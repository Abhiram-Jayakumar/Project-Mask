import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../call_controller.dart';
import '../services/file_access_service.dart';
import '../services/system_service.dart';
import '../widgets/anytime_access_panel.dart';
import '../widgets/connection_panel.dart';
import '../widgets/keep_alive_cards.dart';

/// Host = the device being shared/controlled. In [HostMode.quick] it opens a
/// one-off random session; in [HostMode.anytime] it shows a stable device ID +
/// permanent PIN that viewers can use to connect at any time.
///
/// When [autoArm] is true (set by the boot-restore flow) the screen
/// automatically calls [CallController.armDevice] as soon as signaling connects
/// and a PIN is available — the user only needs to accept the system
/// MediaProjection dialog.
class HostScreen extends StatefulWidget {
  const HostScreen({
    super.key,
    required this.serverUrl,
    this.mode = HostMode.quick,
    this.autoArm = false,
  });

  final String serverUrl;
  final HostMode mode;
  final bool autoArm;

  @override
  State<HostScreen> createState() => _HostScreenState();
}

class _HostScreenState extends State<HostScreen> with WidgetsBindingObserver {
  late final CallController _controller;
  bool _closing = false; // set true only when the user ends the session
  VoidCallback? _autoArmListener; // non-null only while waiting to auto-arm

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
    if (widget.autoArm && widget.mode == HostMode.anytime) {
      _scheduleAutoArm();
    }
  }

  /// Registers a one-shot listener that calls [CallController.armDevice] as
  /// soon as signaling is connected and the PIN is available. Fires at most
  /// once — it removes itself before calling armDevice.
  void _scheduleAutoArm() {
    _autoArmListener = () {
      if (_controller.signalingConnected &&
          _controller.hasPin &&
          !_controller.armed) {
        _controller.removeListener(_autoArmListener!);
        _autoArmListener = null;
        _controller.armDevice();
      }
    };
    _controller.addListener(_autoArmListener!);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check after the user returns from a system settings screen.
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

  @override
  void dispose() {
    if (_autoArmListener != null) {
      _controller.removeListener(_autoArmListener!);
      _autoArmListener = null;
    }
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
              return SingleChildScrollView(
                child: Column(
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
                  // Consensual camera presence: host opts in, sees their own
                  // preview, and can turn it off. Android shows the camera dot.
                  if (!kIsWeb)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.videocam),
                                const SizedBox(width: 8),
                                const Expanded(
                                    child: Text('Let the viewer see my camera')),
                                Switch(
                                  value: _controller.cameraAllowed,
                                  onChanged: (v) => v
                                      ? _controller.allowCamera()
                                      : _controller.disallowCamera(),
                                ),
                              ],
                            ),
                            if (_controller.cameraAllowed &&
                                !_controller.cameraActive)
                              const Padding(
                                padding: EdgeInsets.only(top: 4),
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    'Camera stays off until the viewer chooses '
                                    'to look.',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                              ),
                            if (_controller.cameraActive)
                              Container(
                                margin: const EdgeInsets.only(top: 8),
                                height: 150,
                                clipBehavior: Clip.antiAlias,
                                decoration: BoxDecoration(
                                  color: Colors.black,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: RTCVideoView(
                                  _controller.cameraRenderer,
                                  mirror: true,
                                  objectFit: RTCVideoViewObjectFit
                                      .RTCVideoViewObjectFitCover,
                                ),
                              ),
                            const Divider(height: 16),
                            Row(
                              children: [
                                const Icon(Icons.mic),
                                const SizedBox(width: 8),
                                const Expanded(
                                    child: Text('Let the viewer hear me')),
                                Switch(
                                  value: _controller.micAllowed,
                                  onChanged: (v) => v
                                      ? _controller.allowMic()
                                      : _controller.disallowMic(),
                                ),
                              ],
                            ),
                            if (_controller.micAllowed)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  _controller.micActive
                                      ? 'Mic is live — the viewer is listening.'
                                      : 'Mic stays off until the viewer '
                                          'listens.',
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (!kIsWeb) ...[
                    const SizedBox(height: 8),
                    _LocationCard(controller: _controller),
                  ],
                  if (!kIsWeb) ...[
                    const SizedBox(height: 8),
                    _SharedFoldersCard(controller: _controller),
                  ],
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
                  // Anytime mode: screen sharing is on-demand (the host is
                  // already online for camera/mic). Share on the viewer's
                  // request or proactively.
                  if (widget.mode == HostMode.anytime && _controller.armed) ...[
                    if (_controller.screenRequested && !_controller.isSharing)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.orange.shade800,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Text(
                          'A viewer is asking to see your screen.',
                          style: TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                      ),
                    if (!_controller.isSharing)
                      FilledButton.icon(
                        onPressed: _controller.startSharing,
                        icon: const Icon(Icons.screen_share),
                        style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16)),
                        label: Text(_controller.screenRequested
                            ? 'Approve & share my screen'
                            : 'Share my screen'),
                      )
                    else
                      FilledButton.icon(
                        onPressed: _controller.stopSharing,
                        icon: const Icon(Icons.stop_screen_share),
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        label: const Text('Stop screen sharing'),
                      ),
                    const SizedBox(height: 8),
                  ],
                  CloseSessionButton(onPressed: _closeSession),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 220,
                    child: ConnectionPanel(controller: _controller),
                  ),
                ],
              ),
              );
            },
          ),
        ),
      ),
      ),
    );
  }
}

/// HOST: card to share live location + battery level with the viewer.
class _LocationCard extends StatelessWidget {
  const _LocationCard({required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.location_on),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Share my location & battery'),
                ),
                Switch(
                  value: controller.locationAllowed,
                  onChanged: (v) => v
                      ? controller.allowLocation()
                      : controller.disallowLocation(),
                ),
              ],
            ),
            if (controller.locationAllowed)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  controller.locationActive
                      ? 'Sending live GPS + battery to the viewer.'
                      : 'Waiting for GPS fix…',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            if (!controller.locationAllowed)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Viewer can track your position on a map and see battery level.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// HOST: card that lets the host pick folders the viewer is allowed to browse.
class _SharedFoldersCard extends StatelessWidget {
  const _SharedFoldersCard({required this.controller});

  final CallController controller;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.folder_shared),
                const SizedBox(width: 8),
                const Expanded(child: Text('Shared folders')),
                TextButton.icon(
                  onPressed: () => _showAddFolderDialog(context),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add'),
                ),
              ],
            ),
            if (controller.permittedFolders.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'No folders shared yet. Add a folder so the viewer can browse files.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              )
            else
              ...controller.permittedFolders.map(
                (folder) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder, size: 20),
                  title: Text(
                    folder,
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.remove_circle_outline, size: 20),
                    tooltip: 'Remove',
                    onPressed: () => controller.removePermittedFolder(folder),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showAddFolderDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => _AddFolderDialog(controller: controller),
    );
  }
}

class _AddFolderDialog extends StatefulWidget {
  const _AddFolderDialog({required this.controller});

  final CallController controller;

  @override
  State<_AddFolderDialog> createState() => _AddFolderDialogState();
}

class _AddFolderDialogState extends State<_AddFolderDialog> {
  final _customController = TextEditingController();

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  void _add(String path) {
    widget.controller.addPermittedFolder(path);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final presets = FileAccessService.commonFolders();
    return AlertDialog(
      title: const Text('Add shared folder'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Quick add', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: presets
                  .map((p) => ActionChip(
                        label: Text(p.label),
                        avatar: const Icon(Icons.folder, size: 16),
                        onPressed: () => _add(p.path),
                      ))
                  .toList(),
            ),
            const Divider(height: 24),
            Text('Custom path', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            TextField(
              controller: _customController,
              decoration: const InputDecoration(
                hintText: '/storage/emulated/0/MyFolder',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              autofocus: false,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final path = _customController.text.trim();
            if (path.isNotEmpty) _add(path);
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}
