import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../call_controller.dart';
import '../services/system_service.dart';
import '../widgets/anytime_access_panel.dart';
import '../widgets/connection_panel.dart';
import '../widgets/keep_alive_cards.dart';

/// Host = the device being shared/controlled. In [HostMode.quick] it opens a
/// one-off random session; in [HostMode.anytime] it shows a stable device ID +
/// permanent PIN that viewers can use to connect at any time.
class HostScreen extends StatefulWidget {
  const HostScreen({
    super.key,
    required this.serverUrl,
    this.mode = HostMode.quick,
  });

  final String serverUrl;
  final HostMode mode;

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> with WidgetsBindingObserver {
  late final CallController _controller;
  bool _closing = false; // set true only when the user ends the session

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = CallController(
      role: Role.host,
      serverUrl: widget.serverUrl,
      hostMode: widget.mode,
    );
    _controller.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check after the user returns from a system settings screen.
    if (state == AppLifecycleState.resumed) {
      _controller.refreshAccessibility();
      _controller.refreshBatteryOptimization();
    }
  }

  /// Explicit "Close session": tear down, then leave the route (which disposes
  /// the controller). [_closing] flips PopScope to allow this one pop.
  Future<void> _closeSession() async {
    await _controller.endSession();
    if (!mounted) return;
    setState(() => _closing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Don't let Back end the session; just send the app to the background so
      // the connection keeps running (like swiping off recents). Only the
      // "Close session" button ends it.
      canPop: _closing,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // With a live session, Back just backgrounds the app (keeps it running).
        // With nothing active, Back leaves the screen as usual.
        if (_controller.isSharing || _controller.peerConnected) {
          SystemService.moveTaskToBack();
        } else {
          _closeSession();
        }
      },
      child: Scaffold(
      appBar: AppBar(
          title: Text(
              widget.mode == HostMode.anytime ? 'Anytime access' : 'Host')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_controller.status,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 16),
                  BatteryOptimizationCard(controller: _controller),
                  if (_controller.peerConnected)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade800,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.visibility, color: Colors.white),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'A viewer is connected and can control this device.',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (widget.mode == HostMode.anytime)
                    AnytimeAccessPanel(controller: _controller)
                  else
                    Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          const Text('Your session ID'),
                          const SizedBox(height: 8),
                          SelectableText(
                            _controller.sessionId ?? '—',
                            style: const TextStyle(
                                fontSize: 34,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 2),
                          ),
                          if (_controller.sessionPin != null) ...[
                            const SizedBox(height: 8),
                            Text('PIN',
                                style: Theme.of(context).textTheme.bodySmall),
                            SelectableText(
                              _controller.sessionPin!,
                              style: const TextStyle(
                                  fontSize: 26,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 6),
                            ),
                          ],
                          if (_controller.sessionId != null)
                            TextButton.icon(
                              onPressed: () => Clipboard.setData(ClipboardData(
                                  text:
                                      'ID ${_controller.sessionId} · PIN ${_controller.sessionPin}')),
                              icon: const Icon(Icons.copy, size: 18),
                              label: const Text('Copy ID + PIN'),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Accessibility-based remote control is Android-only.
                  if (!kIsWeb && !_controller.accessibilityEnabled)
                    Card(
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: ListTile(
                        leading: const Icon(Icons.touch_app),
                        title: const Text('Enable remote control'),
                        subtitle: const Text(
                            'Turn on the Accessibility service so the viewer can tap this device.'),
                        trailing: TextButton(
                          onPressed: _controller.openAccessibilitySettings,
                          child: const Text('Open'),
                        ),
                      ),
                    )
                  else if (!kIsWeb)
                    const Card(
                      child: ListTile(
                        dense: true,
                        leading: Icon(Icons.check_circle, color: Colors.greenAccent),
                        title: Text('Remote control ready'),
                      ),
                    ),
                  const SizedBox(height: 8),
                  if (widget.mode == HostMode.quick) ...[
                    if (!_controller.isSharing)
                      FilledButton.icon(
                        onPressed: _controller.startSharing,
                        icon: const Icon(Icons.screen_share),
                        style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16)),
                        label: const Text('Start sharing my screen'),
                      )
                    else
                      FilledButton.icon(
                        onPressed: _controller.stopSharing,
                        icon: const Icon(Icons.stop_screen_share),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        label: const Text('Stop sharing'),
                      ),
                    const SizedBox(height: 8),
                  ],
                  CloseSessionButton(onPressed: _closeSession),
                  const SizedBox(height: 8),
                  Expanded(child: ConnectionPanel(controller: _controller)),
                ],
              );
            },
          ),
        ),
      ),
      ),
    );
  }
}
