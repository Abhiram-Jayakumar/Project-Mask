import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../call_controller.dart';
import '../services/file_access_service.dart';

/// Viewer-side file browser. Shows folders the host has shared, lets the viewer
/// navigate into subdirectories, and displays text file contents.
///
/// All requests go over the WebRTC data channel to the host. The host validates
/// every path against its [CallController.permittedFolders] list before
/// responding, so the viewer cannot access anything outside what was shared.
class FileBrowserPanel extends StatefulWidget {
  const FileBrowserPanel({super.key, required this.controller});

  final CallController controller;

  /// Open the file browser as a full-height modal bottom sheet.
  static Future<void> show(BuildContext context, CallController controller) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => FileBrowserPanel(controller: controller),
    );
  }

  @override
  State<FileBrowserPanel> createState() => _FileBrowserPanelState();
}

class _FileBrowserPanelState extends State<FileBrowserPanel> {
  // Navigation stack: list of directories visited (most recent = current).
  // Empty = root (show the host's shared folder list).
  final List<String> _pathStack = [];
  List<FileEntry>? _entries; // null = loading; [] = empty dir
  bool _loading = false;
  String? _error;

  CallController get _ctrl => widget.controller;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onControllerUpdate);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onControllerUpdate);
    super.dispose();
  }

  // ── Controller listener ───────────────────────────────────────────────────

  void _onControllerUpdate() {
    // File list response arrived.
    final listRes = _ctrl.takeFileListResult();
    if (listRes != null) {
      if (!mounted) return;
      // Only apply the response if it matches our current request path.
      final expected = _pathStack.isNotEmpty ? _pathStack.last : null;
      if (expected == null || listRes.path == expected) {
        setState(() {
          _loading = false;
          _entries = listRes.entries;
          _error = null;
        });
      }
    }

    // File data response arrived.
    final dataRes = _ctrl.takeFileDataResult();
    if (dataRes != null && mounted) {
      _showFileContent(dataRes.path, dataRes.text);
    }

    // Error from host.
    final errRes = _ctrl.takeFileErrorResult();
    if (errRes != null && mounted) {
      setState(() => _loading = false);
      _showError(errRes.error);
    }
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _openFolder(String path) {
    setState(() {
      _pathStack.add(path);
      _entries = null;
      _loading = true;
      _error = null;
    });
    _ctrl.requestFileList(path);
  }

  void _navigateUp() {
    if (_pathStack.isEmpty) return;
    setState(() {
      _pathStack.removeLast();
      if (_pathStack.isEmpty) {
        _entries = null; // back to root view (no request needed)
        _loading = false;
        _error = null;
      } else {
        _entries = null;
        _loading = true;
        _error = null;
        _ctrl.requestFileList(_pathStack.last);
      }
    });
  }

  void _openFile(String path) {
    setState(() => _loading = true);
    _ctrl.requestFile(path);
  }

  void _retry() {
    if (_pathStack.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _entries = null;
    });
    _ctrl.requestFileList(_pathStack.last);
  }

  // ── Dialogs ───────────────────────────────────────────────────────────────

  void _showFileContent(String path, String text) {
    final name = path.split('/').last;
    showDialog<void>(
      context: context,
      builder: (ctx) => _FileContentDialog(name: name, path: path, text: text),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade700,
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isRoot = _pathStack.isEmpty;
    final currentPath = _pathStack.isNotEmpty ? _pathStack.last : null;

    // Breadcrumb label.
    final title = isRoot
        ? 'Shared files'
        : currentPath!.split('/').last;

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 1.0,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // ── Header ──────────────────────────────────────────────────────
            Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  if (!isRoot)
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: 'Back',
                      onPressed: _navigateUp,
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (!isRoot)
                          Text(
                            currentPath!,
                            style: Theme.of(context).textTheme.labelSmall,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // ── Body ────────────────────────────────────────────────────────
            Expanded(
              child: _buildBody(scrollController, isRoot),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBody(ScrollController scrollController, bool isRoot) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Root view: show the list of folders the host has shared.
    if (isRoot) {
      final folders = _ctrl.availableFolders;
      if (folders.isEmpty) {
        return const Center(
          child: Text('The host has not shared any folders.'),
        );
      }
      return ListView.separated(
        controller: scrollController,
        itemCount: folders.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final path = folders[i];
          final label = path.split('/').last;
          return ListTile(
            leading: const Icon(Icons.folder, color: Colors.amber),
            title: Text(label),
            subtitle: Text(path, style: const TextStyle(fontSize: 11)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openFolder(path),
          );
        },
      );
    }

    // Error state.
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    // Empty directory.
    final entries = _entries ?? [];
    if (entries.isEmpty) {
      return const Center(child: Text('Empty folder'));
    }

    // Directory listing.
    return ListView.separated(
      controller: scrollController,
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final entry = entries[i];
        final fullPath = '${_pathStack.last}/${entry.name}';
        if (entry.isDir) {
          return ListTile(
            leading: const Icon(Icons.folder, color: Colors.amber),
            title: Text(entry.name),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openFolder(fullPath),
          );
        }
        return ListTile(
          leading: Icon(
            _fileIcon(entry.name),
            color: Colors.blueGrey,
          ),
          title: Text(entry.name),
          subtitle: Text(_formatSize(entry.size)),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => _openFile(fullPath),
        );
      },
    );
  }

  IconData _fileIcon(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
        return Icons.image;
      case 'mp4':
      case 'mkv':
      case 'avi':
        return Icons.video_file;
      case 'mp3':
      case 'wav':
      case 'aac':
      case 'flac':
        return Icons.audio_file;
      case 'zip':
      case 'tar':
      case 'gz':
      case 'rar':
        return Icons.archive;
      default:
        return Icons.insert_drive_file;
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Dialog showing the content of a text file with copy-to-clipboard support.
class _FileContentDialog extends StatelessWidget {
  const _FileContentDialog({
    required this.name,
    required this.path,
    required this.text,
  });

  final String name;
  final String path;
  final String text;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(name, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.55,
        child: SingleChildScrollView(
          child: SelectableText(
            text,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: text));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Copied to clipboard')),
            );
          },
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
