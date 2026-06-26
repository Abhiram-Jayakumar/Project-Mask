import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../call_controller.dart';
import '../services/system_service.dart';
import '../widgets/connection_panel.dart';
import '../widgets/file_browser_panel.dart';
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
  bool _showHostCam = false; // viewer chose to view the host's camera tile
  bool _listenHost = false; // viewer chose to listen to the host's mic

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

  /// Show/hide the host camera. Toggling on ASKS the host to start the camera
  /// (so it's only live while actually being watched); toggling off stops it.
  void _toggleHostCam() {
    final next = !_showHostCam;
    setState(() => _showHostCam = next);
    _controller.requestHostCamera(next);
  }

  void _closeHostCam() {
    setState(() => _showHostCam = false);
    _controller.requestHostCamera(false);
  }

  /// Start/stop listening to the host mic. Toggling on asks the host to open the
  /// mic (so it's only live while actually being listened to).
  void _toggleHostMic() {
    final next = !_listenHost;
    setState(() => _listenHost = next);
    _controller.requestHostMic(next);
  }

  /// A hidden 1×1 player so the host's mic audio actually outputs (web needs a
  /// media element to play a remote audio track).
  Widget _audioSink() => _controller.micOn
      ? SizedBox(
          width: 1,
          height: 1,
          child: RTCVideoView(_controller.audioRenderer),
        )
      : const SizedBox.shrink();

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
                    ),
                  ),
                  // Host camera presence — the viewer opens it on demand and it
                  // floats as a draggable window (never covers the screen).
                  if (_controller.cameraOn && _showHostCam)
                    _DraggableCameraTile(
                      renderer: _controller.cameraRenderer,
                      bounds: MediaQuery.of(context).size,
                      onClose: _closeHostCam,
                    ),
                  _audioSink(),
                  // Top-right controls: listen toggle + view-host + exit.
                  Positioned(
                    top: 20,
                    right: 16,
                    child: Row(
                      children: [
                        if (_controller.micAvailable) ...[
                          _CircleIconButton(
                            icon: _listenHost ? Icons.hearing : Icons.hearing_disabled,
                            onTap: _toggleHostMic,
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (_controller.cameraAvailable) ...[
                          _CircleIconButton(
                            icon: _showHostCam
                                ? Icons.videocam_off
                                : Icons.videocam,
                            onTap: _toggleHostCam,
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (_controller.cameraOn && _showHostCam) ...[
                          _CircleIconButton(
                            icon: Icons.flip_camera_android,
                            onTap: _controller.requestCameraFlip,
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (_controller.filesAvailable) ...[
                          _CircleIconButton(
                            icon: Icons.folder_open,
                            onTap: () => FileBrowserPanel.show(
                              context,
                              _controller,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        _CircleIconButton(
                          icon: Icons.fullscreen_exit,
                          onTap: _exitFullscreen,
                        ),
                      ],
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
                            _audioSink(),
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
                                        child: Stack(
                                          children: [
                                            Positioned.fill(
                                              child: ColoredBox(
                                                color: Colors.black,
                                                child: RemoteControlSurface(
                                                  renderer: _controller
                                                      .remoteRenderer,
                                                ),
                                              ),
                                            ),
                                            if (_controller.cameraOn &&
                                                _showHostCam)
                                              _DraggableCameraTile(
                                                renderer:
                                                    _controller.cameraRenderer,
                                                bounds: Size(
                                                    frameW - 12, frameH - 12),
                                                tileSize: const Size(72, 96),
                                                onClose: _closeHostCam,
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  // Overlay controls: view-host toggle + fullscreen.
                                  Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_controller.micAvailable) ...[
                                          _CircleIconButton(
                                            icon: _listenHost
                                                ? Icons.hearing
                                                : Icons.hearing_disabled,
                                            onTap: _toggleHostMic,
                                          ),
                                          const SizedBox(width: 8),
                                        ],
                                        if (_controller.cameraAvailable) ...[
                                          _CircleIconButton(
                                            icon: _showHostCam
                                                ? Icons.videocam_off
                                                : Icons.videocam,
                                            onTap: _toggleHostCam,
                                          ),
                                          const SizedBox(width: 8),
                                        ],
                                        if (_controller.cameraOn &&
                                            _showHostCam) ...[
                                          _CircleIconButton(
                                            icon: Icons.flip_camera_android,
                                            onTap: _controller.requestCameraFlip,
                                          ),
                                          const SizedBox(width: 8),
                                        ],
                                        _CircleIconButton(
                                          icon: Icons.fullscreen,
                                          onTap: _enterFullscreen,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              connected
                                  ? "Viewing the host's screen"
                                  : 'Connect to a host to begin',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(height: 10),
                            // Ask the host to start screen sharing when they're
                            // connected but not sharing yet.
                            if (connected &&
                                _controller.remoteRenderer.srcObject == null)
                              FilledButton.icon(
                                onPressed: _controller.dataChannelOpen
                                    ? _controller.requestHostScreen
                                    : null,
                                icon: const Icon(Icons.screen_share),
                                style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 14)),
                                label: const Text('Request screen share'),
                              ),
                            // File browser — visible when the host has shared
                            // at least one folder.
                            if (connected && _controller.filesAvailable) ...[
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                onPressed: () => FileBrowserPanel.show(
                                  context,
                                  _controller,
                                ),
                                icon: const Icon(Icons.folder_open),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 14),
                                ),
                                label: Text(
                                  'Browse files'
                                  ' (${_controller.availableFolders.length}'
                                  ' folder${_controller.availableFolders.length == 1 ? '' : 's'})',
                                ),
                              ),
                            ],
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

/// Camera-presence tile showing the host's front camera. Fills its parent.
class _CameraTile extends StatelessWidget {
  const _CameraTile({required this.renderer});

  final RTCVideoRenderer renderer;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white30),
        boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 8)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: RTCVideoView(
          renderer,
          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
        ),
      ),
    );
  }
}

/// A draggable, closable floating window for the host camera. Defaults to the
/// bottom-right of [bounds] and stays within them. Must be a direct child of a
/// Stack (it returns a [Positioned]).
class _DraggableCameraTile extends StatefulWidget {
  const _DraggableCameraTile({
    required this.renderer,
    required this.bounds,
    required this.onClose,
    this.tileSize = const Size(96, 128),
  });

  final RTCVideoRenderer renderer;
  final Size bounds;
  final VoidCallback onClose;
  final Size tileSize;

  @override
  State<_DraggableCameraTile> createState() => _DraggableCameraTileState();
}

class _DraggableCameraTileState extends State<_DraggableCameraTile> {
  Offset? _pos;

  double _clamp(double v, double max) => v.clamp(0.0, max < 0 ? 0.0 : max);

  @override
  Widget build(BuildContext context) {
    final w = widget.tileSize.width;
    final h = widget.tileSize.height;
    _pos ??= Offset(
      _clamp(widget.bounds.width - w - 8, widget.bounds.width - w),
      _clamp(widget.bounds.height - h - 8, widget.bounds.height - h),
    );
    return Positioned(
      left: _pos!.dx,
      top: _pos!.dy,
      child: GestureDetector(
        onPanUpdate: (d) => setState(() {
          _pos = Offset(
            _clamp(_pos!.dx + d.delta.dx, widget.bounds.width - w),
            _clamp(_pos!.dy + d.delta.dy, widget.bounds.height - h),
          );
        }),
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(child: _CameraTile(renderer: widget.renderer)),
              Positioned(
                top: -8,
                right: -8,
                child: GestureDetector(
                  onTap: widget.onClose,
                  child: const CircleAvatar(
                    radius: 11,
                    backgroundColor: Colors.black87,
                    child: Icon(Icons.close, size: 14, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
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
