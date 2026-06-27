import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'config.dart';
import 'services/connection_service.dart';
import 'services/file_access_service.dart';
import 'services/location_service.dart';
import 'services/pin_crypto.dart';
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

  /// Renders the remote screen on the viewer.
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  /// HOST: local front-camera self-preview. VIEWER: the host's camera feed.
  final RTCVideoRenderer cameraRenderer = RTCVideoRenderer();
  // HOST: cameraAllowed = the user permitted sharing (a toggle); the camera only
  // actually turns on (cameraActive) WHEN the viewer asks to look — so the OS
  // camera indicator only appears while it's genuinely being watched.
  bool cameraAllowed = false;
  bool cameraActive = false;
  // VIEWER: cameraAvailable = the host permits it (show the View-host button);
  // cameraOn = a camera track is actually arriving (show the tile).
  bool cameraAvailable = false;
  bool cameraOn = false;

  /// VIEWER: a hidden renderer that actually PLAYS the host's mic audio (web
  /// needs a media element to output remote audio). Mirrors the camera model.
  final RTCVideoRenderer audioRenderer = RTCVideoRenderer();
  bool micAllowed = false; // HOST permitted listening
  bool micActive = false; // HOST mic genuinely open
  bool micAvailable = false; // VIEWER: host permits listening
  bool micOn = false; // VIEWER: receiving the mic audio
  bool screenRequested = false; // HOST: the viewer asked to see the screen

  // File access — host selects folders the viewer is allowed to browse.
  List<String> permittedFolders = [];   // HOST: folders shared with viewer
  bool filesAvailable = false;           // VIEWER: host has shared folders
  List<String> availableFolders = [];    // VIEWER: folder list from host

  // ── File-browse results (viewer side, cleared after read) ──────────────────
  ({String path, List<FileEntry> entries})? fileListResult;
  ({String path, String text, bool isBinary, int totalSize})? filePreviewResult;
  ({String path, String error})? fileErrorResult;

  // ── Chunked download state (viewer side) ───────────────────────────────────
  bool isDownloading = false;
  String downloadPath = '';
  String downloadName = '';
  int downloadTotalChunks = 0;
  int downloadDoneChunks = 0;
  double get downloadProgress =>
      downloadTotalChunks == 0 ? 0 : downloadDoneChunks / downloadTotalChunks;
  // Assembled bytes ready to save — cleared after caller reads it.
  ({String name, Uint8List bytes})? downloadReady;
  String? downloadError;

  // ── Location + battery ─────────────────────────────────────────────────────
  // HOST side
  bool locationAllowed = false; // host opted-in to share location
  bool locationActive = false;  // GPS stream is running

  // VIEWER side
  bool locationAvailable = false;          // host permits sharing
  LocationUpdate? hostLocation;            // most-recent fix
  final List<LocationUpdate> locationHistory = []; // travel route this session
  int? hostBattery;                        // 0-100
  bool hostBatteryCharging = false;

  String status = 'Idle';
  String? sessionId;
  String? sessionPin;
  bool signalingConnected = false;
  bool dataChannelOpen = false;
  bool peerConnected = false;
  bool isSharing = false;
  bool ignoringBatteryOptimizations = true; // true = exempt (or web/unsupported)

  // Anytime access (permanent PIN) — host, anytime mode only.
  String? deviceId; // stable id shown to viewers
  bool hasPin = false; // a permanent PIN has been set
  bool armed = false; // accepting anytime-access connections
  String? _pinSalt;
  String? _pinHash;

  final List<String> log = [];
  final List<String> _downloadChunks = []; // base64 chunk accumulator

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
    await cameraRenderer.initialize();
    await audioRenderer.initialize();
    _wireCallbacks();
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
    // Restore the host's camera/mic/location "allow" choices so a reboot/re-arm
    // doesn't require re-toggling (the OS permissions already persist).
    final mediaPrefs = await SessionStore.getMediaPrefs();
    cameraAllowed = mediaPrefs.camera;
    micAllowed = mediaPrefs.mic;
    locationAllowed = mediaPrefs.location;
    permittedFolders = await SessionStore.getPermittedFolders();
    notifyListeners();
  }

  void _persistMediaPrefs() {
    SessionStore.setMediaPrefs(
      camera: cameraAllowed,
      mic: micAllowed,
      location: locationAllowed,
    );
  }

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
      SessionStore.setArmedState(true); // persist so BootReceiver detects a reboot
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
      // HOST: viewer's gone — stop camera/mic/location so they aren't left running.
      if (role == Role.host && cameraActive) _stopCameraInternal();
      if (role == Role.host && micActive) _stopMicInternal();
      if (role == Role.host && locationActive) _stopLocationInternal();
      if (role == Role.viewer) {
        cameraAvailable = false;
        cameraOn = false;
        cameraRenderer.srcObject = null;
        micAvailable = false;
        micOn = false;
        audioRenderer.srcObject = null;
        filesAvailable = false;
        availableFolders = [];
        fileListResult = null;
        filePreviewResult = null;
        fileErrorResult = null;
        isDownloading = false;
        downloadPath = '';
        downloadName = '';
        downloadTotalChunks = 0;
        downloadDoneChunks = 0;
        downloadReady = null;
        downloadError = null;
        _downloadChunks.clear();
        locationAvailable = false;
        hostLocation = null;
        locationHistory.clear();
        hostBattery = null;
        hostBatteryCharging = false;
      }
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
      // HOST: tell the (re)connected viewer what's available.
      if (open && role == Role.host) {
        _signalCameraAvailability();
        _signalMicAvailability();
        _signalFoldersAvailability();
        _signalLocationAvailability();
        // Restart the GPS+battery stream so the new viewer immediately gets
        // an update if location sharing was already active.
        if (locationAllowed) _startLocationInternal();
      }
    };
    _webrtc.onDataMessage = (text) {
      // Camera/mic control messages (the only data-channel traffic now).
      if (_handleMediaMessage(text)) return;
      _addLog('Received: $text');
    };
    _webrtc.onRemoteStream = (stream) {
      remoteRenderer.srcObject = stream;
      _addLog('Remote screen attached');
      notifyListeners();
    };
    _webrtc.onScreenRemoved = () {
      remoteRenderer.srcObject = null;
      _addLog('Host stopped screen sharing');
      notifyListeners();
    };
    _webrtc.onCameraStream = (stream) {
      // VIEWER: the host turned their camera on.
      cameraRenderer.srcObject = stream;
      cameraOn = true;
      _addLog('Host camera on');
      notifyListeners();
    };
    _webrtc.onCameraRemoved = () {
      cameraRenderer.srcObject = null;
      cameraOn = false;
      _addLog('Host camera off');
      notifyListeners();
    };
    _webrtc.onMicStream = (stream) {
      // VIEWER: host mic audio arrived — attach to the hidden renderer so it
      // actually plays (needed on web).
      audioRenderer.srcObject = stream;
      micOn = true;
      _addLog('Host mic on');
      notifyListeners();
    };
    _webrtc.onMicRemoved = () {
      audioRenderer.srcObject = null;
      micOn = false;
      _addLog('Host mic off');
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

  /// ANYTIME HOST: go online (keep-alive foreground service) WITHOUT screen
  /// sharing — no capture-consent dialog at arm time. Camera/mic are available
  /// on demand; the screen is shared later on the viewer's request (or the
  /// host's "Share screen" button).
  Future<void> armDevice() async {
    if (!hasPin || _pinSalt == null || _pinHash == null || deviceId == null) {
      _setStatus('Set a PIN first');
      return;
    }
    await ScreenCaptureService.startService(); // connectedDevice keep-alive
    armed = true;
    _addLog('Allowing remote connections…');
    _signaling.armDevice(deviceId!, _pinSalt!, _pinHash!);
    notifyListeners();
  }

  /// ANYTIME HOST: stop accepting connections and tear down the host service.
  Future<void> disarmDevice() async {
    armed = false;
    _signaling.disarmDevice();
    await SessionStore.setArmedState(false);
    cameraAllowed = false;
    if (cameraActive) await _stopCameraInternal();
    micAllowed = false;
    if (micActive) await _stopMicInternal();
    locationAllowed = false;
    _stopLocationInternal();
    _persistMediaPrefs();
    if (isSharing) {
      await _webrtc.removeScreenTrack();
      isSharing = false;
    }
    await ScreenCaptureService.stopService(); // stop the keep-alive FGS
    _addLog('Stopped allowing remote connections');
    _setStatus('Not allowing connections');
    notifyListeners();
  }

  /// VIEWER: ask the host to start sharing their screen.
  void requestHostScreen() {
    if (!dataChannelOpen) return;
    _webrtc.sendData(jsonEncode({'t': 'reqscreen'}));
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
      // FGS must run (and carry the mediaProjection type) before MediaProjection
      // (Android 10+/14 requirement).
      await ScreenCaptureService.startService();
      await ScreenCaptureService.setScreen(true);
      final stream = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
        'audio': false,
      });
      await _webrtc.setLocalStream(stream);
      isSharing = true;
      screenRequested = false;
      _addLog('Screen sharing started');
      _setStatus(peerConnected ? 'Sharing (connected)' : 'Sharing — waiting');
    } catch (e) {
      // Revert the mediaProjection type but keep the keep-alive service so an
      // armed host stays online even if the consent dialog was cancelled.
      await ScreenCaptureService.setScreen(false);
      _addLog('Share failed: $e');
      _setStatus('Share failed');
    }
  }

  /// HOST: allow the viewer to view your camera. This does NOT turn the camera
  /// on — it only advertises availability. The camera (and the OS indicator)
  /// starts only when the viewer actually asks to look ([_startCameraInternal]).
  Future<void> allowCamera() async {
    if (kIsWeb) return;
    cameraAllowed = true;
    // Grant the camera permission NOW (host is here), so the on-demand camera
    // never has to prompt the host again — including while backgrounded.
    SystemService.requestCameraPermission();
    _persistMediaPrefs();
    _addLog('Camera available — turns on only when the viewer looks');
    _signalCameraAvailability();
    notifyListeners();
  }

  /// HOST: revoke camera sharing (and stop it if it's live).
  Future<void> disallowCamera() async {
    cameraAllowed = false;
    if (cameraActive) await _stopCameraInternal();
    _persistMediaPrefs();
    _signalCameraAvailability();
    notifyListeners();
  }

  void _signalCameraAvailability() {
    if (dataChannelOpen) {
      _webrtc.sendData(jsonEncode({'t': 'camavail', 'on': cameraAllowed}));
    }
  }

  /// HOST: actually open the camera — only called when the viewer requests it.
  Future<void> _startCameraInternal() async {
    if (cameraActive || !cameraAllowed || kIsWeb) return;
    try {
      // Add the camera FGS type FIRST so the camera can open even while the app
      // is backgrounded (Android blocks background camera otherwise).
      await ScreenCaptureService.setCamera(true);
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {'facingMode': 'user'},
      });
      cameraRenderer.srcObject = stream; // local self-preview
      await _webrtc.addCameraTrack(stream);
      cameraActive = true;
      _addLog('Camera on (viewer is watching)');
      notifyListeners();
    } catch (e) {
      await ScreenCaptureService.setCamera(false); // revert on failure
      _addLog('Camera failed: $e');
    }
  }

  /// HOST: close the camera (viewer stopped looking / revoked).
  Future<void> _stopCameraInternal() async {
    if (!cameraActive) return;
    cameraRenderer.srcObject = null;
    await _webrtc.removeCameraTrack();
    await ScreenCaptureService.setCamera(false); // drop the camera FGS type
    cameraActive = false;
    _addLog('Camera off');
    notifyListeners();
  }

  /// VIEWER: ask the host to start ([want]=true) or stop sending their camera.
  void requestHostCamera(bool want) {
    if (!dataChannelOpen) return;
    _webrtc.sendData(jsonEncode({'t': 'cam', 'want': want}));
  }

  /// VIEWER: ask the host to flip between front and back camera.
  void requestCameraFlip() {
    if (!dataChannelOpen) return;
    _webrtc.sendData(jsonEncode({'t': 'camflip'}));
  }

  /// HOST: flip the live camera (front ↔ back).
  Future<void> flipCamera() async {
    if (!cameraActive) return;
    await _webrtc.switchCamera();
    _addLog('Camera flipped');
  }

  // ---- Microphone (host "let the viewer listen") — same on-demand model ----

  /// HOST: allow the viewer to listen. Doesn't open the mic — that happens only
  /// when the viewer asks ([_startMicInternal]). Grants the mic permission now.
  Future<void> allowMic() async {
    if (kIsWeb) return;
    micAllowed = true;
    SystemService.requestMicPermission();
    _persistMediaPrefs();
    _addLog('Mic available — turns on only when the viewer listens');
    _signalMicAvailability();
    notifyListeners();
  }

  /// HOST: revoke listening (and stop the mic if it's live).
  Future<void> disallowMic() async {
    micAllowed = false;
    if (micActive) await _stopMicInternal();
    _persistMediaPrefs();
    _signalMicAvailability();
    notifyListeners();
  }

  void _signalMicAvailability() {
    if (dataChannelOpen) {
      _webrtc.sendData(jsonEncode({'t': 'micavail', 'on': micAllowed}));
    }
  }

  /// HOST: open the mic — only when the viewer requests it.
  Future<void> _startMicInternal() async {
    if (micActive || !micAllowed || kIsWeb) return;
    try {
      await ScreenCaptureService.setMic(true); // microphone FGS type (background)
      final stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      await _webrtc.addMicTrack(stream);
      micActive = true;
      _addLog('Mic on (viewer is listening)');
      notifyListeners();
    } catch (e) {
      await ScreenCaptureService.setMic(false);
      _addLog('Mic failed: $e');
    }
  }

  /// HOST: close the mic (viewer stopped listening / revoked).
  Future<void> _stopMicInternal() async {
    if (!micActive) return;
    await _webrtc.removeMicTrack();
    await ScreenCaptureService.setMic(false);
    micActive = false;
    _addLog('Mic off');
    notifyListeners();
  }

  /// VIEWER: ask the host to start/stop sending their microphone.
  void requestHostMic(bool want) {
    if (!dataChannelOpen) return;
    _webrtc.sendData(jsonEncode({'t': 'mic', 'want': want}));
  }

  // ── Location + battery ─────────────────────────────────────────────────────

  /// HOST: consent to share live location + battery with the viewer. Starts the
  /// GPS stream immediately and advertises availability over the data channel.
  Future<void> allowLocation() async {
    if (kIsWeb) return;
    locationAllowed = true;
    _persistMediaPrefs();
    _addLog('Location sharing enabled');
    _signalLocationAvailability();
    await _startLocationInternal();
    notifyListeners();
  }

  /// HOST: revoke location sharing and stop the GPS stream.
  Future<void> disallowLocation() async {
    locationAllowed = false;
    _stopLocationInternal();
    _persistMediaPrefs();
    _signalLocationAvailability();
    notifyListeners();
  }

  void _signalLocationAvailability() {
    if (dataChannelOpen) {
      _webrtc.sendData(jsonEncode({'t': 'locavail', 'on': locationAllowed}));
    }
  }

  Future<void> _startLocationInternal() async {
    if (locationActive || !locationAllowed || kIsWeb) return;
    locationActive = true;
    LocationService.onLocation = (update) {
      if (!dataChannelOpen) return;
      _webrtc.sendData(jsonEncode({
        't': 'locupdate',
        'lat': update.lat,
        'lng': update.lng,
        'acc': update.accuracy,
      }));
    };
    LocationService.onBattery = (pct, charging) {
      if (!dataChannelOpen) return;
      _webrtc.sendData(jsonEncode({
        't': 'battery',
        'pct': pct,
        'charging': charging,
      }));
    };
    await LocationService.startTracking();
    _addLog('Location tracking started');
  }

  void _stopLocationInternal() {
    if (!locationActive) return;
    locationActive = false;
    LocationService.onLocation = null;
    LocationService.onBattery = null;
    LocationService.stopTracking();
    _addLog('Location tracking stopped');
  }

  // ── File access ────────────────────────────────────────────────────────────

  /// HOST: add a folder the viewer is allowed to browse. Persists the list and
  /// immediately signals the change to any connected viewer. Requests storage
  /// permission on the first add so subsequent reads don't fail silently.
  Future<void> addPermittedFolder(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty || permittedFolders.contains(trimmed)) return;
    if (permittedFolders.isEmpty) SystemService.requestStoragePermission();
    permittedFolders = [...permittedFolders, trimmed];
    await SessionStore.setPermittedFolders(permittedFolders);
    _signalFoldersAvailability();
    _addLog('Shared folder added: $trimmed');
    notifyListeners();
  }

  /// HOST: remove a permitted folder and signal the viewer.
  Future<void> removePermittedFolder(String path) async {
    permittedFolders = permittedFolders.where((f) => f != path).toList();
    await SessionStore.setPermittedFolders(permittedFolders);
    _signalFoldersAvailability();
    _addLog('Shared folder removed: $path');
    notifyListeners();
  }

  void _signalFoldersAvailability() {
    if (dataChannelOpen) {
      _webrtc.sendData(jsonEncode({
        't': 'filesavail',
        'folders': permittedFolders,
      }));
    }
  }

  /// VIEWER: request a directory listing from the host.
  void requestFileList(String path) {
    if (!dataChannelOpen) return;
    _webrtc.sendData(jsonEncode({'t': 'reqfilelist', 'path': path}));
  }

  /// VIEWER: request a 2 KB text preview of a file.
  void requestFilePreview(String path) {
    if (!dataChannelOpen) return;
    _webrtc.sendData(jsonEncode({'t': 'reqpreview', 'path': path}));
  }

  /// VIEWER: start a chunked download of a file from the host.
  void requestFileDownload(String path) {
    if (!dataChannelOpen || isDownloading) return;
    isDownloading = true;
    downloadPath = path;
    downloadTotalChunks = 0;
    downloadDoneChunks = 0;
    downloadError = null;
    downloadReady = null;
    _downloadChunks.clear();
    notifyListeners();
    _webrtc.sendData(jsonEncode({'t': 'reqdl', 'path': path}));
  }

  /// Cancel an in-progress download (viewer-initiated).
  void cancelDownload() {
    isDownloading = false;
    downloadPath = '';
    downloadTotalChunks = 0;
    downloadDoneChunks = 0;
    _downloadChunks.clear();
    notifyListeners();
  }

  // ── Take-and-clear helpers (panel reads these after notifyListeners) ────────

  ({String path, List<FileEntry> entries})? takeFileListResult() {
    final r = fileListResult;
    fileListResult = null;
    return r;
  }

  ({String path, String text, bool isBinary, int totalSize})? takeFilePreviewResult() {
    final r = filePreviewResult;
    filePreviewResult = null;
    return r;
  }

  ({String path, String error})? takeFileErrorResult() {
    final r = fileErrorResult;
    fileErrorResult = null;
    return r;
  }

  ({String name, Uint8List bytes})? takeDownloadReady() {
    final r = downloadReady;
    downloadReady = null;
    return r;
  }

  // ── HOST-SIDE handlers ──────────────────────────────────────────────────────

  Future<void> _handleFileListRequest(String path) async {
    if (!FileAccessService.isAllowed(path, permittedFolders)) {
      _sendFileError(path, 'Access denied');
      return;
    }
    try {
      final entries = await FileAccessService.listDirectory(path);
      _webrtc.sendData(jsonEncode({
        't': 'filelist',
        'path': path,
        'entries': entries.map((e) => e.toJson()).toList(),
      }));
    } catch (e) {
      _sendFileError(path, e.toString());
    }
  }

  Future<void> _handlePreviewRequest(String path) async {
    if (!FileAccessService.isAllowed(path, permittedFolders)) {
      _sendFileError(path, 'Access denied');
      return;
    }
    try {
      final result = await FileAccessService.readPreview(path);
      _webrtc.sendData(jsonEncode({
        't': 'preview',
        'path': path,
        'text': result.isBinary ? '' : result.text,
        'bin': result.isBinary,
        'size': result.totalSize,
      }));
    } catch (e) {
      _sendFileError(path, e.toString());
    }
  }

  Future<void> _handleDownloadRequest(String path) async {
    if (!FileAccessService.isAllowed(path, permittedFolders)) {
      _sendFileError(path, 'Access denied');
      return;
    }
    try {
      final name = path.split('/').last;
      final file = await () async {
        // We need the file size for dlstart; do a quick stat.
        final f = File(path);
        final size = await f.length();
        return (size: size, name: name);
      }();
      // Announce the transfer so the viewer can show a progress bar.
      final totalSize = file.size;
      final totalChunks =
          totalSize == 0 ? 1 : (totalSize / FileAccessService.chunkSize).ceil();
      _webrtc.sendData(jsonEncode({
        't': 'dlstart',
        'path': path,
        'name': name,
        'size': totalSize,
        'total': totalChunks,
      }));
      // Stream chunks.
      await FileAccessService.readChunked(path, (idx, b64, total) async {
        _webrtc.sendData(jsonEncode({'t': 'dlchunk', 'i': idx, 'd': b64}));
      });
      // Signal completion.
      _webrtc.sendData(jsonEncode({'t': 'dlend', 'path': path}));
      _addLog('Download sent: $name');
    } catch (e) {
      _webrtc.sendData(jsonEncode({'t': 'dlerr', 'path': path, 'm': e.toString()}));
      _addLog('Download error: $e');
    }
  }

  void _sendFileError(String path, String msg) {
    _webrtc.sendData(jsonEncode({'t': 'fileerr', 'path': path, 'msg': msg}));
  }

  /// Handle the camera/mic control messages over the data channel. HOST receives
  /// `{"t":"cam"|"mic","want":bool}`; VIEWER receives
  /// `{"t":"camavail"|"micavail","on":bool}`. Returns true if handled.
  bool _handleMediaMessage(String text) {
    // The data channel now only carries infrequent media-control messages
    // (no touch events any more), so decoding each is fine.
    final Map<String, dynamic> data;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return false;
      data = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return false;
    }
    final t = data['t'];
    final want = data['want'] == true;
    if (role == Role.host && t == 'cam') {
      want ? _startCameraInternal() : _stopCameraInternal();
      return true;
    }
    if (role == Role.host && t == 'camflip') {
      flipCamera();
      return true;
    }
    if (role == Role.host && t == 'reqscreen') {
      screenRequested = true;
      _addLog('Viewer requested screen share');
      _setStatus('Viewer wants to see your screen');
      notifyListeners();
      return true;
    }
    if (role == Role.host && t == 'mic') {
      want ? _startMicInternal() : _stopMicInternal();
      return true;
    }
    if (role == Role.viewer && t == 'camavail') {
      cameraAvailable = data['on'] == true;
      if (!cameraAvailable) {
        cameraOn = false;
        cameraRenderer.srcObject = null;
      }
      notifyListeners();
      return true;
    }
    if (role == Role.viewer && t == 'micavail') {
      micAvailable = data['on'] == true;
      if (!micAvailable) {
        micOn = false;
        audioRenderer.srcObject = null;
      }
      notifyListeners();
      return true;
    }
    // ── File access ──────────────────────────────────────────────────────────
    if (role == Role.viewer && t == 'filesavail') {
      final raw = data['folders'];
      availableFolders = raw is List
          ? raw.whereType<String>().toList()
          : <String>[];
      filesAvailable = availableFolders.isNotEmpty;
      notifyListeners();
      return true;
    }
    if (role == Role.host && t == 'reqfilelist') {
      _handleFileListRequest(data['path'] as String? ?? '');
      return true;
    }
    if (role == Role.host && t == 'reqpreview') {
      _handlePreviewRequest(data['path'] as String? ?? '');
      return true;
    }
    if (role == Role.host && t == 'reqdl') {
      _handleDownloadRequest(data['path'] as String? ?? '');
      return true;
    }
    // ── Viewer receives responses ──────────────────────────────────────────
    if (role == Role.viewer && t == 'filelist') {
      final path = data['path'] as String? ?? '';
      final rawEntries = data['entries'];
      final entries = rawEntries is List
          ? rawEntries
              .whereType<Map>()
              .map((e) => FileEntry.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : <FileEntry>[];
      fileListResult = (path: path, entries: entries);
      notifyListeners();
      return true;
    }
    if (role == Role.viewer && t == 'preview') {
      filePreviewResult = (
        path: data['path'] as String? ?? '',
        text: data['text'] as String? ?? '',
        isBinary: data['bin'] == true,
        totalSize: (data['size'] as num?)?.toInt() ?? 0,
      );
      notifyListeners();
      return true;
    }
    if (role == Role.viewer && t == 'dlstart') {
      downloadPath = data['path'] as String? ?? '';
      downloadName = data['name'] as String? ?? '';
      downloadTotalChunks = (data['total'] as num?)?.toInt() ?? 0;
      downloadDoneChunks = 0;
      isDownloading = true;
      downloadError = null;
      _downloadChunks.clear();
      notifyListeners();
      return true;
    }
    if (role == Role.viewer && t == 'dlchunk') {
      final b64 = data['d'] as String? ?? '';
      _downloadChunks.add(b64);
      downloadDoneChunks = _downloadChunks.length;
      notifyListeners();
      return true;
    }
    if (role == Role.viewer && t == 'dlend') {
      // Assemble all base64 chunks into a single Uint8List.
      final all = _downloadChunks
          .expand((b64) => base64.decode(b64))
          .toList();
      downloadReady = (name: downloadName, bytes: Uint8List.fromList(all));
      isDownloading = false;
      _downloadChunks.clear();
      _addLog('Download complete: $downloadName');
      notifyListeners();
      return true;
    }
    if (role == Role.viewer && t == 'dlerr') {
      downloadError = data['m'] as String? ?? 'Download failed';
      isDownloading = false;
      _downloadChunks.clear();
      notifyListeners();
      return true;
    }
    if (role == Role.viewer && t == 'fileerr') {
      final path = data['path'] as String? ?? '';
      final msg = data['msg'] as String? ?? 'Unknown error';
      fileErrorResult = (path: path, error: msg);
      // Also cancel any in-progress download if the error matches our path.
      if (isDownloading && path == downloadPath) {
        downloadError = msg;
        isDownloading = false;
        _downloadChunks.clear();
      }
      notifyListeners();
      return true;
    }
    // ── Location + battery (viewer receives) ─────────────────────────────────
    if (role == Role.viewer && t == 'locavail') {
      locationAvailable = data['on'] == true;
      notifyListeners();
      return true;
    }
    if (role == Role.viewer && t == 'locupdate') {
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      final acc = (data['acc'] as num?)?.toDouble() ?? 0.0;
      if (lat != null && lng != null) {
        final update = LocationUpdate(lat: lat, lng: lng, accuracy: acc);
        hostLocation = update;
        locationHistory.add(update);
        notifyListeners();
      }
      return true;
    }
    if (role == Role.viewer && t == 'battery') {
      hostBattery = (data['pct'] as num?)?.toInt();
      hostBatteryCharging = data['charging'] == true;
      notifyListeners();
      return true;
    }
    return false;
  }

  /// HOST: stop screen sharing. Keeps the keep-alive service running so an armed
  /// host stays online for camera/mic; the viewer drops the screen on the
  /// renegotiation (screenOn → false).
  Future<void> stopSharing() async {
    await _webrtc.removeScreenTrack();
    await ScreenCaptureService.setScreen(false);
    isSharing = false;
    _addLog('Screen sharing stopped');
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
        await SessionStore.setArmedState(false);
      }
      if (locationActive) _stopLocationInternal();
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
    cameraRenderer.dispose();
    audioRenderer.dispose();
    super.dispose();
  }
}
