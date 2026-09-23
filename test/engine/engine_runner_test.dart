import 'dart:io';

import 'package:desktop_folder_locker/engine/crypto/kdf_params.dart';
import 'package:desktop_folder_locker/engine/crypto/recovery_key.dart';
import 'package:desktop_folder_locker/engine/engine_exception.dart';
import 'package:desktop_folder_locker/engine/engine_runner.dart';
import 'package:desktop_folder_locker/engine/format/key_slot.dart';
import 'package:desktop_folder_locker/engine/operations/lock_operation.dart';
import 'package:desktop_folder_locker/engine/operations/operation_progress.dart';
import 'package:desktop_folder_locker/engine/operations/unlock_operation.dart';
import 'package:desktop_folder_locker/engine/vault/vault_keys.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_env.dart';

void main() {
  late TestEnv env;
  late EngineRunner runner;

  setUp(() async {
    env = await TestEnv.create();
    runner = EngineRunner(env.crypto);
  });
  tearDown(() => env.dispose());

  test('derives the same key as the main isolate', () async {
    final kdf = KdfPolicy.fast.withSalt(env.crypto.randomBytes(16));
    final derived = await runner.deriveKey('secret', kdf);
    expect(
      derived.key.extractBytes(),
      env.crypto.deriveKey('secret', kdf).extractBytes(),
    );
  });

  test('locks, unlocks and re-keys in background isolates', () async {
    final folder = env.createSampleFolder('Secret');
    final before = snapshotTree(folder.path);
    final master = env.derive('master');
    final recovery = RecoveryKey.generate(env.crypto);

    final lockJob = runner.lock(
      LockRequest(
        operationId: '11111111-lock',
        itemPath: folder.path,
        vaultPath: '${folder.path}.flk',
        journalDir: env.journalDir,
      ),
      VaultSlotsSpec(
        master: master,
        recoveryPublicKey: recovery.keyPair(env.crypto).publicKey,
      ),
    );
    final phases = <OperationPhase>{};
    final progressDone = lockJob.progress.forEach((p) => phases.add(p.phase));
    final locked = await lockJob.result;
    await progressDone;
    expect(phases, contains(OperationPhase.encrypting));
    expect(File(locked.vaultPath).existsSync(), isTrue);

    // The caller still owns the key it passed in.
    expect(master.key.extractBytes(), hasLength(32));

    final newMaster = env.derive('new master');
    final outcomes = await runner.rekey(
      vaultPaths: [locked.vaultPath],
      credential: DerivedKeyCredential(master, KeySlotType.masterPassword),
      newMaster: newMaster,
    );
    expect(outcomes.single.success, isTrue);

    final unlockJob = runner.unlock(
      UnlockRequest(
        operationId: '22222222-unlock',
        vaultPath: locked.vaultPath,
        targetPath: folder.path,
        journalDir: env.journalDir,
      ),
      const PasswordCredential('new master'),
    );
    final unlocked = await unlockJob.result;
    expect(unlocked.openedWith, KeySlotType.masterPassword);
    expect(
      unlocked.derivedKey!.key.extractBytes(),
      newMaster.key.extractBytes(),
    );
    expectSameTree(before, snapshotTree(folder.path));
  });

  test('reports engine errors from the isolate', () async {
    final folder = env.createSampleFolder('Secret');
    final locked = await runner
        .lock(
          LockRequest(
            operationId: '33333333-lock',
            itemPath: folder.path,
            vaultPath: '${folder.path}.flk',
            journalDir: env.journalDir,
          ),
          VaultSlotsSpec(master: env.derive('pw')),
        )
        .result;

    final job = runner.unlock(
      UnlockRequest(
        operationId: '44444444-unlock',
        vaultPath: locked.vaultPath,
        targetPath: folder.path,
        journalDir: env.journalDir,
      ),
      const PasswordCredential('wrong'),
    );
    await expectLater(
      job.result,
      throwsA(
        isA<EngineException>().having(
          (e) => e.code,
          'code',
          EngineErrorCode.wrongPassword,
        ),
      ),
    );
  });

  test('cancel stops a running lock and restores the item', () async {
    final folder = env.createSampleFolder('Secret');
    final before = snapshotTree(folder.path);
    final job = runner.lock(
      LockRequest(
        operationId: '55555555-lock',
        itemPath: folder.path,
        vaultPath: '${folder.path}.flk',
        journalDir: env.journalDir,
      ),
      VaultSlotsSpec(master: env.derive('pw')),
    )..cancel();

    try {
      await job.result;
      // Tiny folders can finish before the cancel flag is read.
    } on EngineException catch (e) {
      expect(e.code, EngineErrorCode.cancelled);
      expectSameTree(before, snapshotTree(folder.path));
    }
  });
}
