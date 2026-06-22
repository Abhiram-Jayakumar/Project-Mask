import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'services/remote_control_service.dart';
import 'services/screen_capture_service.dart';
import 'services/signaling_service.dart';
import 'services/webrtc_service.dart';

enum Role { host, viewer }

/// Orchestrates the signaling + WebRTC services and exposes a single, simple
/// state surface for the UI. One controller per active session.
class CallController extends ChangeNotifier {
  CallController({required this.role, required this.serverUrl});

  final Role role;
  final String serverUrl;

  final SignalingService _signaling = SignalingService();
  final WebRtcService _webrtc = WebRtcService();

  /// Renders the remote screen on the viewer (empty until Phase 3 adds media).
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  String status = 'Idle';
  String? sessionId;
  String? sessionPin;
  bool signalingConnected = false;
  bool dataChannelOpen = false;
  bool peerConnected = false;
  bool isSharing = false;
  bool accessibilityEnabled = false;
  final List<String> log = [];

  bool _hostSessionCreated = false; // guard against duplicate sessions on reconnect
  bool _iceRestarting = false; // guard against repeated ICE restarts

  void _setStatus(String s) {
    status = s;
    notifyListeners();
  }

  void _addLog(String message) {
    log.insert(0, message);
    if (log.length > 100) log.removeLast();
    notifyListeners();
  }

  Future<void> start() async {
    await remoteRenderer.initialize();
    _wireCallbacks();
    if (role == Role.host) await refreshAccessibility();
    _setStatus('Connecting to server…');
    _signaling.connect(serverUrl);
  }

  /// HOST: re-check whether the accessibility service is enabled (call on resume
  /// after the user returns from the system settings screen).
  Future<void> refreshAccessibility() async {
    accessibilityEnabled = await RemoteControlService.isAccessibilityEnabled();
    notifyListeners();
  }

  void openAccessibilitySettings() =>
      RemoteControlService.openAccessibilitySettings();

  void _wireCallbacks() {
    _signaling.onConnectionChange = (connected) {
      signalingConnected = connected;
      _addLog(connected ? 'Signaling connected' : 'Signaling disconnected');
      // Only create a session on the first connect — Socket.IO auto-reconnects,
      // and we don't want a duplicate session each time it does.
      if (connected && role == Role.host && !_hostSessionCreated) {
        _hostSessionCreated = true;
        _signaling.createSession();
      } else if (connected && role == Role.viewer) {
        _setStatus('Enter a session ID to connect');
      }
    };
    _signaling.onSessionCreated = (id, pin) {
      sessionId = id;
      sessionPin = pin;
      _addLog('Session created: $id (PIN $pin)');
      _setStatus('Waiting for viewer…');
    };
    _signaling.onSessionJoined = (id) {
      sessionId = id;
      _addLog('Joined session $id');
      _setStatus('Negotiating…');
      _webrtc.startAsViewer();
    };
    _signaling.onSessionError = (message) {
      _addLog('Error: $message');
      _setStatus('Error: $message');
    };
    _signaling.onViewerJoined = () {
      _addLog('Viewer joined → creating offer');
      _setStatus('Negotiating…');
      _webrtc.startAsHost();
    };
    _signaling.onSignal = (payload) {
      _webrtc.handleSignal(payload);
    };
    _signaling.onPeerLeft = () {
      dataChannelOpen = false;
      peerConnected = false;
      _addLog('Peer left');
      _setStatus('Peer disconnected');
    };

    _webrtc.onLocalSignal = (payload) {
      _signaling.sendSignal(payload);
    };
    _webrtc.onConnectionState = (state) {
      _addLog('Peer state: ${state.name}');
      peerConnected =
          state == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
      if (peerConnected) {
        _iceRestarting = false;
        _setStatus('Connected (peer-to-peer)');
      } else if (state ==
              RTCPeerConnectionState.RTCPeerConnectionStateFailed &&
          role == Role.host &&
          !_iceRestarting) {
        // Media path died — try an ICE restart before giving up (host re-offers).
        _iceRestarting = true;
        _addLog('Connection failed — restarting ICE…');
        _setStatus('Reconnecting…');
        _webrtc.restartIce();
      }
      notifyListeners();
    };
    _webrtc.onDataChannelOpen = (open) {
      dataChannelOpen = open;
      _addLog('Data channel ${open ? 'OPEN' : 'closed'}');
    };
    _webrtc.onDataMessage = (text) {
      // HOST: touch JSON is forwarded to the accessibility service for injection
      // (and not logged, to avoid flooding the log with move events).
      if (role == Role.host && _injectGesture(text)) return;
      _addLog('Received: $text');
    };
    _webrtc.onRemoteStream = (stream) {
      remoteRenderer.srcObject = stream;
      _addLog('Remote stream attached');
      notifyListeners();
    };
  }

  /// Viewer action: join the session the user typed in (with its PIN).
  void joinAsViewer(String id, String pin) {
    _setStatus('Joining $id…');
    _signaling.joinSession(id.trim(), pin.trim());
  }

  /// Phase-2 verification helper: prove the P2P data channel works end-to-end.
  void sendTestPing() {
    final msg = 'ping@${DateTime.now().millisecondsSinceEpoch}';
    _webrtc.sendData(msg);
    _addLog('Sent: $msg');
  }

  /// HOST: start the foreground service, then capture the screen via the system
  /// MediaProjection dialog, and add the track to the peer connection.
  Future<void> startSharing() async {
    try {
      // FGS must run before MediaProjection (Android 10+/14 requirement).
      await ScreenCaptureService.startService();
      final stream = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
        'audio': false,
      });
      await _webrtc.setLocalStream(stream);
      isSharing = true;
      _addLog('Screen capture started');
      _setStatus(peerConnected ? 'Sharing (connected)' : 'Sharing — waiting');
    } catch (e) {
      await ScreenCaptureService.stopService();
      _addLog('Share failed: $e');
      _setStatus('Share failed');
    }
  }

  /// VIEWER: send a normalized touch event (x,y in 0.0–1.0) to the host over the
  /// control data channel. Shape: {"t":"tap|down|move|up","x":..,"y":..}.
  /// The host denormalizes against its real screen size (Phase 5).
  void sendTouch(String type, double x, double y) {
    if (!dataChannelOpen) return;
    _webrtc.sendData(jsonEncode({'t': type, 'x': x, 'y': y}));
  }

  /// HOST: parse an inbound touch message and inject it via the accessibility
  /// service. Returns true if [text] was a recognized gesture message.
  bool _injectGesture(String text) {
    final Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return false;
      data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return false;
    }
    final type = data['t'];
    final x = data['x'];
    final y = data['y'];
    if (type is! String || x is! num || y is! num) return false;
    RemoteControlService.sendGesture(type, x.toDouble(), y.toDouble()).then((ok) {
      if (!ok && accessibilityEnabled) {
        accessibilityEnabled = false;
        _addLog('Remote control blocked — enable Accessibility');
        notifyListeners();
      }
    });
    return true;
  }

  /// HOST: stop capturing and tear down the foreground service.
  Future<void> stopSharing() async {
    await _webrtc.stopLocalStream();
    await ScreenCaptureService.stopService();
    isSharing = false;
    _addLog('Screen capture stopped');
    _setStatus(peerConnected ? 'Connected (peer-to-peer)' : status);
  }

  @override
  void dispose() {
    _webrtc.dispose();
    _signaling.dispose();
    remoteRenderer.dispose();
    super.dispose();
  }
}
