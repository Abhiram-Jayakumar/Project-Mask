import 'dart:convert';
import 'dart:math';

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
  static const _kDeviceId = 'device_id'; // stable id for anytime access
  static const _kDevicePinSalt = 'device_pin_salt';
  static const _kDevicePinHash = 'device_pin_hash';
  static const _maxHistory = 10;

  // ---- Anytime access: this device's STABLE id + permanent PIN ----
  /// The device's permanent 9-digit id (generated once, reused forever) used for
  /// "anytime access". Created and persisted on first call.
  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_kDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = _randomDeviceId();
    await prefs.setString(_kDeviceId, id);
    return id;
  }

  /// Replace the device id (used if the server reports a collision).
  static Future<String> regenerateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = _randomDeviceId();
    await prefs.setString(_kDeviceId, id);
    return id;
  }

  static String _randomDeviceId() =>
      '${100000000 + Random.secure().nextInt(900000000)}';

  /// Store the permanent PIN as a salted hash (never the plaintext).
  static Future<void> saveDevicePin(String salt, String hash) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDevicePinSalt, salt);
    await prefs.setString(_kDevicePinHash, hash);
  }

  /// Returns (salt, hash) if a permanent PIN has been set, else null.
  static Future<({String salt, String hash})?> getDevicePin() async {
    final prefs = await SharedPreferences.getInstance();
    final salt = prefs.getString(_kDevicePinSalt);
    final hash = prefs.getString(_kDevicePinHash);
    if (salt == null || hash == null) return null;
    return (salt: salt, hash: hash);
  }

  static Future<bool> hasDevicePin() async => (await getDevicePin()) != null;

  static Future<void> clearDevicePin() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDevicePinSalt);
    await prefs.remove(_kDevicePinHash);
  }

  // ---- Boot restore: persist armed state so native BootReceiver can detect it ----
  static const _kAnytimeArmed = 'anytime_armed';
  static const _kBootRestorePending = 'boot_restore_pending';
  static const _kCameraAllowed = 'camera_allowed';
  static const _kMicAllowed = 'mic_allowed';
  static const _kLocationAllowed = 'location_allowed';

  /// Persist the host's "let the viewer see/hear/locate me" choices so they
  /// survive a reboot — after re-arming the host doesn't have to re-toggle.
  static Future<void> setMediaPrefs({
    required bool camera,
    required bool mic,
    required bool location,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kCameraAllowed, camera);
    await prefs.setBool(_kMicAllowed, mic);
    await prefs.setBool(_kLocationAllowed, location);
  }

  static Future<({bool camera, bool mic, bool location})> getMediaPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      camera: prefs.getBool(_kCameraAllowed) ?? false,
      mic: prefs.getBool(_kMicAllowed) ?? false,
      location: prefs.getBool(_kLocationAllowed) ?? false,
    );
  }

  /// Write whether anytime access is currently armed. Called by [CallController]
  /// on arm/disarm so the OS can detect the state after a device reboot.
  static Future<void> setArmedState(bool armed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAnytimeArmed, armed);
  }

  /// Returns true (and clears the flag) when the native [BootReceiver] has
  /// signalled that the device restarted while anytime access was armed. Calls
  /// [SharedPreferences.reload] so it sees values written by native code after
  /// the Flutter engine was already running.
  static Future<bool> popBootRestorePending() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final pending = prefs.getBool(_kBootRestorePending) ?? false;
    if (pending) await prefs.remove(_kBootRestorePending);
    return pending;
  }

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

  // ---- Host: permitted folders for viewer file access ----
  static const _kPermittedFolders = 'permitted_folders';

  static Future<List<String>> getPermittedFolders() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_kPermittedFolders) ?? [];
  }

  static Future<void> setPermittedFolders(List<String> folders) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kPermittedFolders, folders);
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
