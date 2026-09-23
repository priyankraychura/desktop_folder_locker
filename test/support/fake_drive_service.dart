import 'dart:async';
import 'dart:io';

import 'package:desktop_folder_locker/engine/crypto/crypto_service.dart';
import 'package:desktop_folder_locker/engine/drive/drive_service.dart';
import 'package:desktop_folder_locker/engine/engine_exception.dart';
import 'package:desktop_folder_locker/engine/operations/operation_progress.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Stands in for the drive helper: "imports" by copying files as they are
/// (no encryption), and "mounts" by recording the vault.
///
/// It remembers the data key each vault was created with (by the vault id
/// in its header), and refuses any other key, so tests check that the app
/// opens the right key from a vault's key slots.
class FakeDriveService implements DriveService {
  DokanyStatus dokany = const DokanyStatus(installed: true);

  /// Makes the next import fail with this error.
  Object? failNextImport;

  /// Open drives: vault folder → mount point.
  final Map<String, String> mounts = {};

  /// Vault folders whose drive has files open in programs, so it only
  /// closes when forced.
  final Set<String> busy = {};

  final Map<String, Uint8List> _keys = {};
  final StreamController<String> _unmounted =
      StreamController<String>.broadcast();
  var _nextLetter = 'V'.codeUnitAt(0);

  @override
  Stream<String> get unmounted => _unmounted.stream;

  /// Closes a drive from outside the app (like ejecting it in Explorer).
  void eject(String vault) {
    mounts.remove(_normal(vault));
    _unmounted.add(vault);
  }

  @override
  Future<DokanyStatus> status() async => dokany;

  @override
  Future<DriveStats> importFolder({
    required String vault,
    required SecureKey key,
    required String source,
    void Function(OperationProgress progress)? onProgress,
    DriveCancelToken? cancel,
  }) async {
    if (failNextImport case final error?) {
      failNextImport = null;
      throw error;
    }
    final data = Directory(p.join(vault, 'data'));
    if (data.existsSync()) {
      throw const EngineException(EngineErrorCode.alreadyExists, 'data');
    }
    _keys[_vaultId(vault)] = key.extractBytes();
    final stats = _copy(Directory(source), data);
    onProgress?.call(
      OperationProgress(
        phase: OperationPhase.verifying,
        processedBytes: stats.bytes,
        totalBytes: stats.bytes,
      ),
    );
    return stats;
  }

  @override
  Future<DriveStats> exportFolder({
    required String vault,
    required SecureKey key,
    required String target,
    void Function(OperationProgress progress)? onProgress,
    DriveCancelToken? cancel,
  }) async {
    _checkKey(vault, key);
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      throw const EngineException(EngineErrorCode.alreadyExists, 'target');
    }
    return _copy(Directory(p.join(vault, 'data')), Directory(target));
  }

  @override
  Future<DriveMount> mount({
    required String vault,
    required SecureKey key,
    required String label,
  }) async {
    _checkKey(vault, key);
    if (mounts.containsKey(_normal(vault))) {
      throw const DriveException(DriveErrorCode.alreadyMounted, 'open');
    }
    final point = '${String.fromCharCode(_nextLetter++)}:\\';
    mounts[_normal(vault)] = point;
    return DriveMount(mountPoint: point);
  }

  @override
  Future<void> unmount(String vault, {bool force = false}) async {
    if (!force &&
        isMounted(vault) &&
        busy.map(_normal).contains(_normal(vault))) {
      throw const DriveException(DriveErrorCode.inUse, 'files are open');
    }
    mounts.remove(_normal(vault));
  }

  @override
  Future<void> dispose() async {}

  /// Whether [vault] is open as a drive.
  bool isMounted(String vault) => mounts.containsKey(_normal(vault));

  void _checkKey(String vault, SecureKey key) {
    final expected = _keys[_vaultId(vault)];
    if (expected == null || !listEquals(expected, key.extractBytes())) {
      throw const EngineException(
        EngineErrorCode.wrongPassword,
        'The key doesn\'t open this vault',
      );
    }
  }

  static String _normal(String path) => p.normalize(path).toLowerCase();

  /// The vault id from the header, which stays the same when the vault
  /// folder is renamed.
  static String _vaultId(String vault) {
    final header = File(p.join(vault, 'vault.flk')).readAsBytesSync();
    return header
        .sublist(16, 32)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static DriveStats _copy(Directory from, Directory to) {
    var files = 0;
    var folders = 0;
    var bytes = 0;
    void copy(Directory source, Directory target) {
      target.createSync(recursive: true);
      for (final entry in source.listSync()) {
        final name = p.basename(entry.path);
        if (entry is Directory) {
          folders++;
          copy(entry, Directory(p.join(target.path, name)));
        } else if (entry is File) {
          files++;
          bytes += entry.lengthSync();
          entry.copySync(p.join(target.path, name));
        }
      }
    }

    copy(from, to);
    return DriveStats(files: files, folders: folders, bytes: bytes);
  }
}
