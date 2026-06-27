import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

class LocationUpdate {
  const LocationUpdate({
    required this.lat,
    required this.lng,
    required this.accuracy,
  });
  final double lat;
  final double lng;
  final double accuracy;
}

/// Thin singleton that streams GPS fixes and battery readings to its callers.
///
/// GPS toggle-resilient: [Geolocator.getServiceStatusStream] watches the
/// system location switch. When GPS is turned off mid-session the position
/// stream is paused silently; when it is turned back on (with the session
/// still active) the stream restarts automatically — no action needed from
/// [CallController] or the UI.
class LocationService {
  LocationService._();

  static final _battery = Battery();
  static StreamSubscription<Position>? _positionSub;
  static StreamSubscription<ServiceStatus>? _serviceStatusSub;
  static StreamSubscription<BatteryState>? _batteryStateSub;
  static Timer? _batteryTimer;

  static void Function(LocationUpdate)? onLocation;
  static void Function(int pct, bool charging)? onBattery;

  /// Request location permission (does NOT check if GPS is currently on —
  /// that is handled by the service-status watcher inside [startTracking]).
  static Future<bool> requestPermission() async {
    if (kIsWeb) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;
  }

  /// Start the full tracking session: GPS stream + battery reports.
  ///
  /// If GPS is currently off the position stream is not started, but the
  /// service-status watcher will start it the moment GPS is re-enabled.
  /// Silently does nothing on web or when permission is denied.
  static Future<void> startTracking() async {
    if (kIsWeb) return;
    final granted = await requestPermission();
    if (!granted) return;

    // Watch the system GPS toggle for the lifetime of this tracking session.
    _serviceStatusSub?.cancel();
    _serviceStatusSub = Geolocator.getServiceStatusStream().listen((status) {
      if (status == ServiceStatus.enabled) {
        // GPS turned back on while session is still active — resume stream.
        _startPositionStream();
      } else {
        // GPS turned off — pause silently; viewer keeps the last known position.
        _positionSub?.cancel();
        _positionSub = null;
      }
    });

    // Start the position stream now only if GPS is already on.
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (serviceEnabled) _startPositionStream();

    // Battery: immediate read, then on state changes, then every 60 s.
    await _emitBattery();
    _batteryStateSub?.cancel();
    _batteryStateSub =
        _battery.onBatteryStateChanged.listen((_) => _emitBattery());
    _batteryTimer?.cancel();
    _batteryTimer =
        Timer.periodic(const Duration(seconds: 60), (_) => _emitBattery());
  }

  /// (Re)create the position subscription. Safe to call while one is running
  /// (cancels the old one first).
  static void _startPositionStream() {
    _positionSub?.cancel();
    _positionSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10, // metres
      ),
    ).listen(
      (pos) => onLocation?.call(
        LocationUpdate(
          lat: pos.latitude,
          lng: pos.longitude,
          accuracy: pos.accuracy,
        ),
      ),
      onError: (_) {
        // Permission revoked at runtime or a race between the service-status
        // event and the stream starting — drop the dead subscription so the
        // next ServiceStatus.enabled event creates a fresh one.
        _positionSub?.cancel();
        _positionSub = null;
      },
      cancelOnError: true,
    );
  }

  static Future<void> _emitBattery() async {
    try {
      final pct = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      final charging =
          state == BatteryState.charging || state == BatteryState.full;
      onBattery?.call(pct, charging);
    } catch (_) {}
  }

  /// Stop all streams and timers. Called when the host disarms, the peer
  /// leaves, or the session ends.
  static void stopTracking() {
    _serviceStatusSub?.cancel();
    _serviceStatusSub = null;
    _positionSub?.cancel();
    _positionSub = null;
    _batteryStateSub?.cancel();
    _batteryStateSub = null;
    _batteryTimer?.cancel();
    _batteryTimer = null;
  }
}
