import 'package:flutter/material.dart';

import '../call_controller.dart';
import '../config.dart';
import 'host_screen.dart';
import 'viewer_screen.dart';

/// Landing screen: pick a role and (optionally) edit the signaling server URL.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _urlController =
      TextEditingController(text: defaultSignalingUrl);

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _open(Role role) {
    final url = _urlController.text.trim();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => role == Role.host
          ? HostScreen(serverUrl: url)
          : ViewerScreen(serverUrl: url),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 32),
              const Icon(Icons.cast_connected, size: 64),
              const SizedBox(height: 16),
              Text('Project Mask',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text('Open-source remote desktop',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium),
              const Spacer(),
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'Signaling server URL',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.dns),
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: isMobileWeb ? null : () => _open(Role.host),
                icon: const Icon(Icons.screen_share),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 18)),
                label: const Text('Share my screen (Host)'),
              ),
              if (isMobileWeb)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    "Mobile browsers can't capture the screen. Install the Android "
                    'app to share this phone; the web app works as a viewer.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _open(Role.viewer),
                icon: const Icon(Icons.visibility),
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 18)),
                label: const Text('Control a device (Viewer)'),
              ),
              const Spacer(),
              Text(
                'Only connect to devices you own or have permission to access.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
            ),
          ),
        ),
      ),
    );
  }
}
