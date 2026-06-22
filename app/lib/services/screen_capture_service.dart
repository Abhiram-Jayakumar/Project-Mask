import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Dart side of the screen-capture foreground service bridge.
///
/// The native [ScreenCaptureService] must be running before flutter_webrtc calls
/// MediaProjection, so [startService] is invoked just before `getDisplayMedia`.
/// No-ops on web (browsers don't need a foreground service; the channel doesn't
/// exist there).
class ScreenCaptureService {
  static const MethodChannel _channel = MethodChannel('project_mask/screen');

  /// Start the mediaProjection foreground service. Call BEFORE getDisplayMedia.
  static Future<void> startService() async {
    if (kIsWeb) return;
    await _channel.invokeMethod('startService');
  }

  /// Stop the foreground service when sharing ends.
  static Future<void> stopService() async {
    if (kIsWeb) return;
    await _channel.invokeMethod('stopService');
  }
}
