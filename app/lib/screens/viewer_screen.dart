import 'package:flutter/material.dart';

import '../call_controller.dart';
import '../widgets/connection_panel.dart';
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

class _ViewerScreenState extends State<ViewerScreen> {
  late final CallController _controller;
  final TextEditingController _idController = TextEditingController();
  final TextEditingController _pinController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller = CallController(role: Role.viewer, serverUrl: widget.serverUrl);
    _controller.start();
  }

  @override
  void dispose() {
    _controller.dispose();
    _idController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Viewer')),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final connected = _controller.peerConnected;
            return LayoutBuilder(
              builder: (context, constraints) {
                // Center the UI in a phone-width column on wide screens.
                const columnMaxWidth = 480.0;
                final availableWidth =
                    (constraints.maxWidth < columnMaxWidth
                            ? constraints.maxWidth
                            : columnMaxWidth) -
                        32; // minus horizontal padding

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
                    constraints: const BoxConstraints(maxWidth: columnMaxWidth),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(_controller.status,
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 12),
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
                                    style:
                                        Theme.of(context).textTheme.labelLarge),
                              ),
                              const SizedBox(height: 4),
                              ..._controller.recentSessions.take(5).map(
                                    (s) => Card(
                                      margin:
                                          const EdgeInsets.symmetric(vertical: 2),
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
                          // Phone-shaped frame holding the remote screen.
                          Center(
                            child: SizedBox(
                              width: frameW,
                              height: frameH,
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0E0E10),
                                  borderRadius: BorderRadius.circular(28),
                                  boxShadow: const [
                                    BoxShadow(
                                        color: Colors.black54, blurRadius: 16),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(22),
                                  child: ColoredBox(
                                    color: Colors.black,
                                    child: RemoteControlSurface(
                                      renderer: _controller.remoteRenderer,
                                      onTouch: _controller.sendTouch,
                                    ),
                                  ),
                                ),
                              ),
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
            );
          },
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
                maxLength: 4,
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
