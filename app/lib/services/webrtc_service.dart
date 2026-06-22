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
  MediaStream? _localStream;

  // ICE candidates can arrive before the remote description is set; buffer them.
  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _pendingCandidates = [];

  // ---- Callbacks ----
  /// Emit a payload that must be relayed to the remote peer via signaling.
  void Function(Map<String, dynamic> payload)? onLocalSignal;
  void Function(RTCPeerConnectionState state)? onConnectionState;
  void Function(String text)? onDataMessage;
  void Function(bool open)? onDataChannelOpen;
  void Function(MediaStream stream)? onRemoteStream;

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
      if (event.streams.isNotEmpty) onRemoteStream?.call(event.streams.first);
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
        await _applyVideoQuality(sender);
      }
    }
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
          encoding.scaleResolutionDownBy = 1.0;
        }
      }
      params.degradationPreference =
          RTCDegradationPreference.MAINTAIN_RESOLUTION;
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

  Future<void> _createAndSendOffer() async {
    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    onLocalSignal?.call({'kind': 'offer', 'sdp': offer.sdp, 'type': offer.type});
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

  Future<void> dispose() async {
    await stopLocalStream();
    await _dataChannel?.close();
    await _pc?.close();
    _dataChannel = null;
    _pc = null;
  }
}
