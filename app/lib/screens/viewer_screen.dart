import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../call_controller.dart';
import '../services/system_service.dart';
import '../widgets/connection_panel.dart';
import '../widgets/keep_alive_cards.dart';
import '../widgets/remote_control_surface.dart';

/// Viewer = the controlling device. Enters a session ID + PIN, watches the host's
/// screen, and sends control events over the data channel.
///
/// The layout is responsive: content is centered in a phone-width column and the
/// remote screen is shown inside a phone-shaped frame sized to fit the window, so
/// it looks right on a wide desktop browser as well as on a phone.
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, required this.serverUrl});

  final String serverUrl;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> with WidgetsBindingObserver {
  late final CallController _controller;
  final TextEditingController _idController = TextEditingController();
  final TextEditingController _pinController = TextEditingController();
  bool _closing = false;    // set true only when the user ends the session
  bool _fullscreen = false; // true → video fills screen, system bars hidden

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = CallController(role: Role.viewer, serverUrl: widget.serverUrl);
    _controller.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
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

  void _enterFullscreen() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    setState(() => _fullscreen = true);
  }

  void _exitFullscreen() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    setState(() => _fullscreen = false);
  }

  @override
  void dispose() {
    // Always restore system UI when leaving the viewer.
    if (_fullscreen) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _idController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back doesn't end the session; it backgrounds the app so the connection
      // keeps running. Only the "Close session" button ends it.
      canPop: _closing,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // Fullscreen → Back exits fullscreen first (doesn't leave the screen).
        if (_fullscreen) {
          _exitFullscreen();
          return;
        }
        // Connected → Back backgrounds the app (keeps the session running);
        // otherwise Back leaves the screen as usual.
        if (_controller.peerConnected) {
          SystemService.moveTaskToBack();
        } else {
          _closeSession();
        }
      },
      child: Scaffold(
        // AppBar is hidden in fullscreen; the exit button replaces it.
        appBar: _fullscreen ? null : AppBar(title: const Text('Viewer')),
        body: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            // ── Fullscreen mode ─────────────────────────────────────────────
            if (_fullscreen) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: Colors.black,
                    child: RemoteControlSurface(
                      renderer: _controller.remoteRenderer,
                      onTouch: _controller.sendTouch,
                    ),
                  ),
                  // Exit-fullscreen button — top-right, semi-transparent.
                  Positioned(
                    top: 20,
                    right: 16,
                    child: _CircleIconButton(
                      icon: Icons.fullscreen_exit,
                      onTap: _exitFullscreen,
                    ),
                  ),
                ],
              );
            }

            // ── Normal mode ─────────────────────────────────────────────────
            final connected = _controller.peerConnected;
            return SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  // Center the UI in a phone-width column on wide screens.
                  const columnMaxWidth = 480.0;
                  final availableWidth =
                      (constraints.maxWidth < columnMaxWidth
                              ? constraints.maxWidth
                              : columnMaxWidth) -
                          32;

                  // Size the phone frame to the real video aspect ratio, fitting
                  // within the available width and ~70% of the viewport height.
                  final frameMaxHeight =
                      (constraints.maxHeight * 0.70).clamp(260.0, 760.0);
                  final aspect = _controller.remoteRenderer.value.aspectRatio;
                  final videoAspect = aspect > 0 ? aspect : 9 / 16;
                  double frameW = availableWidth;
                  double frameH = frameW / videoAspect;
                  if (frameH > frameMaxHeight) {
                    frameH = frameMaxHeight;
                    frameW = frameH * videoAspect;
                  }

                  return Center(
                    child: ConstrainedBox(
                      constraints:
                          const BoxConstraints(maxWidth: columnMaxWidth),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(_controller.status,
                                style:
                                    Theme.of(context).textTheme.titleMedium),
                            const SizedBox(height: 12),
                            BatteryOptimizationCard(controller: _controller),
                            if (!connected) ...[
                              _ConnectFields(
                                idController: _idController,
                                pinController: _pinController,
                                enabled: _controller.signalingConnected,
                                onConnect: () => _controller.joinAsViewer(
                                    _idController.text, _pinController.text),
                              ),
                              if (_controller.recentSessions.isNotEmpty) ...[
                                const SizedBox(height: 16),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text('Recent sessions',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge),
                                ),
                                const SizedBox(height: 4),
                                ..._controller.recentSessions.take(5).map(
                                      (s) => Card(
                                        margin: const EdgeInsets.symmetric(
                                            vertical: 2),
                                        child: ListTile(
                                          dense: true,
                                          leading: const Icon(Icons.history),
                                          title: Text('ID ${s.id}'),
                                          subtitle: Text('PIN ${s.pin}'),
                                          trailing: const Icon(Icons.login),
                                          onTap: _controller.signalingConnected
                                              ? () {
                                                  _idController.text = s.id;
                                                  _pinController.text = s.pin;
                                                  _controller.joinAsViewer(
                                                      s.id, s.pin);
                                                }
                                              : null,
                                        ),
                                      ),
                                    ),
                              ],
                              const SizedBox(height: 16),
                            ],
                            // Phone-shaped frame with the remote screen.
                            // Stack adds the fullscreen-enter button as an
                            // overlay at the bottom-right of the frame.
                            Center(
                              child: Stack(
                                alignment: Alignment.bottomRight,
                                children: [
                                  SizedBox(
                                    width: frameW,
                                    height: frameH,
                                    child: Container(
                                      padding: const EdgeInsets.all(6),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF0E0E10),
                                        borderRadius:
                                            BorderRadius.circular(28),
                                        boxShadow: const [
                                          BoxShadow(
                                              color: Colors.black54,
                                              blurRadius: 16),
                                        ],
                                      ),
                                      child: ClipRRect(
                                        borderRadius:
                                            BorderRadius.circular(22),
                                        child: ColoredBox(
                                          color: Colors.black,
                                          child: RemoteControlSurface(
                                            renderer:
                                                _controller.remoteRenderer,
                                            onTouch: _controller.sendTouch,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  // Enter-fullscreen button overlaid on frame.
                                  Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: _CircleIconButton(
                                      icon: Icons.fullscreen,
                                      onTap: _enterFullscreen,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              connected
                                  ? 'Tap or drag the phone screen to control it'
                                  : 'Connect to a host to begin',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              onPressed: _controller.dataChannelOpen
                                  ? _controller.sendTestPing
                                  : null,
                              icon: const Icon(Icons.network_ping),
                              label: const Text('Send test ping'),
                            ),
                            const SizedBox(height: 12),
                            CloseSessionButton(onPressed: _closeSession),
                            const SizedBox(height: 12),
                            SizedBox(
                              height: 200,
                              child: ConnectionPanel(controller: _controller),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Semi-transparent circular icon button used for the fullscreen toggle.
class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: Icon(icon, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

/// Session ID + PIN entry with a Connect button.
class _ConnectFields extends StatelessWidget {
  const _ConnectFields({
    required this.idController,
    required this.pinController,
    required this.enabled,
    required this.onConnect,
  });

  final TextEditingController idController;
  final TextEditingController pinController;
  final bool enabled;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              flex: 2,
              child: TextField(
                controller: idController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Session ID',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 1,
              child: TextField(
                controller: pinController,
                keyboardType: TextInputType.number,
                // Accepts the 4-digit quick-session PIN and the 6–8 digit
                // permanent "anytime access" PIN.
                maxLength: 8,
                decoration: const InputDecoration(
                  labelText: 'PIN',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: enabled ? onConnect : null,
            child: const Text('Connect'),
          ),
        ),
      ],
    );
  }
}
