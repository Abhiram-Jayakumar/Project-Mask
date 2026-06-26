import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Dart bridge for OS-level behaviors that help a session survive the app being
/// removed from recents: battery-optimization exemption (so aggressive OEMs don't
/// reap the foreground service) and sending the task to the background instead of
/// tearing it down. All methods no-op / return safe defaults on web.
class SystemService {
  static const MethodChannel _channel = MethodChannel('project_mask/system');

  /// Whether the app is currently exempt from battery optimization. Returns true
  /// on web / pre-M where the concept doesn't apply.
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (kIsWeb) return true;
    final result =
        await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
    return result ?? false;
  }

  /// Prompt the user to exempt the app from battery optimization.
  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (kIsWeb) return;
    await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
  }

  /// Send the app to the background (like Home) instead of finishing the task,
  /// so the session keeps running. Used to intercept the system Back button.
  static Future<void> moveTaskToBack() async {
    if (kIsWeb) return;
    await _channel.invokeMethod('moveTaskToBack');
  }

  /// Prompt for the camera permission once (at setup, while the host is present)
  /// so the on-demand camera never has to disturb the host again.
  static Future<void> requestCameraPermission() async {
    if (kIsWeb) return;
    await _channel.invokeMethod('requestCameraPermission');
  }

  /// Prompt for the microphone permission once (at setup).
  static Future<void> requestMicPermission() async {
    if (kIsWeb) return;
    await _channel.invokeMethod('requestMicPermission');
  }

  /// Request storage read access for the host's shared-files feature.
  /// On Android ≤ 12 this shows the READ_EXTERNAL_STORAGE runtime dialog;
  /// on Android 13+ it opens the All Files Access settings page.
  static Future<void> requestStoragePermission() async {
    if (kIsWeb) return;
    await _channel.invokeMethod('requestStoragePermission');
  }

  /// Save [bytes] as [filename] in the device's public Downloads folder.
  /// Returns the saved path (e.g. "Downloads/file.txt") on success.
  /// Throws on failure. No-op on web (returns empty string).
  static Future<String> saveFileToDownloads(String filename, Uint8List bytes) async {
    if (kIsWeb) return '';
    final result = await _channel.invokeMethod<String>('saveToDownloads', {
      'filename': filename,
      'data': bytes,
    });
    return result ?? 'Downloads/$filename';
  }
}
