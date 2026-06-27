import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../call_controller.dart';

/// Bottom-sheet panel showing the host's live position on a map with the full
/// travel route drawn as a polyline, plus a battery badge overlay.
///
/// Open it via [LocationMapPanel.show]. Works on mobile and Flutter web.
class LocationMapPanel extends StatefulWidget {
  const LocationMapPanel({super.key, required this.controller});

  final CallController controller;

  static void show(BuildContext context, CallController controller) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => LocationMapPanel(controller: controller),
    );
  }

  @override
  State<LocationMapPanel> createState() => _LocationMapPanelState();
}

class _LocationMapPanelState extends State<LocationMapPanel> {
  final _mapController = MapController();
  bool _following = true; // auto-center on the latest fix

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (ctx, _) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: Scaffold(
            body: Column(
              children: [
                _DragHandle(),
                _Header(controller: widget.controller),
                Expanded(
                  child: ListenableBuilder(
                    listenable: widget.controller,
                    builder: (_, _) => _MapBody(
                      controller: widget.controller,
                      mapController: _mapController,
                      following: _following,
                      onGesture: () => setState(() => _following = false),
                      onRecenter: () => setState(() => _following = true),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DragHandle extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      child: Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.grey.shade400,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(
        children: [
          const Icon(Icons.route, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Host travel route',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListenableBuilder(
            listenable: controller,
            builder: (_, _) {
              final pts = controller.locationHistory.length;
              return Text(
                '$pts point${pts == 1 ? '' : 's'}',
                style: Theme.of(context).textTheme.bodySmall,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MapBody extends StatelessWidget {
  const _MapBody({
    required this.controller,
    required this.mapController,
    required this.following,
    required this.onGesture,
    required this.onRecenter,
  });

  final CallController controller;
  final MapController mapController;
  final bool following;
  final VoidCallback onGesture;
  final VoidCallback onRecenter;

  @override
  Widget build(BuildContext context) {
    final current = controller.hostLocation;
    final history = controller.locationHistory;
    final battery = controller.hostBattery;
    final charging = controller.hostBatteryCharging;

    // Auto-follow the latest position.
    if (following && current != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        try {
          mapController.move(LatLng(current.lat, current.lng), mapController.camera.zoom);
        } catch (_) {}
      });
    }

    final points = history.map((p) => LatLng(p.lat, p.lng)).toList();
    final center = current != null
        ? LatLng(current.lat, current.lng)
        : const LatLng(20.5937, 78.9629); // India center fallback

    return Stack(
      children: [
        FlutterMap(
          mapController: mapController,
          options: MapOptions(
            initialCenter: center,
            initialZoom: 15.0,
            onPositionChanged: (_, hasGesture) {
              if (hasGesture) onGesture();
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.projectmask.project_mask',
            ),
            if (points.length > 1)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: points,
                    color: const Color(0xFF4F46E5), // indigo
                    strokeWidth: 4.5,
                  ),
                ],
              ),
            if (points.isNotEmpty)
              CircleLayer(
                circles: [
                  CircleMarker(
                    point: points.first,
                    radius: 6,
                    color: Colors.green,
                    borderColor: Colors.white,
                    borderStrokeWidth: 2,
                  ),
                ],
              ),
            if (current != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: LatLng(current.lat, current.lng),
                    width: 36,
                    height: 36,
                    child: const _PulsingDot(),
                  ),
                ],
              ),
          ],
        ),

        // Battery badge — top-left.
        if (battery != null)
          Positioned(
            top: 10,
            left: 10,
            child: _BatteryBadge(pct: battery, charging: charging),
          ),

        // Re-center FAB — bottom-right.
        if (!following && current != null)
          Positioned(
            bottom: 12,
            right: 12,
            child: FloatingActionButton.small(
              heroTag: 'loc_recenter',
              onPressed: () {
                onRecenter();
                mapController.move(LatLng(current.lat, current.lng), 15.0);
              },
              child: const Icon(Icons.my_location),
            ),
          ),

        // "No location" placeholder.
        if (current == null)
          Center(
            child: Card(
              margin: const EdgeInsets.all(32),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.location_searching,
                      size: 40,
                      color: Colors.grey.shade400,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      controller.locationAvailable
                          ? 'Waiting for host GPS fix…'
                          : 'Host has not enabled location sharing.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Pulsing blue dot indicating the current (live) position.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const core = Color(0xFF4F46E5);
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, _) => Stack(
        alignment: Alignment.center,
        children: [
          // Expanding ring
          Container(
            width: 18 + 18 * _anim.value,
            height: 18 + 18 * _anim.value,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: core.withValues(alpha: 0.25 * (1 - _anim.value)),
            ),
          ),
          // Solid dot
          Container(
            width: 16,
            height: 16,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: core,
            ),
          ),
          // White centre
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pill showing battery percentage with a colour-coded icon.
class _BatteryBadge extends StatelessWidget {
  const _BatteryBadge({required this.pct, required this.charging});

  final int pct;
  final bool charging;

  @override
  Widget build(BuildContext context) {
    final color = pct > 50
        ? Colors.greenAccent
        : pct > 20
            ? Colors.orange
            : Colors.redAccent;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_iconFor(pct, charging), color: color, size: 16),
          const SizedBox(width: 5),
          Text(
            '$pct%',
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (charging) ...[
            const SizedBox(width: 3),
            const Icon(Icons.bolt, color: Colors.yellow, size: 12),
          ],
        ],
      ),
    );
  }

  IconData _iconFor(int pct, bool charging) {
    if (charging) return Icons.battery_charging_full;
    if (pct > 80) return Icons.battery_full;
    if (pct > 60) return Icons.battery_5_bar;
    if (pct > 40) return Icons.battery_3_bar;
    if (pct > 20) return Icons.battery_2_bar;
    return Icons.battery_0_bar;
  }
}
