import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../call_controller.dart';

/// Prompt shown when the app is NOT exempt from battery optimization. Without the
/// exemption (and, on Xiaomi/MIUI, "Autostart") the OS can kill the foreground
/// service and drop the session when the app is swiped off recents. Hidden on web
/// and once the exemption is granted.
class BatteryOptimizationCard extends StatelessWidget {
  const BatteryOptimizationCard({super.key, required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || controller.ignoringBatteryOptimizations) {
      return const SizedBox.shrink();
    }
    return Card(
      color: Theme.of(context).colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.battery_alert),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Allow background running',
                      style: Theme.of(context).textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'So the session keeps running after you swipe the app away. On '
              'Xiaomi/MIUI also enable "Autostart" for Project Mask in Settings.',
              style: TextStyle(fontSize: 12),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: controller.requestBatteryOptimization,
                child: const Text('Allow'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Prominent button that ends the session for good (the only thing that does —
/// backgrounding the app keeps it alive).
class CloseSessionButton extends StatelessWidget {
  const CloseSessionButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.call_end),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.redAccent,
        side: const BorderSide(color: Colors.redAccent),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      label: const Text('Close session'),
    );
  }
}
