import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A single notification received from the host device.
class NotifEntry {
  const NotifEntry({
    required this.app,
    required this.pkg,
    required this.title,
    required this.text,
    required this.time,
  });

  final String app;   // human-readable app label, e.g. "Instagram"
  final String pkg;   // package name, e.g. "com.instagram.android"
  final String title;
  final String text;
  final int time;     // milliseconds since epoch
}

/// Dart bridge for [NotificationMirrorService] (Android side).
///
/// Subscribes to the [EventChannel] pushed by the native service and forwards
/// each notification to [onNotification]. All filtering (SMS, OTP, system UI)
/// is done in Kotlin; this class just routes the raw payload.
class NotificationMirrorService {
  static const _eventCh = EventChannel('project_mask/notifications');
  static const _sysCh   = MethodChannel('project_mask/system');

  static StreamSubscription? _sub;

  /// Called for every incoming notification while listening is active.
  static void Function(NotifEntry)? onNotification;

  /// Returns true when the user has granted notification access in Settings.
  static Future<bool> isAccessGranted() async {
    if (kIsWeb) return false;
    try {
      return await _sysCh.invokeMethod<bool>('isNotificationAccessGranted') ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Opens Settings › Apps › Special app access › Notification access so the
  /// user can grant the permission (can't be granted programmatically).
  static Future<void> requestAccess() async {
    if (kIsWeb) return;
    await _sysCh.invokeMethod('requestNotificationAccess');
  }

  /// Start receiving notification events from the native service. Safe to call
  /// multiple times — cancels any previous subscription first.
  static void startListening() {
    if (kIsWeb) return;
    _sub?.cancel();
    _sub = _eventCh.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        final e = NotifEntry(
          app:   event['app']   as String? ?? '',
          pkg:   event['pkg']   as String? ?? '',
          title: event['title'] as String? ?? '',
          text:  event['text']  as String? ?? '',
          time:  (event['time'] as int?) ??
              DateTime.now().millisecondsSinceEpoch,
        );
        onNotification?.call(e);
      },
      onError: (_) {},
    );
  }

  /// Stop receiving notification events (clears the callback too).
  static void stopListening() {
    _sub?.cancel();
    _sub = null;
  }
}
