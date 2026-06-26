import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../call_controller.dart';
import '../services/file_access_service.dart';
import '../services/system_service.dart';

/// Viewer-side file browser.
///
/// Navigation: root shows shared folders → tap into folders → tap a file to
/// open the [_FileDetailSheet] which shows a 2 KB text preview and a
/// "Download to device" button that streams the full file from the host.
class FileBrowserPanel extends StatefulWidget {
  const FileBrowserPanel({super.key, required this.controller});

  final CallController controller;

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
  final List<String> _pathStack = [];
  List<FileEntry>? _entries;
  bool _loading = false;
  String? _browseError;

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

  void _onControllerUpdate() {
    final listRes = _ctrl.takeFileListResult();
    if (listRes != null && mounted) {
      final expected = _pathStack.isNotEmpty ? _pathStack.last : null;
      if (expected == null || listRes.path == expected) {
        setState(() {
          _loading = false;
          _entries = listRes.entries;
          _browseError = null;
        });
      }
    }
    final errRes = _ctrl.takeFileErrorResult();
    if (errRes != null && mounted) {
      setState(() => _loading = false);
      _showSnack(errRes.error, isError: true);
    }
  }

  void _openFolder(String path) {
    setState(() {
      _pathStack.add(path);
      _entries = null;
      _loading = true;
      _browseError = null;
    });
    _ctrl.requestFileList(path);
  }

  void _navigateUp() {
    if (_pathStack.isEmpty) return;
    setState(() {
      _pathStack.removeLast();
      _entries = null;
      _browseError = null;
      if (_pathStack.isEmpty) {
        _loading = false;
      } else {
        _loading = true;
        _ctrl.requestFileList(_pathStack.last);
      }
    });
  }

  void _openFile(FileEntry entry) {
    final fullPath = '${_pathStack.last}/${entry.name}';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _FileDetailSheet(
        controller: _ctrl,
        entry: entry,
        fullPath: fullPath,
      ),
    );
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red.shade700 : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isRoot = _pathStack.isEmpty;
    final title = isRoot
        ? 'Shared files'
        : _pathStack.last.split('/').last;

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 1.0,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          _Header(
            title: title,
            subtitle: isRoot ? null : _pathStack.last,
            canGoBack: !isRoot,
            onBack: _navigateUp,
            onClose: () => Navigator.of(context).pop(),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody(scrollController, isRoot)),
        ],
      ),
    );
  }

  Widget _buildBody(ScrollController sc, bool isRoot) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (isRoot) {
      final folders = _ctrl.availableFolders;
      if (folders.isEmpty) {
        return const Center(child: Text('The host has not shared any folders.'));
      }
      return ListView.separated(
        controller: sc,
        itemCount: folders.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final path = folders[i];
          return ListTile(
            leading: const Icon(Icons.folder, color: Colors.amber),
            title: Text(path.split('/').last),
            subtitle: Text(path, style: const TextStyle(fontSize: 11)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _openFolder(path),
          );
        },
      );
    }
    if (_browseError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text(_browseError!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () {
                setState(() { _loading = true; _browseError = null; });
                _ctrl.requestFileList(_pathStack.last);
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    final entries = _entries ?? [];
    if (entries.isEmpty) {
      return const Center(child: Text('Empty folder'));
    }
    return ListView.separated(
      controller: sc,
      itemCount: entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
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
          leading: Icon(_fileIcon(entry.name), color: Colors.blueGrey),
          title: Text(entry.name),
          subtitle: Text(_fmtSize(entry.size),
              style: const TextStyle(fontSize: 11)),
          trailing: const Icon(Icons.open_in_new, size: 18),
          onTap: () => _openFile(entry),
        );
      },
    );
  }

  IconData _fileIcon(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'pdf': return Icons.picture_as_pdf;
      case 'jpg': case 'jpeg': case 'png': case 'gif': case 'webp':
        return Icons.image;
      case 'mp4': case 'mkv': case 'avi': return Icons.video_file;
      case 'mp3': case 'wav': case 'aac': case 'flac': return Icons.audio_file;
      case 'zip': case 'tar': case 'gz': case 'rar': return Icons.archive;
      default: return Icons.insert_drive_file;
    }
  }

  String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

// ── File detail sheet ──────────────────────────────────────────────────────────

/// Bottom sheet that shows a 2 KB text preview of a file and lets the viewer
/// download the full file to their device's Downloads folder.
class _FileDetailSheet extends StatefulWidget {
  const _FileDetailSheet({
    required this.controller,
    required this.entry,
    required this.fullPath,
  });

  final CallController controller;
  final FileEntry entry;
  final String fullPath;

  @override
  State<_FileDetailSheet> createState() => _FileDetailSheetState();
}

class _FileDetailSheetState extends State<_FileDetailSheet> {
  bool _previewLoading = true;
  String? _previewText;
  bool _isBinary = false;
  int _totalSize = 0;

  // Download
  bool _downloadTriggered = false;
  String? _savedPath;
  String? _downloadErrMsg;

  CallController get _ctrl => widget.controller;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onControllerUpdate);
    // Request preview immediately when the sheet opens.
    _ctrl.requestFilePreview(widget.fullPath);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onControllerUpdate);
    super.dispose();
  }

  void _onControllerUpdate() {
    if (!mounted) return;

    // Preview response.
    final preview = _ctrl.takeFilePreviewResult();
    if (preview != null && preview.path == widget.fullPath) {
      setState(() {
        _previewLoading = false;
        _previewText = preview.text;
        _isBinary = preview.isBinary;
        _totalSize = preview.totalSize;
      });
    }

    // Download progress / completion / error.
    if (_downloadTriggered) {
      if (_ctrl.downloadReady != null) {
        final ready = _ctrl.takeDownloadReady()!;
        _saveFile(ready.name, ready.bytes);
      } else if (_ctrl.downloadError != null && !_ctrl.isDownloading) {
        final err = _ctrl.downloadError!;
        setState(() {
          _downloadTriggered = false;
          _downloadErrMsg = err;
        });
        _ctrl.downloadError = null;
      } else {
        // Progress update — just rebuild for the progress bar.
        setState(() {});
      }
    }

    // General file error (e.g. preview denied).
    final errRes = _ctrl.takeFileErrorResult();
    if (errRes != null && errRes.path == widget.fullPath) {
      setState(() {
        _previewLoading = false;
        _previewText = null;
        _downloadErrMsg = errRes.error;
      });
    }
  }

  Future<void> _saveFile(String name, Uint8List bytes) async {
    try {
      final savedPath = await SystemService.saveFileToDownloads(name, bytes);
      if (!mounted) return;
      setState(() {
        _downloadTriggered = false;
        _savedPath = savedPath;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloadTriggered = false;
        _downloadErrMsg = 'Save failed: $e';
      });
    }
  }

  void _startDownload() {
    setState(() {
      _downloadTriggered = true;
      _downloadErrMsg = null;
      _savedPath = null;
    });
    _ctrl.requestFileDownload(widget.fullPath);
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.entry.name;
    final isDownloading = _downloadTriggered && _ctrl.isDownloading;
    final progress = _ctrl.downloadProgress;

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 1.0,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          _Header(
            title: name,
            subtitle: _totalSize > 0 ? _fmtSize(_totalSize) : null,
            canGoBack: false,
            onClose: () => Navigator.of(context).pop(),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Preview ─────────────────────────────────────────────
                  _previewSection(),
                  const SizedBox(height: 20),
                  // ── Download ─────────────────────────────────────────────
                  _downloadSection(isDownloading, progress),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewSection() {
    if (_previewLoading) {
      return const Center(
        heightFactor: 3,
        child: CircularProgressIndicator(),
      );
    }
    if (_isBinary) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          children: [
            Icon(Icons.info_outline, color: Colors.grey),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Binary file — preview not available.\nUse Download to get the full file.',
                style: TextStyle(color: Colors.grey),
              ),
            ),
          ],
        ),
      );
    }
    if (_previewText == null) {
      return const SizedBox.shrink();
    }
    final isTruncated = _totalSize > FileAccessService.previewBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Preview',
                style: Theme.of(context).textTheme.labelLarge),
            if (isTruncated) ...[
              const SizedBox(width: 8),
              Text(
                '(first 2 KB of ${_fmtSize(_totalSize)})',
                style: Theme.of(context)
                    .textTheme
                    .labelSmall
                    ?.copyWith(color: Colors.grey),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey.shade900,
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            _previewText!,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: Colors.greenAccent,
            ),
          ),
        ),
        if (isTruncated)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              '— truncated — download the full file to see everything',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
      ],
    );
  }

  Widget _downloadSection(bool isDownloading, double progress) {
    if (_savedPath != null) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.green.shade900,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.greenAccent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Saved to Downloads',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(_savedPath!,
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    if (_downloadErrMsg != null) {
      return Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.red.shade900,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: Colors.redAccent),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(_downloadErrMsg!,
                        style: const TextStyle(color: Colors.white))),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _startDownload,
            icon: const Icon(Icons.download),
            label: const Text('Retry download'),
          ),
        ],
      );
    }

    if (isDownloading) {
      final done = _ctrl.downloadDoneChunks;
      final total = _ctrl.downloadTotalChunks;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            total > 0
                ? 'Downloading… $done / $total chunks'
                : 'Downloading…',
            style: Theme.of(context).textTheme.labelMedium,
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: total > 0 ? progress : null,
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            total > 0
                ? '${(progress * 100).toStringAsFixed(0)}% — '
                    '${_fmtSize((progress * _totalSize).round())} of ${_fmtSize(_totalSize)}'
                : 'Preparing…',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _ctrl.cancelDownload,
            child: const Text('Cancel'),
          ),
        ],
      );
    }

    // Idle — show download button.
    return FilledButton.icon(
      onPressed: _startDownload,
      icon: const Icon(Icons.download),
      style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 14)),
      label: Text(
        _totalSize > 0
            ? 'Download to device  (${_fmtSize(_totalSize)})'
            : 'Download to device',
      ),
    );
  }

  String _fmtSize(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(2)} MB';
  }
}

// ── Shared header ──────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.canGoBack,
    required this.onClose,
    this.subtitle,
    this.onBack,
  });

  final String title;
  final String? subtitle;
  final bool canGoBack;
  final VoidCallback? onBack;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          if (canGoBack)
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: onBack,
              tooltip: 'Back',
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis),
                if (subtitle != null)
                  Text(subtitle!,
                      style: Theme.of(context).textTheme.labelSmall,
                      overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
