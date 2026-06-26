import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../config.dart';

/// Wraps a single [RTCPeerConnection]. Handles the offer/answer/ICE dance and a
/// "control" [RTCDataChannel] used to ship touch events from viewer → host.
///
/// Roles:
///   - HOST is the **offerer**: it creates the data channel and the SDP offer.
///   - VIEWER is the **answerer**: it waits for the offer and replies.
///
/// Media tracks (the screen video) are added in Phase 3; the plumbing here
/// (onRemoteStream) is ready for them.
class WebRtcService {
  RTCPeerConnection? _pc;
  RTCDataChannel? _dataChannel;
  MediaStream? _localStream; // HOST: the screen
  RTCRtpSender? _screenSender;

  // HOST: optional front-camera "presence" stream, sent as a SECOND video track.
  MediaStream? _cameraStream;
  RTCRtpSender? _cameraSender;
  // HOST: optional microphone stream so the viewer can listen in on demand.
  MediaStream? _micStream;
  RTCRtpSender? _micSender;

  // VIEWER routing: the host announces which media are on (screenOn/cameraOn/
  // micOn) on every offer. A video track is the SCREEN when the host says it's
  // sharing and we haven't bound one yet; any other video track is the camera;
  // audio is the mic. This is reliable regardless of track arrival order (which
  // matters now that camera/audio can arrive before any screen).
  bool _remoteScreenOn = false;
  bool _haveScreen = false;
  bool _remoteCameraPresent = false;
  bool _remoteMicPresent = false;

  // ICE candidates can arrive before the remote description is set; buffer them.
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];

  // ---- Callbacks ----
  /// Emit a payload that must be relayed to the remote peer via signaling.
  void Function(Map<String, dynamic> payload)? onLocalSignal;
  void Function(RTCPeerConnectionState state)? onConnectionState;
  void Function(String text)? onDataMessage;
  void Function(bool open)? onDataChannelOpen;
  void Function(MediaStream stream)? onRemoteStream; // viewer: screen arrived
  void Function()? onScreenRemoved; // viewer: host stopped screen sharing
  void Function(MediaStream stream)? onCameraStream; // viewer: host camera arrived
  void Function()? onCameraRemoved; // viewer: host turned camera off
  void Function(MediaStream stream)? onMicStream; // viewer: host mic audio arrived
  void Function()? onMicRemoved; // viewer: host turned mic off

  RTCPeerConnection? get peerConnection => _pc;

  Future<void> _ensurePeerConnection() async {
    if (_pc != null) return;
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      onLocalSignal?.call({
        'kind': 'ice',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    pc.onConnectionState = (state) => onConnectionState?.call(state);
    pc.onTrack = (event) {
      // Audio tracks are the host's microphone (the only audio we send).
      if (event.track.kind == 'audio') {
        if (event.streams.isNotEmpty) onMicStream?.call(event.streams.first);
        return;
      }
      if (event.streams.isEmpty) return;
      final stream = event.streams.first;
      // Screen if the host is sharing and we haven't bound one; else camera.
      if (_remoteScreenOn && !_haveScreen) {
        _haveScreen = true;
        onRemoteStream?.call(stream);
      } else {
        onCameraStream?.call(stream);
      }
    };
    // Viewer side receives the host-created channel here.
    pc.onDataChannel = _bindDataChannel;
  }

  void _bindDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    channel.onDataChannelState = (state) {
      onDataChannelOpen?.call(state == RTCDataChannelState.RTCDataChannelOpen);
    };
    channel.onMessage = (message) => onDataMessage?.call(message.text);
  }

  /// HOST: create the data channel + SDP offer. Includes the screen track if the
  /// host already started sharing before the viewer joined.
  Future<void> startAsHost() async {
    await _ensurePeerConnection();
    final channel =
        await _pc!.createDataChannel('control', RTCDataChannelInit());
    _bindDataChannel(channel);

    if (_localStream != null) {
      await _addStreamTracks(_localStream!);
    }
    // Re-attach the camera/mic tracks too (e.g. after a reconnect).
    if (_cameraStream != null) {
      await _attachCameraTracks();
    }
    if (_micStream != null) {
      await _attachMicTracks();
    }
    await _createAndSendOffer();
  }

  /// VIEWER: just make sure the peer connection exists; the offer arrives via
  /// [handleSignal].
  Future<void> startAsViewer() => _ensurePeerConnection();

  /// HOST: attach the captured screen stream. If a peer connection already
  /// exists (viewer joined first), this adds the track and renegotiates. If not,
  /// the stream is stored and added when [startAsHost] runs. The host is always
  /// the offerer, so renegotiation can't cause glare.
  Future<void> setLocalStream(MediaStream stream) async {
    _localStream = stream;
    if (_pc == null) return;
    await _addStreamTracks(stream);
    await _createAndSendOffer();
  }

  /// Add a stream's tracks and tune the video encoder for crisp screen content.
  Future<void> _addStreamTracks(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      final sender = await _pc!.addTrack(track, stream);
      if (track.kind == 'video') {
        _screenSender = sender;
        await _applyVideoQuality(sender);
      }
    }
  }

  /// HOST: stop screen sharing and renegotiate so the viewer drops the screen
  /// (the session stays alive for camera/mic).
  Future<void> removeScreenTrack() async {
    final sender = _screenSender;
    _screenSender = null;
    if (sender != null && _pc != null) {
      try {
        await _pc!.removeTrack(sender);
      } catch (_) {}
    }
    await stopLocalStream();
    if (_pc != null) await _createAndSendOffer();
  }

  /// Raise the max bitrate and tell the encoder to preserve resolution (sharp
  /// text) instead of framerate. Non-fatal if the platform rejects the params.
  Future<void> _applyVideoQuality(RTCRtpSender sender) async {
    try {
      final params = sender.parameters;
      final encodings = params.encodings;
      if (encodings == null || encodings.isEmpty) {
        params.encodings = [
          RTCRtpEncoding(
            maxBitrate: maxVideoBitrate,
            maxFramerate: maxVideoFramerate,
          ),
        ];
      } else {
        for (final encoding in encodings) {
          encoding.maxBitrate = maxVideoBitrate;
          encoding.maxFramerate = maxVideoFramerate;
          // Don't pin scaleResolutionDownBy — let BALANCED adapt resolution to
          // the available (cellular/relayed) bandwidth.
        }
      }
      // BALANCED lets WebRTC scale resolution down to fit a constrained/relayed
      // uplink (e.g. host on mobile data) — a smaller but CLEAN image is far more
      // legible than a full-resolution one starved of bitrate. On a fast LAN it
      // stays at full resolution anyway.
      params.degradationPreference = RTCDegradationPreference.BALANCED;
      await sender.setParameters(params);
    } catch (_) {
      // Keep default encoder settings if tuning isn't supported.
    }
  }

  Future<void> stopLocalStream() async {
    final stream = _localStream;
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
    _localStream = null;
  }

  /// HOST: add the front-camera "presence" stream as a second video track and
  /// renegotiate. The host has explicitly opted in (and Android shows the camera
  /// indicator). Safe to call before the peer exists — it's attached in
  /// [startAsHost].
  Future<void> addCameraTrack(MediaStream camStream) async {
    _cameraStream = camStream;
    if (_pc == null) return;
    await _attachCameraTracks();
    await _createAndSendOffer();
  }

  Future<void> _attachCameraTracks() async {
    final stream = _cameraStream;
    if (stream == null || _pc == null) return;
    for (final track in stream.getTracks()) {
      final sender = await _pc!.addTrack(track, stream);
      if (track.kind == 'video') {
        _cameraSender = sender;
        await _applyCameraQuality(sender);
      }
    }
  }

  /// The camera tile is small, so cap it low to leave bandwidth for the screen
  /// (important when the host is on mobile data).
  Future<void> _applyCameraQuality(RTCRtpSender sender) async {
    try {
      final params = sender.parameters;
      final encodings = params.encodings;
      if (encodings == null || encodings.isEmpty) {
        params.encodings = [RTCRtpEncoding(maxBitrate: 500000, maxFramerate: 20)];
      } else {
        for (final e in encodings) {
          e.maxBitrate = 500000;
          e.maxFramerate = 20;
        }
      }
      await sender.setParameters(params);
    } catch (_) {}
  }

  /// HOST: flip the live camera between front and back (no renegotiation —
  /// the capturer is swapped under the same track).
  Future<void> switchCamera() async {
    final tracks = _cameraStream?.getVideoTracks();
    if (tracks == null || tracks.isEmpty) return;
    try {
      await Helper.switchCamera(tracks.first);
    } catch (_) {}
  }

  /// HOST: stop sending the camera and renegotiate so the viewer drops the tile.
  Future<void> removeCameraTrack() async {
    final sender = _cameraSender;
    _cameraSender = null;
    if (sender != null && _pc != null) {
      try {
        await _pc!.removeTrack(sender);
      } catch (_) {}
    }
    await _stopCameraStream();
    if (_pc != null) await _createAndSendOffer();
  }

  Future<void> _stopCameraStream() async {
    final stream = _cameraStream;
    _cameraStream = null;
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }

  /// HOST: add the microphone stream so the viewer can listen, and renegotiate.
  Future<void> addMicTrack(MediaStream micStream) async {
    _micStream = micStream;
    if (_pc == null) return;
    await _attachMicTracks();
    await _createAndSendOffer();
  }

  Future<void> _attachMicTracks() async {
    final stream = _micStream;
    if (stream == null || _pc == null) return;
    for (final track in stream.getTracks()) {
      final sender = await _pc!.addTrack(track, stream);
      if (track.kind == 'audio') _micSender = sender;
    }
  }

  /// HOST: stop sending the mic and renegotiate so the viewer drops the audio.
  Future<void> removeMicTrack() async {
    final sender = _micSender;
    _micSender = null;
    if (sender != null && _pc != null) {
      try {
        await _pc!.removeTrack(sender);
      } catch (_) {}
    }
    await _stopMicStream();
    if (_pc != null) await _createAndSendOffer();
  }

  Future<void> _stopMicStream() async {
    final stream = _micStream;
    _micStream = null;
    if (stream == null) return;
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }

  Future<void> _createAndSendOffer() async {
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    onLocalSignal?.call({
      'kind': 'offer',
      'sdp': offer.sdp,
      'type': offer.type,
      // Tell the viewer which inbound stream is the camera presence track (null
      // when the host isn't sharing their camera).
      // The host announces which media are live so the viewer routes tracks
      // reliably (and drops them when turned off), regardless of arrival order.
      'screenOn': _localStream != null,
      'cameraOn': _cameraStream != null,
      'micOn': _micStream != null,
    });
  }

  /// HOST: recover a dropped media path without re-pairing. Generates fresh ICE
  /// credentials and re-offers; the viewer answers and ICE re-converges.
  Future<void> restartIce() async {
    if (_pc == null) return;
    await _pc!.restartIce();
    _remoteDescriptionSet = false; // a new negotiation cycle begins
    await _createAndSendOffer();
  }

  /// Process an inbound signaling payload from the remote peer.
  Future<void> handleSignal(Map<String, dynamic> payload) async {
    await _ensurePeerConnection();
    switch (payload['kind']) {
      case 'offer':
        // Apply the host's media flags BEFORE the tracks arrive so onTrack
        // routes correctly, and fire *Removed when something turned off (no
        // track-removal event fires on its own).
        final screenOn = payload['screenOn'] == true;
        if (!screenOn && _remoteScreenOn) {
          _haveScreen = false;
          onScreenRemoved?.call();
        }
        _remoteScreenOn = screenOn;
        final camPresent = payload['cameraOn'] == true;
        if (!camPresent && _remoteCameraPresent) {
          onCameraRemoved?.call();
        }
        _remoteCameraPresent = camPresent;
        final micPresent = payload['micOn'] == true;
        if (!micPresent && _remoteMicPresent) {
          onMicRemoved?.call();
        }
        _remoteMicPresent = micPresent;
        await _pc!.setRemoteDescription(
          RTCSessionDescription(payload['sdp'] as String, payload['type'] as String),
        );
        await _flushPendingCandidates();
        final answer = await _pc!.createAnswer();
        await _pc!.setLocalDescription(answer);
        onLocalSignal
            ?.call({'kind': 'answer', 'sdp': answer.sdp, 'type': answer.type});
        break;
      case 'answer':
        await _pc!.setRemoteDescription(
          RTCSessionDescription(payload['sdp'] as String, payload['type'] as String),
        );
        await _flushPendingCandidates();
        break;
      case 'ice':
        final candidate = RTCIceCandidate(
          payload['candidate'] as String?,
          payload['sdpMid'] as String?,
          payload['sdpMLineIndex'] as int?,
        );
        if (_remoteDescriptionSet) {
          await _pc!.addCandidate(candidate);
        } else {
          _pendingCandidates.add(candidate);
        }
        break;
    }
  }

  Future<void> _flushPendingCandidates() async {
    _remoteDescriptionSet = true;
    for (final candidate in _pendingCandidates) {
      await _pc!.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  /// Send a string over the control data channel (e.g. a touch event JSON).
  void sendData(String text) =>
      _dataChannel?.send(RTCDataChannelMessage(text));

  /// Tear down the peer connection for a fresh negotiation (used on reconnect /
  /// reclaim) while KEEPING the local screen stream so the new offer re-includes
  /// the video track.
  Future<void> resetPeer() async {
    await _dataChannel?.close();
    await _pc?.close();
    _dataChannel = null;
    _pc = null;
    _screenSender = null; // belonged to the closed pc; re-added in startAsHost
    _cameraSender = null;
    _micSender = null;
    _remoteScreenOn = false;
    _haveScreen = false;
    _remoteCameraPresent = false;
    _remoteMicPresent = false;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
  }

  Future<void> dispose() async {
    await stopLocalStream();
    await _stopCameraStream();
    await _stopMicStream();
    await resetPeer();
  }
}
