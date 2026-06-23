import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Dart side of the generic keep-alive foreground service used by the VIEWER.
///
/// Started once the viewer's peer connection is up so the process (and the
/// persistent Flutter engine) stays alive if the app is swiped off recents, and
/// stopped when the session is explicitly closed. The host doesn't need this —
/// its [ScreenCaptureService] already keeps the process alive while sharing.
/// No-ops on web.
class ConnectionService {
  static const MethodChannel _channel = MethodChannel('project_mask/session');

  /// Start the keep-alive foreground service (viewer).
  static Future<void> startKeepAlive() async {
    if (kIsWeb) return;
    await _channel.invokeMethod('startKeepAlive');
  }

  /// Stop the keep-alive foreground service when the session ends.
  static Future<void> stopKeepAlive() async {
    if (kIsWeb) return;
    await _channel.invokeMethod('stopKeepAlive');
  }
}
