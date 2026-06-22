/// App-wide configuration constants.
library;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Default signaling server URL. Resolved in this order:
///   1. `--dart-define=SIGNALING_URL=...` (used for release builds pointing at
///      the deployed server), then
///   2. on **web**, the page's own origin — because the web app is served BY the
///      signaling server, so same-origin "just works" in production, and then
///   3. a local dev default (`127.0.0.1:3000`) for native.
///
/// Dev tips: Android emulator → `http://10.0.2.2:3000`; USB phone →
/// `adb reverse tcp:3000 tcp:3000` + `127.0.0.1:3000`; local web dev → pass
/// `--dart-define=SIGNALING_URL=http://127.0.0.1:3000`. Always editable in the UI.
String get defaultSignalingUrl {
  const fromEnv = String.fromEnvironment('SIGNALING_URL');
  if (fromEnv.isNotEmpty) return fromEnv;
  if (kIsWeb) return Uri.base.origin;
  return 'http://127.0.0.1:3000';
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
const String _turnUrl = String.fromEnvironment('TURN_URL');
const String _turnUsername = String.fromEnvironment('TURN_USERNAME');
const String _turnCredential = String.fromEnvironment('TURN_CREDENTIAL');

List<Map<String, dynamic>> get iceServers => [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      if (_turnUrl.isNotEmpty)
        {
          'urls': _turnUrl,
          'username': _turnUsername,
          'credential': _turnCredential,
        },
    ];

/// Screen-share video tuning (applied to the host's video sender).
///
/// Screen content (sharp text) looks best with a high bitrate and a preference to
/// keep RESOLUTION over framerate — by default WebRTC drops resolution to hold
/// the framerate, which makes text blurry. 8 Mbps is comfortable on a LAN;
/// WebRTC automatically adapts down on constrained networks.
const int maxVideoBitrate = 8000000; // 8 Mbps
const int maxVideoFramerate = 30;
