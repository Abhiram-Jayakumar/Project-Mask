import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../call_controller.dart';

/// HOST "anytime access" controls: shows the stable device ID, lets the user set
/// a permanent PIN, and arm/disarm the device so viewers with the ID + PIN can
/// connect at any time (Chrome-Remote-Desktop style).
class AnytimeAccessPanel extends StatefulWidget {
  const AnytimeAccessPanel({super.key, required this.controller});

  final CallController controller;

  @override
  State<AnytimeAccessPanel> createState() => _AnytimeAccessPanelState();
}

class _AnytimeAccessPanelState extends State<AnytimeAccessPanel> {
  final TextEditingController _pinController = TextEditingController();
  bool _editingPin = false;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _savePin() async {
    final pin = _pinController.text.trim();
    if (pin.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PIN must be at least 6 digits')),
      );
      return;
    }
    await widget.controller.setPermanentPin(pin);
    _pinController.clear();
    if (mounted) setState(() => _editingPin = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final showPinField = _editingPin || !c.hasPin;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Anytime access', textAlign: TextAlign.center),
            const SizedBox(height: 4),
            const Text(
              'Share this device ID + your PIN. Anyone with both can connect '
              'while this device is allowing connections.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            const Text('Device ID', textAlign: TextAlign.center),
            const SizedBox(height: 4),
            SelectableText(
              c.deviceId ?? '—',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 30, fontWeight: FontWeight.bold, letterSpacing: 2),
            ),
            if (c.deviceId != null)
              TextButton.icon(
                onPressed: () => Clipboard.setData(
                    ClipboardData(text: c.deviceId!)),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy ID'),
              ),
            const Divider(height: 24),

            // --- PIN ---
            if (showPinField) ...[
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 8,
                decoration: InputDecoration(
                  labelText: c.hasPin ? 'New PIN (min 6 digits)' : 'Set a PIN (min 6 digits)',
                  border: const OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: _savePin,
                      child: Text(c.hasPin ? 'Save new PIN' : 'Set PIN'),
                    ),
                  ),
                  if (c.hasPin) ...[
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => setState(() => _editingPin = false),
                      child: const Text('Cancel'),
                    ),
                  ],
                ],
              ),
            ] else
              Row(
                children: [
                  const Icon(Icons.lock, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('PIN is set')),
                  TextButton(
                    onPressed: () => setState(() => _editingPin = true),
                    child: const Text('Change PIN'),
                  ),
                ],
              ),
            const SizedBox(height: 8),

            // --- Arm / disarm ---
            if (!c.armed)
              FilledButton.icon(
                onPressed: c.hasPin ? c.armDevice : null,
                icon: const Icon(Icons.lock_open),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                label: const Text('Allow remote connections'),
              )
            else ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.green.shade800,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.white, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Allowing connections — anyone with the ID + PIN can '
                        'connect now.',
                        style: TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: c.disarmDevice,
                icon: const Icon(Icons.lock),
                label: const Text('Stop allowing connections'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
