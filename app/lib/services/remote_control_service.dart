import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Dart side of the remote-control bridge (host device).
///
/// Forwards normalized touch coordinates to the native [RemoteAccessibilityService]
/// and exposes helpers to check / open the accessibility settings the user must
/// enable before remote control works. All methods no-op on web (no native
/// channel + a browser can't inject OS-level gestures).
class RemoteControlService {
  static const MethodChannel _channel = MethodChannel('project_mask/control');

  /// Inject a gesture on this device. Returns false if the accessibility service
  /// isn't enabled (so the UI can prompt the user).
  static Future<bool> sendGesture(String type, double x, double y) async {
    if (kIsWeb) return false;
    final ok = await _channel.invokeMethod<bool>('gesture', {
      't': type,
      'x': x,
      'y': y,
    });
    return ok ?? false;
  }

  static Future<bool> isAccessibilityEnabled() async {
    if (kIsWeb) return false;
    final enabled =
        await _channel.invokeMethod<bool>('isAccessibilityEnabled');
    return enabled ?? false;
  }

  static Future<void> openAccessibilitySettings() async {
    if (kIsWeb) return;
    await _channel.invokeMethod('openAccessibilitySettings');
  }
}
