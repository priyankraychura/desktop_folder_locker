import 'dart:io';

import 'package:desktop_folder_locker/engine/crypto/recovery_key.dart';
import 'package:desktop_folder_locker/engine/engine_exception.dart';
import 'package:desktop_folder_locker/engine/format/archive.dart';
import 'package:desktop_folder_locker/engine/format/key_slot.dart';
import 'package:desktop_folder_locker/engine/format/vault_header.dart';
import 'package:desktop_folder_locker/engine/operations/journal.dart';
import 'package:desktop_folder_locker/engine/operations/lock_operation.dart';
import 'package:desktop_folder_locker/engine/operations/operation_progress.dart';
import 'package:desktop_folder_locker/engine/operations/rekey_operation.dart';
import 'package:desktop_folder_locker/engine/operations/reseal_operation.dart';
import 'package:desktop_folder_locker/engine/operations/unlock_operation.dart';
import 'package:desktop_folder_locker/engine/vault/vault_keys.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/test_env.dart';

void main() {
  late TestEnv env;
  var counter = 0;

  setUp(() async => env = await TestEnv.create());
  tearDown(() => env.dispose());

  String newId() => '${(++counter).toString().padLeft(8, '0')}-test';

  Matcher throwsEngine(EngineErrorCode code) =>
      throwsA(isA<EngineException>().having((e) => e.code, 'code', code));

  LockResult lock(
    String itemPath,
    VaultSlotsSpec slots, {
    CancellationToken? cancel,
    void Function(OperationProgress)? onProgress,
  }) =>
      LockOperation(
        crypto: env.crypto,
        progress: onProgress == null
            ? ProgressReporter.silent()
            : ProgressReporter(onProgress, interval: Duration.zero),
        cancel: cancel ?? CancellationToken(),
      ).run(
        LockRequest(
          operationId: newId(),
          itemPath: itemPath,
          vaultPath: '$itemPath.flk',
          journalDir: env.journalDir,
        ),
        slots,
      );

  UnlockResult unlock(
    String vaultPath,
    VaultCredential credential, {
    String? target,
    CancellationToken? cancel,
  }) =>
      UnlockOperation(
        crypto: env.crypto,
        progress: ProgressReporter.silent(),
        cancel: cancel ?? CancellationToken(),
      ).run(
        UnlockRequest(
          operationId: newId(),
          vaultPath: vaultPath,
          targetPath: target ?? p.withoutExtension(vaultPath),
          journalDir: env.journalDir,
        ),
        credential,
      );

  test('locks a folder and restores it byte-for-byte', () {
    final folder = env.createSampleFolder('Secret');
    final before = snapshotTree(folder.path);
    final master = env.derive('correct horse');
    final phases = <OperationPhase>{};

    final result = lock(
      folder.path,
      VaultSlotsSpec(master: master),
      onProgress: (progress) => phases.add(progress.phase),
    );

    expect(folder.existsSync(), isFalse);
    expect(File(result.vaultPath).existsSync(), isTrue);
    expect(result.kind, ItemKind.folder);
    expect(result.cleanupFailures, isEmpty);
    expect(result.fileCount, 6);
    expect(result.folderCount, 4);
    expect(phases, containsAll(OperationPhase.values.take(3)));
    // Nothing is left behind.
    expect(
      env.root.listSync().map((e) => p.basename(e.path)),
      unorderedEquals(['Secret.flk', '_journal']),
    );

    final unlocked = unlock(
      result.vaultPath,
      const PasswordCredential('correct horse'),
    );
    expect(unlocked.restoredPath, folder.path);
    expect(unlocked.openedWith, KeySlotType.masterPassword);
    expect(unlocked.vaultRemoved, isTrue);
    expect(unlocked.derivedKey, isNotNull);
    expect(File(result.vaultPath).existsSync(), isFalse);
    expectSameTree(before, snapshotTree(folder.path));
    expect(Journal(env.journalDir).pending(), isEmpty);
  });

  test('locks a single file and keeps its modified time', () {
    final file = File(env.path('report.pdf'))..writeAsStringSync('PDF data');
    final modified = DateTime(2024, 5, 17, 10, 30);
    file.setLastModifiedSync(modified);

    final result = lock(file.path, VaultSlotsSpec(master: env.derive('pw')));
    expect(result.kind, ItemKind.file);
    expect(file.existsSync(), isFalse);

    final unlocked = unlock(result.vaultPath, const PasswordCredential('pw'));
    expect(unlocked.kind, ItemKind.file);
    expect(File(unlocked.restoredPath).readAsStringSync(), 'PDF data');
    expect(
      File(unlocked.restoredPath).lastModifiedSync().millisecondsSinceEpoch,
      modified.millisecondsSinceEpoch,
    );
  });

  test('wrong password changes nothing', () {
    final folder = env.createSampleFolder('Secret');
    final result = lock(folder.path, VaultSlotsSpec(master: env.derive('a')));
    final vaultBytes = File(result.vaultPath).readAsBytesSync();

    expect(
      () => unlock(result.vaultPath, const PasswordCredential('b')),
      throwsEngine(EngineErrorCode.wrongPassword),
    );
    expect(File(result.vaultPath).readAsBytesSync(), vaultBytes);
    expect(folder.existsSync(), isFalse);
  });

  test('custom password, master key and recovery key all open a vault', () {
    final recovery = RecoveryKey.generate(env.crypto);
    final pair = recovery.keyPair(env.crypto);
    final master = env.derive('master');
    final custom = env.derive('custom');

    void roundTrip(VaultCredential credential, KeySlotType expected) {
      final folder = env.createSampleFolder('Item');
      final result = lock(
        folder.path,
        VaultSlotsSpec(
          master: master,
          custom: custom,
          recoveryPublicKey: pair.publicKey,
        ),
      );
      final unlocked = unlock(result.vaultPath, credential);
      expect(unlocked.openedWith, expected);
      Directory(unlocked.restoredPath).deleteSync(recursive: true);
    }

    roundTrip(const PasswordCredential('custom'), KeySlotType.customPassword);
    roundTrip(const PasswordCredential('master'), KeySlotType.masterPassword);
    roundTrip(
      DerivedKeyCredential(master, KeySlotType.masterPassword),
      KeySlotType.masterPassword,
    );
    roundTrip(RecoveryCredential(recovery), KeySlotType.recovery);
    roundTrip(
      RecoveryCredential(RecoveryKey.tryParse(recovery.format())!),
      KeySlotType.recovery,
    );
  });

  test('a session key with another salt does not match', () {
    final folder = env.createSampleFolder('Item');
    final result = lock(folder.path, VaultSlotsSpec(master: env.derive('pw')));
    expect(
      () => unlock(
        result.vaultPath,
        DerivedKeyCredential(env.derive('pw'), KeySlotType.masterPassword),
      ),
      throwsEngine(EngineErrorCode.wrongPassword),
    );
  });

  test('rekey replaces the master password and keeps other slots', () {
    final recovery = RecoveryKey.generate(env.crypto);
    final oldMaster = env.derive('old');
    final newMaster = env.derive('new');
    final folder = env.createSampleFolder('Item');
    final before = snapshotTree(folder.path);
    final result = lock(
      folder.path,
      VaultSlotsSpec(
        master: oldMaster,
        recoveryPublicKey: recovery.keyPair(env.crypto).publicKey,
      ),
    );

    RekeyOperation(env.crypto).run(
      vaultPath: result.vaultPath,
      credential: RecoveryCredential(recovery),
      newMaster: newMaster,
    );

    expect(
      () => unlock(result.vaultPath, const PasswordCredential('old')),
      throwsEngine(EngineErrorCode.wrongPassword),
    );
    final header = VaultHeader.read(result.vaultPath, env.crypto);
    expect(header.slots.whereType<RecoveryKeySlot>(), hasLength(1));
    final unlocked = unlock(result.vaultPath, const PasswordCredential('new'));
    expectSameTree(before, snapshotTree(unlocked.restoredPath));
  });

  test('reseal switches a vault to a new recovery key', () {
    final oldKey = RecoveryKey.generate(env.crypto);
    final newKey = RecoveryKey.generate(env.crypto);
    final newPublicKey = newKey.keyPair(env.crypto).publicKey;
    final master = env.derive('master');
    final folder = env.createSampleFolder('Item');
    final before = snapshotTree(folder.path);
    final result = lock(
      folder.path,
      VaultSlotsSpec(
        master: master,
        recoveryPublicKey: oldKey.keyPair(env.crypto).publicKey,
      ),
    );
    final reseal = ResealOperation(env.crypto);

    // Without a key the vault can only be checked.
    expect(
      reseal.run(vaultPath: result.vaultPath, recoveryPublicKey: newPublicKey),
      ResealResult.needsKey,
    );
    expect(
      reseal.run(
        vaultPath: result.vaultPath,
        recoveryPublicKey: newPublicKey,
        credential: DerivedKeyCredential(master, KeySlotType.masterPassword),
      ),
      ResealResult.updated,
    );
    expect(
      reseal.run(vaultPath: result.vaultPath, recoveryPublicKey: newPublicKey),
      ResealResult.alreadyCurrent,
    );

    expect(
      () => unlock(result.vaultPath, RecoveryCredential(oldKey)),
      throwsEngine(EngineErrorCode.wrongPassword),
    );
    final header = VaultHeader.read(result.vaultPath, env.crypto);
    expect(header.slots.whereType<RecoveryKeySlot>(), hasLength(1));
    expect(header.slots.whereType<PasswordKeySlot>(), hasLength(1));
    final unlocked = unlock(result.vaultPath, RecoveryCredential(newKey));
    expectSameTree(before, snapshotTree(unlocked.restoredPath));
  });

  test('restores next to an existing item without overwriting it', () {
    final folder = env.createSampleFolder('Secret');
    final result = lock(folder.path, VaultSlotsSpec(master: env.derive('pw')));
    Directory(folder.path).createSync(); // someone created a new "Secret"

    final unlocked = unlock(result.vaultPath, const PasswordCredential('pw'));
    expect(unlocked.restoredPath, '${folder.path} (2)');
    expect(Directory(folder.path).listSync(), isEmpty);
  });

  test('cancelling a lock restores the original', () {
    final folder = env.createSampleFolder('Secret');
    final before = snapshotTree(folder.path);
    final cancel = CancellationToken();

    expect(
      () => lock(
        folder.path,
        VaultSlotsSpec(master: env.derive('pw')),
        cancel: cancel,
        onProgress: (progress) {
          if (progress.processedBytes > 0) cancel.cancel();
        },
      ),
      throwsEngine(EngineErrorCode.cancelled),
    );
    expectSameTree(before, snapshotTree(folder.path));
    expect(
      env.root.listSync().map((e) => p.basename(e.path)),
      unorderedEquals(['Secret', '_journal']),
    );
    expect(Journal(env.journalDir).pending(), isEmpty);
  });

  test('cancelling an unlock keeps the vault', () {
    final folder = env.createSampleFolder('Secret');
    final result = lock(folder.path, VaultSlotsSpec(master: env.derive('pw')));
    final cancel = CancellationToken()..cancel();
    expect(
      () => unlock(
        result.vaultPath,
        const PasswordCredential('pw'),
        cancel: cancel,
      ),
      throwsEngine(EngineErrorCode.cancelled),
    );
    expect(File(result.vaultPath).existsSync(), isTrue);
    expect(folder.existsSync(), isFalse);
    expect(
      env.root.listSync().map((e) => p.basename(e.path)),
      unorderedEquals(['Secret.flk', '_journal']),
    );
  });

  test('refuses folders containing symbolic links', () {
    final folder = env.createSampleFolder('Secret');
    Link(p.join(folder.path, 'link')).createSync(env.root.path);
    expect(
      () => lock(folder.path, VaultSlotsSpec(master: env.derive('pw'))),
      throwsEngine(EngineErrorCode.unsupportedContent),
    );
    expect(folder.existsSync(), isTrue);
  }, skip: Platform.isWindows ? 'Needs developer mode on Windows' : false);

  test('refuses to overwrite an existing vault', () {
    final folder = env.createSampleFolder('Secret');
    File('${folder.path}.flk').writeAsStringSync('existing');
    expect(
      () => lock(folder.path, VaultSlotsSpec(master: env.derive('pw'))),
      throwsEngine(EngineErrorCode.alreadyExists),
    );
    expect(folder.existsSync(), isTrue);
  });

  group('startup recovery', () {
    test('rolls back a lock interrupted before verification', () {
      final folder = env.createSampleFolder('Secret');
      final before = snapshotTree(folder.path);
      final staged = '${folder.path}.00000001.flk-locking';
      final partial = '${folder.path}.00000001.flk-partial';
      folder.renameSync(staged);
      File(partial).writeAsStringSync('half written');
      Journal(env.journalDir).save(
        JournalEntry(
          id: 'j1',
          kind: JournalKind.lock,
          phase: JournalPhase.started,
          itemPath: folder.path,
          workPath: staged,
          partialPath: partial,
          vaultPath: '${folder.path}.flk',
          startedAt: DateTime.now(),
        ),
      );

      final outcomes = JournalRecovery.run(Journal(env.journalDir));
      expect(outcomes.single.success, isTrue);
      expect(outcomes.single.completed, isFalse);
      expectSameTree(before, snapshotTree(folder.path));
      expect(File(partial).existsSync(), isFalse);
      expect(Journal(env.journalDir).pending(), isEmpty);
    });

    test('completes a lock interrupted after verification', () {
      final folder = env.createSampleFolder('Secret');
      final result = lock(
        folder.path,
        VaultSlotsSpec(master: env.derive('pw')),
      );
      // Simulate: vault verified but not moved, original still staged.
      final staged = '${folder.path}.00000002.flk-locking';
      final partial = '${folder.path}.00000002.flk-partial';
      File(result.vaultPath).renameSync(partial);
      env.createSampleFolder('Secret').renameSync(staged);
      Journal(env.journalDir).save(
        JournalEntry(
          id: 'j2',
          kind: JournalKind.lock,
          phase: JournalPhase.verified,
          itemPath: folder.path,
          workPath: staged,
          partialPath: partial,
          vaultPath: result.vaultPath,
          startedAt: DateTime.now(),
        ),
      );

      final outcomes = JournalRecovery.run(Journal(env.journalDir));
      expect(outcomes.single.completed, isTrue);
      expect(File(result.vaultPath).existsSync(), isTrue);
      expect(Directory(staged).existsSync(), isFalse);
      expect(File(partial).existsSync(), isFalse);
    });

    test('cleans up an unlock interrupted while extracting', () {
      final folder = env.createSampleFolder('Secret');
      final result = lock(
        folder.path,
        VaultSlotsSpec(master: env.derive('pw')),
      );
      final work = '${folder.path}.00000003.flk-restoring';
      Directory(work).createSync();
      File(p.join(work, 'partial.bin')).writeAsStringSync('x');
      Journal(env.journalDir).save(
        JournalEntry(
          id: 'j3',
          kind: JournalKind.unlock,
          phase: JournalPhase.started,
          itemPath: folder.path,
          workPath: work,
          vaultPath: result.vaultPath,
          startedAt: DateTime.now(),
        ),
      );

      JournalRecovery.run(Journal(env.journalDir));
      expect(Directory(work).existsSync(), isFalse);
      expect(File(result.vaultPath).existsSync(), isTrue);
    });
  });
}
