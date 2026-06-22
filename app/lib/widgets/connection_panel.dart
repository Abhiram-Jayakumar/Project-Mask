import 'package:flutter/material.dart';

import '../call_controller.dart';

/// Shared status chips + scrolling event log used by both host and viewer.
class ConnectionPanel extends StatelessWidget {
  const ConnectionPanel({super.key, required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _StatusChip(label: 'Signaling', on: controller.signalingConnected),
            _StatusChip(label: 'Peer (P2P)', on: controller.peerConnected),
            _StatusChip(label: 'Data channel', on: controller.dataChannelOpen),
          ],
        ),
        const SizedBox(height: 12),
        Text('Event log', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.builder(
              reverse: true,
              itemCount: controller.log.length,
              itemBuilder: (_, i) => Text(
                controller.log[i],
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12, height: 1.4),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.on});

  final String label;
  final bool on;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(
        on ? Icons.check_circle : Icons.radio_button_unchecked,
        color: on ? Colors.greenAccent : Colors.grey,
        size: 18,
      ),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}
