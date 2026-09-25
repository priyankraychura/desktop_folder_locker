import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Reads and writes one JSON document, crash-safely.
///
/// A write goes to `file.tmp` first (flushed to disk), the previous version
/// is copied to `file.bak`, then the temp file replaces the original in one
/// step. The file is never missing, not even for a moment: the Explorer
/// plug-in reads `items.json` as soon as it changes. If the main file is
/// damaged, [read] falls back to the backup.
class JsonFileStore {
  JsonFileStore(
    this.path, {
    this.retryDelay = const Duration(milliseconds: 50),
  });

  final String path;

  /// How long to wait before trying again when another program (an
  /// antivirus, the search indexer, a backup tool) briefly holds the file;
  /// longer each time.
  final Duration retryDelay;

  static const int _attempts = 5;

  Future<void> _queue = Future.value();

  String get _backupPath => '$path.bak';
  String get _tempPath => '$path.tmp';

  /// Returns the stored document, or `null` if nothing was saved yet.
  Future<Map<String, Object?>?> read() async {
    for (final candidate in [path, _backupPath]) {
      final file = File(candidate);
      if (!file.existsSync()) continue;
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, Object?>) return decoded;
      } on FormatException {
        // Damaged: try the backup.
      }
    }
    return null;
  }

  /// Saves [data]. Writes are queued, so they never interleave.
  Future<void> write(Map<String, Object?> data) {
    final next = _queue.then((_) => _write(data));
    _queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _write(Map<String, Object?> data) async {
    final encoded = const JsonEncoder.withIndent('  ').convert(data);
    final temp = File(_tempPath);
    await temp.parent.create(recursive: true);
    await _retry(() => temp.writeAsString(encoded, flush: true));
    final current = File(path);
    if (current.existsSync()) {
      try {
        await _retry(() => current.copy(_backupPath));
      } on FileSystemException {
        // The backup is a safety net: the older one stays.
      }
    }
    // Replaces the file in one step (MoveFileEx with REPLACE_EXISTING).
    await _retry(() => temp.rename(path));
  }

  Future<T> _retry<T>(Future<T> Function() action) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await action();
      } on FileSystemException {
        if (attempt >= _attempts) rethrow;
        await Future<void>.delayed(retryDelay * attempt);
      }
    }
  }
}
