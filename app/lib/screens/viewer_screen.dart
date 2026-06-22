import 'package:flutter/material.dart';

import '../call_controller.dart';
import '../widgets/connection_panel.dart';
import '../widgets/remote_control_surface.dart';

/// Viewer = the controlling device. Enters a session ID, watches the host's
/// screen (Phase 3+), and sends control events over the data channel.
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
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              final connected = _controller.peerConnected;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_controller.status,
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  if (!connected)
                    Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: _idController,
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
                                controller: _pinController,
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
                            onPressed: _controller.signalingConnected
                                ? () => _controller.joinAsViewer(
                                    _idController.text, _pinController.text)
                                : null,
                            child: const Text('Connect'),
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 12),
                  // Remote screen — tap/drag here to control the host.
                  AspectRatio(
                    aspectRatio: 9 / 16,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: RemoteControlSurface(
                        renderer: _controller.remoteRenderer,
                        onTouch: _controller.sendTouch,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    connected
                        ? 'Tap or drag the screen to control the host'
                        : 'Connect to a host to begin',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  OutlinedButton.icon(
                    onPressed: _controller.dataChannelOpen
                        ? _controller.sendTestPing
                        : null,
                    icon: const Icon(Icons.network_ping),
                    label: const Text('Send test ping (verify data channel)'),
                  ),
                  const SizedBox(height: 8),
                  Expanded(child: ConnectionPanel(controller: _controller)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
