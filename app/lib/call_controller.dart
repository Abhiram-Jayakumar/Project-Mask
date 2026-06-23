import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'config.dart';
import 'services/connection_service.dart';
import 'services/pin_crypto.dart';
import 'services/remote_control_service.dart';
import 'services/screen_capture_service.dart';
import 'services/session_store.dart';
import 'services/signaling_service.dart';
import 'services/system_service.dart';
import 'services/webrtc_service.dart';

enum Role { host, viewer }

/// Host sub-mode: a one-off RANDOM session (quick) vs a stable device id +
/// permanent PIN for Chrome-Remote-Desktop-style "anytime access".
enum HostMode { quick, anytime }

/// Orchestrates the signaling + WebRTC services and exposes a single, simple
/// state surface for the UI. One controller per active session.
class CallController extends ChangeNotifier {
  CallController({
    required this.role,
    required this.serverUrl,
    this.hostMode = HostMode.quick,
  });

  final Role role;
  final String serverUrl;
  final HostMode hostMode;

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
  bool ignoringBatteryOptimizations = true; // true = exempt (or web/unsupported)

  // Anytime access (permanent PIN) — host, anytime mode only.
  String? deviceId; // stable id shown to viewers
  bool hasPin = false; // a permanent PIN has been set
  bool armed = false; // accepting anytime-access connections
  String? _pinSalt;
  String? _pinHash;

  final List<String> log = [];

  bool _hostSessionCreated = false; // guard against duplicate sessions on reconnect
  bool _iceRestarting = false; // guard against repeated ICE restarts
  bool _reclaiming = false; // host is reclaiming an existing session
  bool _keepAliveStarted = false; // viewer keep-alive FGS started
  String _pendingJoinPin = ''; // pin the viewer last tried, saved on success

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
    if (role == Role.host && hostMode == HostMode.anytime) {
      await _loadDeviceIdentity();
    }
    if (role == Role.viewer) await _loadRecentSessions();
    await refreshBatteryOptimization();
    _setStatus('Connecting to server…');
    _signaling.connect(serverUrl);
  }

  /// ANYTIME HOST: load the stable device id + any saved permanent PIN.
  Future<void> _loadDeviceIdentity() async {
    deviceId = await SessionStore.getOrCreateDeviceId();
    final stored = await SessionStore.getDevicePin();
    if (stored != null) {
      _pinSalt = stored.salt;
      _pinHash = stored.hash;
      hasPin = true;
    }
    notifyListeners();
  }

  /// HOST: re-check whether the accessibility service is enabled (call on resume
  /// after the user returns from the system settings screen).
  Future<void> refreshAccessibility() async {
    accessibilityEnabled = await RemoteControlService.isAccessibilityEnabled();
    notifyListeners();
  }

  void openAccessibilitySettings() =>
      RemoteControlService.openAccessibilitySettings();

  /// Re-check whether the app is exempt from battery optimization. A session can
  /// only reliably survive the app being swiped off recents when it is. Call on
  /// resume (after the user returns from the system prompt).
  Future<void> refreshBatteryOptimization() async {
    ignoringBatteryOptimizations =
        await SystemService.isIgnoringBatteryOptimizations();
    notifyListeners();
  }

  void requestBatteryOptimization() =>
      SystemService.requestIgnoreBatteryOptimizations();

  void _wireCallbacks() {
    _signaling.onConnectionChange = (connected) {
      signalingConnected = connected;
      _addLog(connected ? 'Signaling connected' : 'Signaling disconnected');
      if (connected && role == Role.host && hostMode == HostMode.anytime) {
        // Anytime mode: never create a random session. If already armed, re-arm
        // on (re)connect so a waiting viewer can resume.
        if (armed && _pinSalt != null && _pinHash != null) {
          _addLog('Reconnected — re-arming device $deviceId');
          _webrtc.resetPeer();
          _signaling.armDevice(deviceId!, _pinSalt!, _pinHash!);
        }
      } else if (connected && role == Role.host) {
        if (!_hostSessionCreated) {
          _hostSessionCreated = true;
          _signaling.createSession();
        } else if (sessionId != null) {
          // Reconnected (Socket.IO auto-reconnect) — reclaim the SAME session
          // instead of creating a new one, so the viewer can resume.
          _addLog('Reconnected — reclaiming session $sessionId');
          _reclaiming = true;
          _webrtc.resetPeer();
          _signaling.reclaimSession(sessionId!, sessionPin ?? '');
        }
      } else if (connected && role == Role.viewer) {
        _setStatus('Enter a session ID to connect');
      }
    };
    _signaling.onSessionCreated = (id, pin) {
      sessionId = id;
      sessionPin = pin;
      SessionStore.saveHostSession(id, pin);
      _addLog(_reclaiming ? 'Session reclaimed: $id' : 'Session created: $id (PIN $pin)');
      _setStatus(_reclaiming ? 'Reclaimed — reconnecting viewer…' : 'Waiting for viewer…');
      _reclaiming = false;
    };
    _signaling.onSessionJoined = (id) {
      sessionId = id;
      SessionStore.addViewerHistory(id, _pendingJoinPin)
          .then((_) => _loadRecentSessions());
      _addLog('Joined session $id');
      _setStatus('Negotiating…');
      _webrtc.startAsViewer();
    };
    _signaling.onReclaimFailed = (message) {
      _addLog('Reclaim failed: $message — starting a new session');
      _reclaiming = false;
      _webrtc.resetPeer();
      _signaling.createSession();
    };
    _signaling.onDeviceArmed = (id) {
      deviceId = id;
      armed = true;
      _addLog('Device armed — viewers can connect with the PIN');
      _setStatus(peerConnected
          ? 'Connected (peer-to-peer)'
          : 'Ready — waiting for a viewer');
    };
    _signaling.onDeviceArmFailed = (reason) async {
      if (reason == 'id-taken') {
        // Extremely rare 9-digit collision: take a new id and re-arm.
        deviceId = await SessionStore.regenerateDeviceId();
        _addLog('Device ID was in use — switched to $deviceId');
        if (armed && _pinSalt != null && _pinHash != null) {
          _signaling.armDevice(deviceId!, _pinSalt!, _pinHash!);
        }
        notifyListeners();
      } else {
        armed = false;
        _addLog('Couldn\'t allow connections: $reason');
        _setStatus('Couldn\'t allow connections');
        notifyListeners();
      }
    };
    _signaling.onHostDisconnected = () {
      // Viewer side: host dropped but the session is held briefly — keep waiting.
      peerConnected = false;
      _addLog('Host disconnected — waiting for it to reconnect…');
      _setStatus('Host reconnecting…');
    };
    _signaling.onHostReconnected = () {
      // Viewer side: host is back and will re-offer; reset for a clean handshake.
      _addLog('Host reconnected — renegotiating');
      _setStatus('Reconnecting…');
      _webrtc.resetPeer();
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
        // VIEWER: start the keep-alive FGS so the session survives the app being
        // swiped off recents. (The host is already kept alive by the screen-
        // capture FGS while sharing.)
        if (role == Role.viewer && !_keepAliveStarted) {
          _keepAliveStarted = true;
          ConnectionService.startKeepAlive();
        }
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
    _pendingJoinPin = pin.trim(); // saved to history once the join succeeds
    _setStatus('Joining $id…');
    _signaling.joinSession(id.trim(), _pendingJoinPin);
  }

  /// Viewer: recently-connected sessions, for one-tap rejoin (reactive).
  List<SessionEntry> recentSessions = [];

  Future<void> _loadRecentSessions() async {
    recentSessions = await SessionStore.getViewerHistory();
    notifyListeners();
  }

  /// Phase-2 verification helper: prove the P2P data channel works end-to-end.
  void sendTestPing() {
    final msg = 'ping@${DateTime.now().millisecondsSinceEpoch}';
    _webrtc.sendData(msg);
    _addLog('Sent: $msg');
  }

  /// ANYTIME HOST: set/replace the permanent PIN (stored hashed). If already
  /// armed, re-arm so the new PIN takes effect immediately.
  Future<void> setPermanentPin(String pin) async {
    final salt = PinCrypto.generateSalt();
    final hash = PinCrypto.hash(salt, pin);
    await SessionStore.saveDevicePin(salt, hash);
    _pinSalt = salt;
    _pinHash = hash;
    hasPin = true;
    _addLog('Permanent PIN set');
    if (armed && deviceId != null) _signaling.armDevice(deviceId!, salt, hash);
    notifyListeners();
  }

  /// ANYTIME HOST: start accepting connections. Requires a PIN; starts screen
  /// capture (one consent dialog) so viewers get video the instant they connect,
  /// then arms the device on the server.
  Future<void> armDevice() async {
    if (!hasPin || _pinSalt == null || _pinHash == null || deviceId == null) {
      _setStatus('Set a PIN first');
      return;
    }
    if (!isSharing) {
      await startSharing();
      if (!isSharing) return; // user cancelled the capture consent dialog
    }
    armed = true;
    _addLog('Allowing remote connections…');
    _signaling.armDevice(deviceId!, _pinSalt!, _pinHash!);
    notifyListeners();
  }

  /// ANYTIME HOST: stop accepting connections and stop capturing.
  Future<void> disarmDevice() async {
    armed = false;
    _signaling.disarmDevice();
    await stopSharing();
    _addLog('Stopped allowing remote connections');
    _setStatus('Not allowing connections');
    notifyListeners();
  }

  /// HOST: start the foreground service, then capture the screen via the system
  /// MediaProjection dialog, and add the track to the peer connection.
  Future<void> startSharing() async {
    if (isMobileWeb) {
      // Mobile browsers can't capture the screen; this would grab the camera.
      _addLog('Screen sharing isn\'t supported in a mobile browser.');
      _setStatus('Install the app to share this phone\'s screen');
      return;
    }
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

  /// Explicitly END the session. This is the ONLY thing that drops the
  /// connection — backgrounding / swiping the app off recents intentionally
  /// keeps it alive. Stops the keep-alive foreground service(s); the caller then
  /// pops back to Home, which disposes this controller (closing the peer +
  /// signaling socket so the other side sees the disconnect).
  Future<void> endSession() async {
    if (role == Role.host) {
      if (armed) {
        armed = false;
        _signaling.disarmDevice();
      }
      if (isSharing) await _webrtc.stopLocalStream();
      await ScreenCaptureService.stopService();
      isSharing = false;
    } else {
      await ConnectionService.stopKeepAlive();
      _keepAliveStarted = false;
    }
    _addLog('Session closed by user');
    _setStatus('Session closed');
  }

  @override
  void dispose() {
    _webrtc.dispose();
    _signaling.dispose();
    remoteRenderer.dispose();
    super.dispose();
  }
}
