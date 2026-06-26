import 'dart:io';

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
  static const int maxTextBytes = 64 * 1024; // 64 KB cap for data-channel safety

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
    // Preserve leading slash but drop trailing slash.
    final joined = out.join('/');
    return joined.isEmpty ? '/' : joined;
  }

  // ── File system operations ─────────────────────────────────────────────────

  /// List a directory. Entries are sorted: directories first, then files, each
  /// group sorted case-insensitively. Hidden files (starting with .) are
  /// included so the host can share dotfile-heavy config directories.
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
      } catch (_) {
        // Skip entries we can't stat (broken symlinks, permission errors, etc.)
      }
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// Read a text file and return its content. Throws if the file is missing,
  /// too large, or can't be decoded as UTF-8 (binary).
  static Future<String> readTextFile(String path) async {
    final file = File(path);
    if (!await file.exists()) throw Exception('File not found: $path');
    final size = await file.length();
    if (size > maxTextBytes) {
      throw Exception('File too large (${(size / 1024).round()} KB — limit is 64 KB)');
    }
    try {
      return await file.readAsString();
    } catch (_) {
      throw Exception('Binary file — cannot display as text');
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
