import 'dart:io';

import 'package:desktop_folder_locker/engine/drive/drive_helper.dart';
import 'package:desktop_folder_locker/engine/drive/drive_operations.dart';
import 'package:desktop_folder_locker/engine/drive/drive_service.dart';
import 'package:desktop_folder_locker/engine/engine_exception.dart';
import 'package:desktop_folder_locker/engine/vault/drive_vault.dart';
import 'package:desktop_folder_locker/engine/vault/vault_keys.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/test_env.dart';

/// The drive helper built by `cargo build` in `native/`, if any.
String? _builtHelper() {
  final name = Platform.isWindows ? 'cloak_drive.exe' : 'cloak_drive';
  for (final profile in ['debug', 'release']) {
    final path = p.join('native', 'target', profile, name);
    if (File(path).existsSync()) return p.absolute(path);
  }
  return null;
}

/// The app and the real drive helper together: the header and key slots
/// written here, the data key sent over the pipe, and the helper's import,
/// check and export. (Mounting needs Windows and Dokany: see
/// `native/drive/tests/drive.rs`.)
void main() {
  final helper = _builtHelper();
  final skip = helper == null
      ? 'Build the helper first: cargo build in native/'
      : false;

  late TestEnv env;
  late HelperDriveService drives;
  var counter = 0;

  setUp(() async {
    env = await TestEnv.create();
    drives = HelperDriveService(helper!);
  });
  tearDown(() async {
    await drives.dispose();
    await env.dispose();
  });

  String newId() => '${(++counter).toString().padLeft(8, '0')}-test';

  test('reports its status', () async {
    final status = await drives.status();
    if (!Platform.isWindows) expect(status.installed, isFalse);
  }, skip: skip);

  test('turns a folder into a drive vault and back', () async {
    final folder = env.createSampleFolder('Taxes');
    final before = snapshotTree(folder.path);
    final operations = DriveOperations(crypto: env.crypto, drives: drives);
    final vaultPath = env.path('Taxes${DriveVault.extension}');

    final locked = await operations.lock(
      operationId: newId(),
      folderPath: folder.path,
      vaultPath: vaultPath,
      journalDir: env.journalDir,
      slots: VaultSlotsSpec(master: env.derive('correct horse')),
    );
    expect(locked.cleanupFailures, isEmpty);
    expect(locked.stats.files, 6);
    expect(folder.existsSync(), isFalse);
    // Only encrypted names are stored.
    for (final entry in Directory(
      p.join(vaultPath, 'data'),
    ).listSync(recursive: true)) {
      final name = p.basename(entry.path);
      expect(before.keys.any((path) => p.basename(path) == name), isFalse);
    }

    final opened = DriveVault.openKey(
      crypto: env.crypto,
      path: vaultPath,
      credential: const PasswordCredential('correct horse'),
    );
    addTearDown(() {
      opened.dataKey.dispose();
      opened.derivedKey?.dispose();
    });
    final restored = await operations.export(
      operationId: newId(),
      vaultPath: vaultPath,
      folderPath: folder.path,
      journalDir: env.journalDir,
      dataKey: opened.dataKey,
    );
    expect(restored.folderPath, folder.path);
    expect(Directory(vaultPath).existsSync(), isFalse);
    expectSameTree(before, snapshotTree(folder.path));
  }, skip: skip);

  test('refuses a key that is not the vault\'s', () async {
    final operations = DriveOperations(crypto: env.crypto, drives: drives);
    final vaultPath = env.path('A${DriveVault.extension}');
    await operations.lock(
      operationId: newId(),
      folderPath: env.createSampleFolder('A').path,
      vaultPath: vaultPath,
      journalDir: env.journalDir,
      slots: VaultSlotsSpec(master: env.derive('pw')),
    );
    final other = env.crypto.randomKey();
    addTearDown(other.dispose);
    await expectLater(
      drives.exportFolder(
        vault: vaultPath,
        key: other,
        target: env.path('Out'),
      ),
      throwsA(
        isA<EngineException>().having(
          (e) => e.code,
          'code',
          EngineErrorCode.wrongPassword,
        ),
      ),
    );
    expect(Directory(env.path('Out')).existsSync(), isFalse);
  }, skip: skip);

  test('mounting says why it can\'t', () async {
    if (Platform.isWindows) return;
    final key = env.crypto.randomKey();
    addTearDown(key.dispose);
    await expectLater(
      drives.mount(vault: env.path('none'), key: key, label: 'x'),
      throwsA(isA<DriveException>()),
    );
  }, skip: skip);
}
