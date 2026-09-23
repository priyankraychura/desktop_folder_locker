import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'windows/win32_ffi.dart';

/// Keeps a single copy of the app running.
///
/// The first copy holds an exclusive lock on `instance.lock`. When Explorer
/// starts another copy (double-clicking a vault, "Lock with…" in the
/// context menu), it writes its arguments into the `inbox` folder and
/// exits; the first copy picks them up and shows the right dialog.
class SingleInstance {
  SingleInstance._(this._lockFile, this._inboxDir);

  final RandomAccessFile _lockFile;
  final String _inboxDir;
  final StreamController<List<String>> _messages =
      StreamController<List<String>>.broadcast();
  StreamSubscription<FileSystemEvent>? _watch;
  Timer? _poll;
  bool _draining = false;

  static const Duration _maxMessageAge = Duration(minutes: 2);

  /// Returns `null` if another copy of the app already holds the lock.
  static Future<SingleInstance?> acquire({
    required String lockPath,
    required String inboxDir,
  }) async {
    final file = await File(lockPath).open(mode: FileMode.append);
    try {
      await file.lock();
    } on FileSystemException {
      await file.close();
      return null;
    }
    return SingleInstance._(file, inboxDir).._start();
  }

  /// Sends [args] to the running copy of the app.
  static Future<void> forward({
    required String inboxDir,
    required List<String> args,
  }) async {
    await Directory(inboxDir).create(recursive: true);
    final name = '${DateTime.now().microsecondsSinceEpoch}-$pid';
    final temp = File(p.join(inboxDir, '$name.tmp'));
    await temp.writeAsString(
      jsonEncode({
        'args': args,
        'sentAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    // The rename makes the message appear complete, all at once.
    await temp.rename(p.join(inboxDir, '$name.json'));
    // Let the running copy bring its window to the front.
    if (Platform.isWindows) Win32.allowSetForegroundWindow();
  }

  /// Arguments forwarded by later copies of the app.
  Stream<List<String>> get messages => _messages.stream;

  void _start() {
    Directory(_inboxDir).createSync(recursive: true);
    _watch = Directory(_inboxDir).watch().listen((_) => deliverPending());
    // Directory events can be missed; polling is a cheap safety net.
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => deliverPending());
  }

  /// Delivers messages that are already waiting in the inbox.
  void deliverPending() {
    if (_draining) return;
    _draining = true;
    try {
      final files =
          Directory(_inboxDir)
              .listSync()
              .whereType<File>()
              .where((file) => file.path.endsWith('.json'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        _deliver(file);
      }
    } on FileSystemException {
      // Try again at the next poll.
    } finally {
      _draining = false;
    }
  }

  void _deliver(File file) {
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      file.deleteSync();
      if (decoded is! Map<String, Object?>) return;
      final sentAt = DateTime.tryParse(decoded['sentAt'] as String? ?? '');
      if (sentAt == null ||
          DateTime.now().toUtc().difference(sentAt) > _maxMessageAge) {
        return; // Stale request from an earlier session: ignore it.
      }
      final args = decoded['args'];
      if (args is List<Object?>) {
        _messages.add([
          for (final arg in args)
            if (arg is String) arg,
        ]);
      }
    } on FormatException {
      file.deleteSync();
    } on FileSystemException {
      // Locked by the writer; picked up next time.
    }
  }

  Future<void> dispose() async {
    await _watch?.cancel();
    _poll?.cancel();
    await _messages.close();
    await _lockFile.unlock();
    await _lockFile.close();
  }
}
