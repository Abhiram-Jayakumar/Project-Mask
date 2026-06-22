import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A remembered session (id + pin + when it was last used).
class SessionEntry {
  SessionEntry(this.id, this.pin, this.timestamp);

  final String id;
  final String pin;
  final int timestamp;

  Map<String, dynamic> toJson() => {'id': id, 'pin': pin, 'ts': timestamp};

  factory SessionEntry.fromJson(Map<String, dynamic> json) => SessionEntry(
        json['id'] as String,
        json['pin'] as String? ?? '',
        (json['ts'] as num?)?.toInt() ?? 0,
      );
}

/// Persists session info so users can rejoin after an accidental disconnect.
/// Backed by shared_preferences (uses localStorage on web — works everywhere).
class SessionStore {
  static const _kViewerHistory = 'viewer_history';
  static const _kHostSession = 'host_session';
  static const _maxHistory = 10;

  // ---- Viewer: history of sessions this device connected to ----
  static Future<List<SessionEntry>> getViewerHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kViewerHistory);
    if (raw == null) return [];
    final decoded = jsonDecode(raw) as List;
    return decoded
        .map((e) => SessionEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  static Future<void> addViewerHistory(String id, String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await getViewerHistory()
      ..removeWhere((e) => e.id == id); // de-dupe, keep most recent
    list.insert(0, SessionEntry(id, pin, DateTime.now().millisecondsSinceEpoch));
    final trimmed = list.take(_maxHistory).toList();
    await prefs.setString(
      _kViewerHistory,
      jsonEncode(trimmed.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> clearViewerHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kViewerHistory);
  }

  // ---- Host: the device's own last session (for reclaim after a drop) ----
  static Future<void> saveHostSession(String id, String pin) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kHostSession,
      jsonEncode(
          SessionEntry(id, pin, DateTime.now().millisecondsSinceEpoch).toJson()),
    );
  }

  static Future<SessionEntry?> getHostSession() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kHostSession);
    if (raw == null) return null;
    return SessionEntry.fromJson(Map<String, dynamic>.from(jsonDecode(raw)));
  }

  static Future<void> clearHostSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kHostSession);
  }
}
