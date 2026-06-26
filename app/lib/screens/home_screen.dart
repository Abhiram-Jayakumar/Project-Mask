import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../call_controller.dart';
import '../config.dart';
import '../services/session_store.dart';
import 'host_screen.dart';
import 'viewer_screen.dart';

/// Landing screen: pick a role and (optionally) edit the signaling server URL.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final TextEditingController _urlController =
      TextEditingController(text: defaultSignalingUrl);

  /// Prevents concurrent or re-entrant calls to [_checkBootRestore].
  bool _checkingRestore = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Check on first frame — handles a fresh cold start from the notification.
    _checkBootRestore();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Check whenever the app comes to the foreground — handles the case where
    // the engine was already running in the background and the user taps the
    // boot-restore notification.
    if (state == AppLifecycleState.resumed) _checkBootRestore();
  }

  /// If the native [BootReceiver] wrote a restore request (device rebooted
  /// while anytime access was armed), navigate straight to the HostScreen in
  /// anytime mode with [autoArm] so the MediaProjection dialog fires
  /// automatically — the only tap we can't eliminate on Android.
  Future<void> _checkBootRestore() async {
    if (kIsWeb || _checkingRestore) return;
    _checkingRestore = true;
    try {
      final shouldArm = await SessionStore.popBootRestorePending();
      if (!shouldArm || !mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => HostScreen(
          serverUrl: _urlController.text.trim(),
          mode: HostMode.anytime,
          autoArm: true,
        ),
      ));
    } finally {
      _checkingRestore = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

  void _openAnytime() {
    final url = _urlController.text.trim();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => HostScreen(serverUrl: url, mode: HostMode.anytime),
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
              Text('Sim Tool',
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
                onPressed: isMobileWeb ? null : _openAnytime,
                icon: const Icon(Icons.lock_clock),
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 18)),
                label: const Text('Anytime access (set up once)'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _open(Role.viewer),
                icon: const Icon(Icons.visibility),
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 18)),
                label: const Text('View a device (Viewer)'),
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
