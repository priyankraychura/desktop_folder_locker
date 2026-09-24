import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../crypto/crypto_service.dart';
import '../engine_exception.dart';
import '../operations/operation_progress.dart';
import 'drive_service.dart';

/// Talks to the drive helper (`cloak_drive.exe`), one JSON object
/// per line on its stdin and stdout (see `native/drive/src/protocol.rs`).
///
/// The helper starts on first use. When its stdin closes (the app quits or
/// stops unexpectedly), it closes every drive and exits, so no vault stays
/// open by accident.
class HelperDriveService implements DriveService {
  HelperDriveService(this.executable);

  /// The helper next to the app's executable, or the one named by the
  /// `CLOAK_DRIVE` environment variable (for development).
  static String defaultExecutable() {
    final override = Platform.environment['CLOAK_DRIVE'];
    if (override != null && override.isNotEmpty) return override;
    return p.join(
      p.dirname(Platform.resolvedExecutable),
      Platform.isWindows ? 'cloak_drive.exe' : 'cloak_drive',
    );
  }

  final String executable;

  Process? _process;
  Future<Process>? _starting;
  var _nextId = 1;
  final Map<int, _Pending> _pending = {};

  /// Open drives, by normalized vault path (the value is the path as the
  /// caller spelled it).
  final Map<String, String> _mounted = {};
  final StreamController<String> _unmounted =
      StreamController<String>.broadcast();

  @override
  Stream<String> get unmounted => _unmounted.stream;

  @override
  Future<DokanyStatus> status() async {
    final result = await _call({'cmd': 'hello'});
    final dokany = result['dokany'];
    return switch (dokany) {
      {'installed': true} => const DokanyStatus(installed: true),
      {'reason': final String reason} => DokanyStatus(
        installed: false,
        outdated: dokany['outdated'] == true,
        reason: reason,
      ),
      _ => const DokanyStatus(installed: false),
    };
  }

  @override
  Future<DriveStats> importFolder({
    required String vault,
    required SecureKey key,
    required String source,
    void Function(OperationProgress progress)? onProgress,
    DriveCancelToken? cancel,
  }) async => _stats(
    await _call(
      {'cmd': 'import', 'vault': vault, 'source': source},
      key: key,
      onProgress: onProgress == null
          ? null
          : (event) => onProgress(_progress(event, OperationPhase.encrypting)),
      cancel: cancel,
    ),
  );

  @override
  Future<DriveStats> exportFolder({
    required String vault,
    required SecureKey key,
    required String target,
    void Function(OperationProgress progress)? onProgress,
    DriveCancelToken? cancel,
  }) async => _stats(
    await _call(
      {'cmd': 'export', 'vault': vault, 'target': target},
      key: key,
      onProgress: onProgress == null
          ? null
          : (event) => onProgress(_progress(event, OperationPhase.decrypting)),
      cancel: cancel,
    ),
  );

  @override
  Future<DriveMount> mount({
    required String vault,
    required SecureKey key,
    required String label,
  }) async {
    final result = await _call(
      {'cmd': 'mount', 'vault': vault, 'label': label},
      key: key,
      mounting: true,
    );
    _mounted[_key(vault)] = vault;
    return DriveMount(mountPoint: result['mountPoint']! as String);
  }

  @override
  Future<void> unmount(String vault, {bool force = false}) async {
    // Without a running helper, nothing is open.
    if (_process == null) return;
    try {
      await _call({'cmd': 'unmount', 'vault': vault, 'force': force});
    } on _NotMounted {
      // Closed already.
    }
    _mounted.remove(_key(vault));
  }

  @override
  Future<void> dispose() async {
    final process = _process;
    if (process == null) return;
    try {
      // The helper closes every drive and exits.
      await process.stdin.close();
    } on Object {
      // It stopped already.
    }
    await process.exitCode.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
  }

  // -------------------------------------------------------------------------

  Future<Map<String, Object?>> _call(
    Map<String, Object?> fields, {
    SecureKey? key,
    void Function(Map<String, Object?> event)? onProgress,
    DriveCancelToken? cancel,
    bool mounting = false,
  }) async {
    final process = await _ensureStarted();
    final id = _nextId++;
    final pending = _Pending(onProgress, mounting: mounting);
    _pending[id] = pending;
    final bytes = _encode({'id': id, ...fields}, key);
    try {
      process.stdin.add(bytes);
      await process.stdin.flush();
    } on Object {
      _pending.remove(id);
      throw const DriveException(
        DriveErrorCode.helperStopped,
        'The drive helper stopped',
      );
    } finally {
      // It may hold a key.
      bytes.fillRange(0, bytes.length, 0);
    }
    cancel?.onCancel(
      () => unawaited(
        _call({'cmd': 'cancel', 'target': id})
            .then((_) {}, onError: (Object _) {}),
      ),
    );
    return pending.completer.future;
  }

  Future<Process> _ensureStarted() {
    final process = _process;
    if (process != null) return Future.value(process);
    return _starting ??= _start();
  }

  Future<Process> _start() async {
    try {
      if (!File(executable).existsSync()) {
        throw const DriveException(
          DriveErrorCode.helperMissing,
          'The drive helper is not installed',
        );
      }
      final Process process;
      try {
        process = await Process.start(executable, const []);
      } on ProcessException catch (error) {
        throw DriveException(DriveErrorCode.helperMissing, error.message);
      }
      _process = process;
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_onLine);
      process.stderr.listen((_) {});
      unawaited(process.exitCode.then((_) => _onExit(process)));
      return process;
    } finally {
      _starting = null;
    }
  }

  void _onExit(Process process) {
    if (!identical(_process, process)) return;
    _process = null;
    final pending = [..._pending.values];
    _pending.clear();
    for (final request in pending) {
      request.completer.completeError(
        const DriveException(
          DriveErrorCode.helperStopped,
          'The drive helper stopped',
        ),
      );
    }
    // Its drives closed with it.
    final vaults = [..._mounted.values];
    _mounted.clear();
    vaults.forEach(_unmounted.add);
  }

  void _onLine(String line) {
    final Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (message is! Map<String, Object?>) return;
    switch (message) {
      case {'event': 'unmounted', 'vault': final String vault}:
        if (_mounted.remove(_key(vault)) != null) _unmounted.add(vault);
      case {'id': final int id, 'event': 'progress'}:
        _pending[id]?.onProgress?.call(message);
      case {'id': final int id, 'ok': true}:
        final result = message['result'];
        _pending
            .remove(id)
            ?.completer
            .complete(
              result is Map<String, Object?> ? result : <String, Object?>{},
            );
      case {'id': final int id, 'ok': false}:
        final pending = _pending.remove(id);
        if (pending == null) return;
        final error = message['error'];
        final (code, text) = switch (error) {
          {'code': final String code, 'message': final String text} => (
            code,
            text,
          ),
          _ => ('failed', 'The drive helper failed'),
        };
        pending.completer.completeError(
          _error(code, text, mounting: pending.mounting),
        );
    }
  }

  static String _key(String vault) => p.normalize(vault).toLowerCase();

  static DriveStats _stats(Map<String, Object?> result) => DriveStats(
    files: result['files'] as int? ?? 0,
    folders: result['folders'] as int? ?? 0,
    bytes: result['bytes'] as int? ?? 0,
  );

  static OperationProgress _progress(
    Map<String, Object?> event,
    OperationPhase copying,
  ) => OperationProgress(
    phase: event['phase'] == 'verify' ? OperationPhase.verifying : copying,
    processedBytes: event['done'] as int? ?? 0,
    totalBytes: event['total'] as int? ?? 0,
  );

  /// Turns the helper's error codes into the app's exceptions.
  static Object _error(String code, String message, {required bool mounting}) {
    EngineException engine(EngineErrorCode code) =>
        EngineException(code, message);
    return switch (code) {
      'notMounted' => const _NotMounted(),
      'dokanyMissing' => DriveException(DriveErrorCode.dokanyMissing, message),
      'noDriveLetter' => DriveException(DriveErrorCode.noDriveLetter, message),
      'alreadyMounted' => DriveException(
        DriveErrorCode.alreadyMounted,
        message,
      ),
      'unmountFailed' => DriveException(DriveErrorCode.unmountFailed, message),
      'inUse' => DriveException(DriveErrorCode.inUse, message),
      'mountFailed' => DriveException(DriveErrorCode.mountFailed, message),
      'unsupported' when mounting => DriveException(
        DriveErrorCode.mountFailed,
        message,
      ),
      'unsupported' => engine(EngineErrorCode.unsupportedContent),
      'notFound' => engine(EngineErrorCode.notFound),
      'alreadyExists' => engine(EngineErrorCode.alreadyExists),
      'corrupt' => engine(EngineErrorCode.corruptVault),
      'mismatch' => EngineException(
        EngineErrorCode.corruptVault,
        'Verification failed: $message',
      ),
      'cancelled' => engine(EngineErrorCode.cancelled),
      'wrongKey' => engine(EngineErrorCode.wrongPassword),
      'notAVault' ||
      'unsupportedVersion' => engine(EngineErrorCode.unsupportedVersion),
      'io' => engine(_ioCode(message)),
      _ => engine(EngineErrorCode.ioError),
    };
  }

  /// Windows error numbers in the helper's messages ("(os error 112)").
  static EngineErrorCode _ioCode(String message) {
    final match = RegExp(r'\(os error (\d+)\)').firstMatch(message);
    return switch (int.tryParse(match?.group(1) ?? '')) {
      5 => EngineErrorCode.accessDenied,
      32 || 33 => EngineErrorCode.inUse,
      39 || 112 || 28 => EngineErrorCode.diskFull,
      _ => EngineErrorCode.ioError,
    };
  }

  /// A request line. The key is written into the bytes directly, never
  /// into a Dart string, so it can be wiped once sent.
  static Uint8List _encode(Map<String, Object?> fields, SecureKey? key) {
    final json = utf8.encode(jsonEncode(fields));
    if (key == null) return Uint8List.fromList([...json, 0x0a]);
    return key.runUnlockedSync((raw) {
      final encoded = _base64(raw);
      final field = utf8.encode(',"key":"');
      // `json` ends with "}": the key goes in before it.
      final out = Uint8List(json.length - 1 + field.length + encoded.length + 3)
        ..setRange(0, json.length - 1, json);
      var at = json.length - 1;
      out.setRange(at, at += field.length, field);
      out.setRange(at, at += encoded.length, encoded);
      out
        ..[at] =
            0x22 // "
        ..[at + 1] =
            0x7d // }
        ..[at + 2] = 0x0a; // newline
      encoded.fillRange(0, encoded.length, 0);
      return out;
    });
  }

  static const String _alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  /// Standard base64, as bytes.
  static Uint8List _base64(Uint8List data) {
    final out = Uint8List((data.length + 2) ~/ 3 * 4);
    var o = 0;
    for (var i = 0; i < data.length; i += 3) {
      final b0 = data[i];
      final b1 = i + 1 < data.length ? data[i + 1] : 0;
      final b2 = i + 2 < data.length ? data[i + 2] : 0;
      out[o++] = _alphabet.codeUnitAt(b0 >> 2);
      out[o++] = _alphabet.codeUnitAt(((b0 & 3) << 4) | (b1 >> 4));
      out[o++] = i + 1 < data.length
          ? _alphabet.codeUnitAt(((b1 & 15) << 2) | (b2 >> 6))
          : 0x3d;
      out[o++] = i + 2 < data.length ? _alphabet.codeUnitAt(b2 & 63) : 0x3d;
    }
    return out;
  }
}

class _Pending {
  _Pending(this.onProgress, {required this.mounting});

  final void Function(Map<String, Object?> event)? onProgress;
  final bool mounting;
  final Completer<Map<String, Object?>> completer = Completer();
}

class _NotMounted implements Exception {
  const _NotMounted();
}
