import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../call_controller.dart';
import '../services/capture_service.dart';
import '../services/system_service.dart';
import '../widgets/connection_panel.dart';
import '../widgets/file_browser_panel.dart';
import '../widgets/keep_alive_cards.dart';
import '../widgets/location_map_panel.dart';
import '../widgets/notification_panel.dart';
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
  bool _closing = false;      // set true only when the user ends the session
  bool _fullscreen = false;   // true → video fills screen, system bars hidden
  bool _showHostCam = false;  // viewer chose to view the host's camera tile
  bool _cameraExpanded = false; // camera is shown full-frame (over screen share)
  bool _listenHost = false;   // viewer chose to listen to the host's mic

  // Screen capture (screenshot + recording) — permitted by host toggle.
  final GlobalKey _captureKey = GlobalKey();
  bool _isRecording = false;

  // Tracks the previous peer-connected state to detect "host came back" event.
  bool _prevPeerConnected = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = CallController(role: Role.viewer, serverUrl: widget.serverUrl);
    _controller.start();
    _controller.addListener(_onControllerChange);
  }

  /// Detects the moment peerConnected flips true after a host reboot/disconnect
  /// and shows a "Host is back online" banner.
  void _onControllerChange() {
    final connected = _controller.peerConnected;
    if (connected && !_prevPeerConnected && _controller.hostReconnecting) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white, size: 18),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Host is back online — session resumed',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF2E7D32),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        );
      });
    }
    _prevPeerConnected = connected;
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
    setState(() {
      _showHostCam = next;
      if (!next) _cameraExpanded = false;
    });
    _controller.requestHostCamera(next);
  }

  void _closeHostCam() {
    setState(() {
      _showHostCam = false;
      _cameraExpanded = false;
    });
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

  Future<void> _takeScreenshot() async {
    if (!_controller.capturePermitted) return;
    try {
      final boundary = _captureKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;
      final ts = DateTime.now().millisecondsSinceEpoch;
      await CaptureService.saveImageToGallery(
          'screenshot_$ts.png', byteData.buffer.asUint8List());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Screenshot saved to gallery')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Screenshot failed: $e')));
      }
    }
  }

  Future<void> _startRecording() async {
    if (!_controller.capturePermitted || _isRecording) return;
    final started = await CaptureService.startRecording();
    if (mounted) {
      setState(() => _isRecording = started);
      if (started) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Recording started')));
      }
    }
  }

  Future<void> _stopRecording() async {
    if (!_isRecording) return;
    final path = await CaptureService.stopRecording();
    if (mounted) {
      setState(() => _isRecording = false);
      if (path.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Recording saved to Downloads')));
      }
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChange);
    if (_isRecording) CaptureService.stopRecording(); // fire-and-forget
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
            // True when the host is actively sending their screen.
            final hasScreen = _controller.remoteRenderer.srcObject != null;
            // Camera fills the frame when: no screen share at all, OR the viewer
            // tapped the expand button on the small tile.
            final cameraFull = _controller.cameraOn &&
                _showHostCam &&
                (!hasScreen || _cameraExpanded);
            final cameraSmall = _controller.cameraOn &&
                _showHostCam &&
                hasScreen &&
                !_cameraExpanded;

            // ── Fullscreen mode ─────────────────────────────────────────────
            if (_fullscreen) {
              return RepaintBoundary(
                key: _captureKey,
                child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(
                    color: Colors.black,
                    child: RemoteControlSurface(
                      renderer: _controller.remoteRenderer,
                    ),
                  ),
                  // Full-frame camera: no screen share, or viewer expanded it.
                  if (cameraFull)
                    _FullCameraView(
                      renderer: _controller.cameraRenderer,
                      onClose: _closeHostCam,
                      onFlip: _controller.requestCameraFlip,
                      showMinimize: hasScreen && _cameraExpanded,
                      onMinimize: () =>
                          setState(() => _cameraExpanded = false),
                    ),
                  // Small draggable tile when screen share is active.
                  if (cameraSmall)
                    _DraggableCameraTile(
                      renderer: _controller.cameraRenderer,
                      bounds: MediaQuery.of(context).size,
                      onClose: _closeHostCam,
                      onExpand: () =>
                          setState(() => _cameraExpanded = true),
                    ),
                  _audioSink(),
                  // Top-left: host online / reconnecting status badge.
                  Positioned(
                    top: 20,
                    left: 16,
                    child: _HostStatusBadge(
                      connected: _controller.peerConnected,
                      reconnecting: _controller.hostReconnecting,
                    ),
                  ),
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
                        // Flip button in overlay only while camera is small tile;
                        // when full-frame the flip button lives inside _FullCameraView.
                        if (cameraSmall) ...[
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
                        if (_controller.locationAvailable) ...[
                          _CircleIconButton(
                            icon: Icons.location_on,
                            onTap: () => LocationMapPanel.show(
                              context,
                              _controller,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (_controller.notificationsAvailable) ...[
                          _NotifIconButton(
                            unread: _controller.unreadNotifCount,
                            onTap: () => NotificationPanel.show(
                              context,
                              _controller,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        if (_controller.capturePermitted) ...[
                          _CircleIconButton(
                            icon: Icons.camera_alt,
                            onTap: _takeScreenshot,
                          ),
                          const SizedBox(width: 8),
                          _CircleIconButton(
                            icon: _isRecording
                                ? Icons.stop
                                : Icons.fiber_manual_record,
                            onTap: _isRecording
                                ? _stopRecording
                                : _startRecording,
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
              ),
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
                            const SizedBox(height: 8),
                            _HostStatusBadge(
                              connected: _controller.peerConnected,
                              reconnecting: _controller.hostReconnecting,
                            ),
                            const SizedBox(height: 8),
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
                                          trailing: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (_controller
                                                  .signalingConnected)
                                                const Icon(Icons.login,
                                                    size: 20),
                                              IconButton(
                                                icon: const Icon(
                                                    Icons.delete_outline,
                                                    size: 20),
                                                tooltip: 'Remove',
                                                padding: EdgeInsets.zero,
                                                constraints:
                                                    const BoxConstraints(),
                                                onPressed: () =>
                                                    _controller
                                                        .removeRecentSession(
                                                            s.id),
                                              ),
                                            ],
                                          ),
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
                                  RepaintBoundary(
                                    key: _captureKey,
                                    child: SizedBox(
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
                                            // Full-frame camera: no screen share
                                            // or viewer expanded the tile.
                                            if (cameraFull)
                                              Positioned.fill(
                                                child: _FullCameraView(
                                                  renderer: _controller
                                                      .cameraRenderer,
                                                  onClose: _closeHostCam,
                                                  onFlip: _controller
                                                      .requestCameraFlip,
                                                  showMinimize: hasScreen &&
                                                      _cameraExpanded,
                                                  onMinimize: () => setState(
                                                      () => _cameraExpanded =
                                                          false),
                                                ),
                                              ),
                                            // Small draggable tile when screen
                                            // share is active.
                                            if (cameraSmall)
                                              _DraggableCameraTile(
                                                renderer:
                                                    _controller.cameraRenderer,
                                                bounds: Size(
                                                    frameW - 12, frameH - 12),
                                                tileSize: const Size(72, 96),
                                                onClose: _closeHostCam,
                                                onExpand: () => setState(() =>
                                                    _cameraExpanded = true),
                                              ),
                                          ],
                                        ),
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
                                        if (cameraSmall) ...[
                                          _CircleIconButton(
                                            icon: Icons.flip_camera_android,
                                            onTap: _controller.requestCameraFlip,
                                          ),
                                          const SizedBox(width: 8),
                                        ],
                                        if (_controller.locationAvailable) ...[
                                          _CircleIconButton(
                                            icon: Icons.location_on,
                                            onTap: () => LocationMapPanel.show(
                                              context,
                                              _controller,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                        ],
                                        if (_controller.notificationsAvailable) ...[
                                          _NotifIconButton(
                                            unread: _controller.unreadNotifCount,
                                            onTap: () => NotificationPanel.show(
                                              context,
                                              _controller,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                        ],
                                        if (_controller.capturePermitted) ...[
                                          _CircleIconButton(
                                            icon: Icons.camera_alt,
                                            onTap: _takeScreenshot,
                                          ),
                                          const SizedBox(width: 8),
                                          _CircleIconButton(
                                            icon: _isRecording
                                                ? Icons.stop
                                                : Icons.fiber_manual_record,
                                            onTap: _isRecording
                                                ? _stopRecording
                                                : _startRecording,
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
                            // Location map — visible when the host shares location.
                            if (connected && _controller.locationAvailable) ...[
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                onPressed: () => LocationMapPanel.show(
                                  context,
                                  _controller,
                                ),
                                icon: const Icon(Icons.location_on),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 14),
                                ),
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text('View host location'),
                                    if (_controller.hostBattery != null) ...[
                                      const SizedBox(width: 8),
                                      _BatteryPill(
                                        pct: _controller.hostBattery!,
                                        charging: _controller.hostBatteryCharging,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                            // Notifications — visible when the host mirrors them.
                            if (connected &&
                                _controller.notificationsAvailable) ...[
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                onPressed: () => NotificationPanel.show(
                                  context,
                                  _controller,
                                ),
                                icon: const Icon(
                                    Icons.notifications_active),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 14),
                                ),
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text('Notifications'),
                                    if (_controller.unreadNotifCount > 0) ...[
                                      const SizedBox(width: 8),
                                      _UnreadBadge(
                                          count: _controller.unreadNotifCount),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                            // Screenshot + record — visible when the host allows capture.
                            if (connected && _controller.capturePermitted) ...[
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _takeScreenshot,
                                      icon: const Icon(Icons.camera_alt),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 14),
                                      ),
                                      label: const Text('Screenshot'),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _isRecording
                                          ? _stopRecording
                                          : _startRecording,
                                      icon: Icon(
                                        _isRecording
                                            ? Icons.stop
                                            : Icons.fiber_manual_record,
                                        color: _isRecording ? Colors.red : null,
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 14),
                                        foregroundColor:
                                            _isRecording ? Colors.red : null,
                                      ),
                                      label: Text(_isRecording
                                          ? 'Stop recording'
                                          : 'Record'),
                                    ),
                                  ),
                                ],
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
    this.onExpand,
  });

  final RTCVideoRenderer renderer;
  final Size bounds;
  final VoidCallback onClose;
  final Size tileSize;
  /// Optional callback: when tapped, expands the camera to fill the frame.
  final VoidCallback? onExpand;

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
              // Expand button — bottom-left corner of the tile.
              if (widget.onExpand != null)
                Positioned(
                  bottom: -8,
                  left: -8,
                  child: GestureDetector(
                    onTap: widget.onExpand,
                    child: const CircleAvatar(
                      radius: 11,
                      backgroundColor: Colors.black87,
                      child: Icon(
                        Icons.open_in_full,
                        size: 13,
                        color: Colors.white,
                      ),
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

/// Camera feed filling its parent entirely — used when there is no screen share
/// or when the viewer has expanded the small camera tile. Must be a child of a
/// Stack (or wrapped in [Positioned.fill] in a non-expand Stack).
class _FullCameraView extends StatelessWidget {
  const _FullCameraView({
    required this.renderer,
    required this.onClose,
    required this.onFlip,
    this.showMinimize = false,
    this.onMinimize,
  });

  final RTCVideoRenderer renderer;
  final VoidCallback onClose;
  final VoidCallback onFlip;
  /// True when a screen share exists in the background — shows a "show screen"
  /// pill at the bottom so the viewer can shrink the camera back.
  final bool showMinimize;
  final VoidCallback? onMinimize;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Camera video fills the entire area.
        Positioned.fill(
          child: RTCVideoView(
            renderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          ),
        ),
        // Close button — top-left.
        Positioned(
          top: 8,
          left: 8,
          child: _CircleIconButton(icon: Icons.close, onTap: onClose),
        ),
        // Flip camera — top-right.
        Positioned(
          top: 8,
          right: 8,
          child: _CircleIconButton(
            icon: Icons.flip_camera_android,
            onTap: onFlip,
          ),
        ),
        // "Show screen" minimize pill — bottom-center, only when screen share
        // is active behind the camera.
        if (showMinimize && onMinimize != null)
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: GestureDetector(
                onTap: onMinimize,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.picture_in_picture_alt,
                          color: Colors.white, size: 14),
                      SizedBox(width: 6),
                      Text(
                        'Show screen',
                        style:
                            TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Circular notification button with an optional red unread-count badge.
class _NotifIconButton extends StatelessWidget {
  const _NotifIconButton({required this.unread, required this.onTap});

  final int unread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _CircleIconButton(
          icon: Icons.notifications,
          onTap: onTap,
        ),
        if (unread > 0)
          Positioned(
            top: -4,
            right: -4,
            child: _UnreadBadge(count: unread),
          ),
      ],
    );
  }
}

/// Small red pill showing an unread notification count.
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

/// Coloured pill showing whether the host is connected, reconnecting, or gone.
///
/// Green + solid dot  → host online (peerConnected = true)
/// Amber + pulsing dot → host went offline but session is still open
/// Hidden              → not in a session
class _HostStatusBadge extends StatelessWidget {
  const _HostStatusBadge({required this.connected, required this.reconnecting});

  final bool connected;
  final bool reconnecting;

  @override
  Widget build(BuildContext context) {
    if (!connected && !reconnecting) return const SizedBox.shrink();
    final color =
        connected ? const Color(0xFF2E7D32) : const Color(0xFFF57F17);
    final label = connected ? 'Host online' : 'Host reconnecting…';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PulsingDot(color: color, pulsing: !connected),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// A small circle that optionally pulses (opacity breathes) to signal activity.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color, required this.pulsing});

  final Color color;
  final bool pulsing;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.pulsing) _anim.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_PulsingDot old) {
    super.didUpdateWidget(old);
    if (widget.pulsing && !old.pulsing) {
      _anim.repeat(reverse: true);
    } else if (!widget.pulsing && old.pulsing) {
      _anim
        ..stop()
        ..value = 1.0;
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) => Opacity(
        opacity: widget.pulsing ? 0.4 + _anim.value * 0.6 : 1.0,
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

/// Compact battery pill shown inline on the "View host location" button.
class _BatteryPill extends StatelessWidget {
  const _BatteryPill({required this.pct, required this.charging});

  final int pct;
  final bool charging;

  @override
  Widget build(BuildContext context) {
    final color = pct > 50
        ? Colors.green
        : pct > 20
            ? Colors.orange
            : Colors.red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            charging ? Icons.battery_charging_full : Icons.battery_std,
            size: 12,
            color: color,
          ),
          const SizedBox(width: 2),
          Text(
            '$pct%',
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
