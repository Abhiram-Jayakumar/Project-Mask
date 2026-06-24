/// App-wide configuration constants.
library;

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;

/// True when running in a **mobile browser** (Chrome/Safari on a phone). Such
/// browsers do NOT support screen capture (`getDisplayMedia`) — only desktop
/// browsers and the native Android app can host. Used to make the web app
/// viewer-only on phones instead of accidentally grabbing the camera.
bool get isMobileWeb =>
    kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Default signaling server URL. Resolved in this order:
///   1. `--dart-define=SIGNALING_URL=...` (overrides everything), then
///   2. on **web**, the page's own origin — because the web app is served BY the
///      signaling server, so same-origin "just works" in production, and then
///   3. the deployed server, so plain `flutter run` from the IDE (no dart-define)
///      connects to production by default.
///
/// Local-server dev: type the local URL in the UI (it's editable), or pass
/// `--dart-define=SIGNALING_URL=http://127.0.0.1:3000` (USB phone also needs
/// `adb reverse tcp:3000 tcp:3000`; Android emulator uses `http://10.0.2.2:3000`).
String get defaultSignalingUrl {
  const fromEnv = String.fromEnvironment('SIGNALING_URL');
  if (fromEnv.isNotEmpty) return fromEnv;
  if (kIsWeb) return Uri.base.origin;
  return 'https://project-mask.onrender.com';
}

/// ICE servers for NAT traversal.
///
/// NOTE: the original blueprint's `stun:://google.com` is invalid. These are the
/// real, free Google public STUN servers. STUN alone fails on symmetric-NAT
/// networks (some mobile carriers), so a TURN relay is needed for full coverage.
///
/// TURN can be supplied at BUILD TIME without editing code — see docs/TURN.md:
///   flutter build apk \
///     --dart-define=TURN_URL=turn:your.host:3478 \
///     --dart-define=TURN_USERNAME=user \
///     --dart-define=TURN_CREDENTIAL=pass
/// TURN config (baked in at build time). [TURN_URL] may be a SINGLE url or a
/// COMMA-SEPARATED list so you can supply several transports that share the same
/// credentials, e.g. a UDP relay plus a TLS/443 fallback (the latter punches
/// through restrictive mobile-carrier firewalls that block the default 3478/UDP):
///   --dart-define=TURN_URL=turn:relay1.expressturn.com:3478,turns:relay1.expressturn.com:443
const String _turnUrl = String.fromEnvironment('TURN_URL');
const String _turnUsername = String.fromEnvironment('TURN_USERNAME');
const String _turnCredential = String.fromEnvironment('TURN_CREDENTIAL');

List<String> get _turnUrls => _turnUrl
    .split(',')
    .map((u) => u.trim())
    .where((u) => u.isNotEmpty)
    .toList();

List<Map<String, dynamic>> get iceServers => [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      if (_turnUrls.isNotEmpty)
        {
          'urls': _turnUrls,
          'username': _turnUsername,
          'credential': _turnCredential,
        },
    ];

/// Screen-share video tuning (applied to the host's video sender).
///
/// The encoder uses BALANCED degradation (see webrtc_service.dart), so on a
/// constrained/relayed uplink — e.g. the host on MOBILE DATA — it scales the
/// resolution down to fit the bandwidth, producing a smaller but CLEAN image
/// instead of a full-resolution blur. On a fast LAN it stays at full resolution.
///
/// FRAMERATE is the main quality knob to trade by hand: fewer frames = more bits
/// per frame = crisper text. 15 fps reads/operates well. Lower it (e.g. 10) for
/// the sharpest stills on a weak/cellular link; raise it (24–30) only on a fast
/// direct LAN where you want smoother motion. [maxVideoBitrate] is only a ceiling;
/// congestion control sets the real rate (the cellular UPLOAD speed is the true
/// limit when the host is on mobile data).
const int maxVideoBitrate = 8000000; // 8 Mbps ceiling
const int maxVideoFramerate = 15;
