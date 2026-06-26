import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A single directory entry as sent over the data channel.
class FileEntry {
  FileEntry({required this.name, required this.isDir, required this.size});

  final String name;
  final bool isDir;
  final int size;

  Map<String, dynamic> toJson() => {'n': name, 'd': isDir, 's': size};

  factory FileEntry.fromJson(Map<String, dynamic> j) => FileEntry(
        name: j['n'] as String,
        isDir: j['d'] as bool? ?? false,
        size: (j['s'] as num?)?.toInt() ?? 0,
      );
}

/// HOST-SIDE file system access, restricted to paths the host has explicitly
/// permitted. All path checks run through [_norm] to defeat traversal attacks.
class FileAccessService {
  /// First N bytes sent as a text preview (viewer sees this instantly on tap).
  static const int previewBytes = 2048; // 2 KB

  /// Bytes per download chunk sent over the data channel. Base64-encoded this
  /// becomes ~64 KB per message, safely within WebRTC data-channel limits.
  static const int chunkSize = 48 * 1024; // 48 KB raw → ~64 KB base64

  /// Hard cap on file downloads to avoid very long transfers (can be raised).
  static const int maxDownloadBytes = 50 * 1024 * 1024; // 50 MB

  // ── Path security ──────────────────────────────────────────────────────────

  /// Returns true only when [path] is exactly one of [permittedFolders] or is
  /// a strict descendant. Resolves . and .. before comparing.
  static bool isAllowed(String path, List<String> permittedFolders) {
    final norm = _norm(path);
    return permittedFolders.any((folder) {
      final nf = _norm(folder);
      return norm == nf || norm.startsWith('$nf/');
    });
  }

  /// Collapses . and .. segments without touching the file system.
  static String _norm(String rawPath) {
    final segments = rawPath.split('/');
    final out = <String>[];
    for (final seg in segments) {
      if (seg == '..') {
        if (out.isNotEmpty) out.removeLast();
      } else if (seg != '.') {
        out.add(seg);
      }
    }
    final joined = out.join('/');
    return joined.isEmpty ? '/' : joined;
  }

  // ── File system operations ─────────────────────────────────────────────────

  static Future<List<FileEntry>> listDirectory(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) throw Exception('Directory not found: $path');
    final entries = <FileEntry>[];
    await for (final entity in dir.list()) {
      try {
        final stat = await entity.stat();
        final name = entity.path.split(Platform.pathSeparator).last;
        entries.add(FileEntry(
          name: name,
          isDir: entity is Directory,
          size: stat.size,
        ));
      } catch (_) {}
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// Read the first [previewBytes] bytes and attempt UTF-8 decode. Returns
  /// the preview text and whether the file appears to be binary.
  static Future<({String text, bool isBinary, int totalSize})> readPreview(
      String path) async {
    final file = File(path);
    if (!await file.exists()) throw Exception('File not found: $path');
    final totalSize = await file.length();
    final limit = totalSize < previewBytes ? totalSize : previewBytes;
    final bytes = <int>[];
    await file.openRead(0, limit).forEach(bytes.addAll);
    try {
      final text = utf8.decode(bytes, allowMalformed: false);
      return (text: text, isBinary: false, totalSize: totalSize);
    } catch (_) {
      return (text: '', isBinary: true, totalSize: totalSize);
    }
  }

  /// Read the full file in [chunkSize]-byte blocks, calling [onChunk] for each.
  /// [onChunk] receives (chunkIndex, base64EncodedBytes, totalChunks).
  /// Throws if the file is missing or exceeds [maxDownloadBytes].
  static Future<void> readChunked(
    String path,
    Future<void> Function(int index, String base64Data, int total) onChunk,
  ) async {
    final file = File(path);
    if (!await file.exists()) throw Exception('File not found: $path');
    final size = await file.length();
    if (size > maxDownloadBytes) {
      throw Exception(
          'File too large to download (${(size / (1024 * 1024)).toStringAsFixed(1)} MB — limit is 50 MB)');
    }
    final total = size == 0 ? 1 : (size / chunkSize).ceil();
    final raf = await file.open();
    try {
      int index = 0;
      int offset = 0;
      while (offset < size || (size == 0 && index == 0)) {
        final count = (size - offset).clamp(0, chunkSize);
        final bytes = count > 0 ? await raf.read(count) : Uint8List(0);
        final b64 = base64.encode(bytes);
        await onChunk(index, b64, total);
        index++;
        offset += count;
        if (size == 0) break; // empty file
        // Yield to the event loop between chunks to keep the app responsive
        // and avoid saturating the data-channel send buffer.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      await raf.close();
    }
  }

  /// Canonical common paths on Android external storage.
  static List<({String label, String path})> commonFolders() => [
        (label: 'Downloads', path: '/storage/emulated/0/Download'),
        (label: 'Documents', path: '/storage/emulated/0/Documents'),
        (label: 'Pictures', path: '/storage/emulated/0/Pictures'),
        (label: 'DCIM / Camera', path: '/storage/emulated/0/DCIM'),
        (label: 'Music', path: '/storage/emulated/0/Music'),
        (label: 'Videos', path: '/storage/emulated/0/Movies'),
      ];
}
