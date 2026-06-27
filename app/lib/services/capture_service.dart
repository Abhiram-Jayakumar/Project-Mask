import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';

/// Dart bridge for viewer-side screen capture (screenshot + video recording).
///
/// The host controls whether capture is allowed via the "Allow viewer to
/// screenshot & record" toggle. The viewer only calls these methods after
/// confirming [capturePermitted] from the WebRTC data channel.
class CaptureService {
  static const _ch = MethodChannel('project_mask/system');

  /// Start recording the viewer's device screen to an MP4.
  /// Triggers the Android system "record your screen" consent dialog.
  /// Returns true if recording started, false if the user cancelled.
  static Future<bool> startRecording() async {
    if (kIsWeb) return false;
    return await _ch.invokeMethod<bool>('startViewerRecording') ?? false;
  }

  /// Stop recording and move the MP4 to Downloads.
  /// Returns the saved path (e.g. "Downloads/recording_….mp4") or empty string.
  static Future<String> stopRecording() async {
    if (kIsWeb) return '';
    return await _ch.invokeMethod<String>('stopViewerRecording') ?? '';
  }

  /// Save [bytes] (PNG) as [filename] in Pictures/ProjectMask.
  /// Returns the saved path. Throws on failure.
  static Future<String> saveImageToGallery(
    String filename,
    Uint8List bytes,
  ) async {
    if (kIsWeb) return '';
    final result = await _ch.invokeMethod<String>('saveImageToGallery', {
      'filename': filename,
      'data': bytes,
    });
    return result ?? '';
  }
}
