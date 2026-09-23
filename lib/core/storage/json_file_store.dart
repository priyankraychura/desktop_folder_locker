import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Reads and writes one JSON document, crash-safely.
///
/// A write goes to `file.tmp` first (flushed to disk), the previous version
/// is kept as `file.bak`, then the temp file replaces the original. If the
/// main file is missing or damaged, [read] falls back to the backup.
class JsonFileStore {
  JsonFileStore(this.path);

  final String path;
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
    await temp.writeAsString(encoded, flush: true);
    final current = File(path);
    if (current.existsSync()) {
      await current.rename(_backupPath);
    }
    await temp.rename(path);
  }
}
