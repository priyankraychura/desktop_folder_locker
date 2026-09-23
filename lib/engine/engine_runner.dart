import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'crypto/crypto_service.dart';
import 'crypto/kdf_params.dart';
import 'engine_exception.dart';
import 'format/key_slot.dart';
import 'operations/lock_operation.dart';
import 'operations/operation_progress.dart';
import 'operations/rekey_operation.dart';
import 'operations/reseal_operation.dart';
import 'operations/unlock_operation.dart';
import 'vault/drive_vault.dart';
import 'vault/vault_keys.dart';

/// A job running in a background isolate.
class EngineJob<T> {
  EngineJob._(this.progress, this.result, this._cancel);

  /// Progress updates (throttled). Closes when the job ends.
  final Stream<OperationProgress> progress;

  /// Completes with the result, or with an [EngineException].
  final Future<T> result;

  final void Function() _cancel;

  /// Asks the job to stop. It finishes with [EngineErrorCode.cancelled]
  /// after rolling back its changes.
  void cancel() => _cancel();
}

/// Outcome of rewriting one vault's master slot.
class RekeyOutcome {
  const RekeyOutcome({required this.vaultPath, this.error});

  final String vaultPath;
  final EngineException? error;

  bool get success => error == null;
}

/// A vault to seal to a new recovery key, with a key that opens it when the
/// app has one (without it, the vault is only checked).
class ResealTarget {
  const ResealTarget(this.vaultPath, [this.credential]);

  final String vaultPath;
  final DerivedKeyCredential? credential;
}

/// Outcome of sealing one vault to a new recovery key.
class ResealOutcome {
  const ResealOutcome({required this.vaultPath, this.result, this.error});

  final String vaultPath;
  final ResealResult? result;
  final EngineException? error;

  /// Whether the vault now opens with the new recovery key.
  bool get isCurrent =>
      result == ResealResult.alreadyCurrent || result == ResealResult.updated;
}

/// Runs engine operations in background isolates, so the UI never freezes.
///
/// Keys are moved between isolates as [TransferrableSecureKey]s; the
/// caller keeps ownership of the keys it passes in.
class EngineRunner {
  EngineRunner(this._crypto);

  final CryptoService _crypto;

  /// Argon2id on a background isolate.
  Future<DerivedKey> deriveKey(String password, KdfParams kdf) async {
    final job = _start(_DeriveSpec(password, kdf));
    return _materialize(await job.result)!;
  }

  EngineJob<LockResult> lock(LockRequest request, VaultSlotsSpec slots) =>
      _start(
        _LockSpec(
          request,
          _toTransfer(slots.master),
          _toTransfer(slots.custom),
          slots.recoveryPublicKey,
        ),
      );

  EngineJob<UnlockResult> unlock(
    UnlockRequest request,
    VaultCredential credential,
  ) {
    final job = _start(_UnlockSpec(request, _credentialToTransfer(credential)));
    return EngineJob._(
      job.progress,
      job.result.then(
        (r) => r.result.withDerivedKey(_materialize(r.derivedKey)),
      ),
      job.cancel,
    );
  }

  /// Opens the data key of the drive vault at [vaultPath]. The caller owns
  /// the returned keys (the data key, and the derived key when a typed
  /// password opened it).
  Future<UnlockedKey> openDriveKey(
    String vaultPath,
    VaultCredential credential,
  ) async {
    final opened = await _start(
      _OpenDriveKeySpec(vaultPath, _credentialToTransfer(credential)),
    ).result;
    return UnlockedKey(
      dataKey: _crypto.fromTransferrable(opened.dataKey),
      openedWith: opened.openedWith,
      derivedKey: _materialize(opened.derivedKey),
    );
  }

  /// Rewrites the master slot of every vault in [vaultPaths].
  Future<List<RekeyOutcome>> rekey({
    required List<String> vaultPaths,
    required VaultCredential credential,
    required DerivedKey newMaster,
    Uint8List? recoveryPublicKey,
  }) => _start(
    _RekeySpec(
      vaultPaths,
      _credentialToTransfer(credential),
      _toTransfer(newMaster)!,
      recoveryPublicKey,
    ),
  ).result;

  /// Seals every vault in [targets] to [recoveryPublicKey].
  Future<List<ResealOutcome>> resealRecovery({
    required List<ResealTarget> targets,
    required Uint8List recoveryPublicKey,
  }) => _start(
    _ResealSpec([
      for (final target in targets)
        (
          target.vaultPath,
          target.credential == null
              ? null
              : _credentialToTransfer(target.credential!),
        ),
    ], recoveryPublicKey),
  ).result;

  // ---------------------------------------------------------------------

  _TransferKey? _toTransfer(DerivedKey? key) => key == null
      ? null
      : _TransferKey(_crypto.toTransferrable(key.key), key.kdf);

  DerivedKey? _materialize(_TransferKey? key) => key == null
      ? null
      : DerivedKey(key: _crypto.fromTransferrable(key.key), kdf: key.kdf);

  _TransferCredential _credentialToTransfer(VaultCredential credential) =>
      switch (credential) {
        PasswordCredential() ||
        RecoveryCredential() => _TransferCredential(credential),
        DerivedKeyCredential(:final key, :final slotType) =>
          _TransferCredential(null, key: _toTransfer(key), slotType: slotType),
      };

  EngineJob<T> _start<T>(_JobSpec<T> spec) {
    final progress = StreamController<OperationProgress>.broadcast();
    final completer = Completer<T>();
    final port = ReceivePort();
    final cancelFlag = calloc<Uint8>();
    var finished = false;

    void finish() {
      if (finished) return;
      finished = true;
      port.close();
      calloc.free(cancelFlag);
      unawaited(progress.close());
    }

    port.listen((message) {
      if (finished) return;
      switch (message) {
        case OperationProgress():
          progress.add(message);
        case _JobDone(:final value):
          completer.complete(value as T);
          finish();
        case _JobFailed(:final error):
          completer.completeError(error);
          finish();
        case null || List<Object?>():
          // Isolate exited or crashed without reporting a result.
          completer.completeError(
            const EngineException(
              EngineErrorCode.ioError,
              'The background task stopped unexpectedly',
            ),
          );
          finish();
      }
    });

    unawaited(
      Isolate.spawn(
        _workerMain,
        _JobMessage(port.sendPort, cancelFlag.address, spec),
        onError: port.sendPort,
        onExit: port.sendPort,
      ).catchError((Object error) {
        port.sendPort.send(<Object?>[error.toString(), null]);
        return Isolate.current;
      }),
    );

    return EngineJob._(progress.stream, completer.future, () {
      if (!finished) cancelFlag.value = 1;
    });
  }
}

// --- Messages -----------------------------------------------------------

class _JobMessage {
  const _JobMessage(this.reply, this.cancelFlagAddress, this.spec);

  final SendPort reply;
  final int cancelFlagAddress;
  final _JobSpec<Object?> spec;
}

class _JobDone {
  const _JobDone(this.value);

  final Object? value;
}

class _JobFailed {
  const _JobFailed(this.error);

  final EngineException error;
}

class _TransferKey {
  const _TransferKey(this.key, this.kdf);

  final TransferrableSecureKey key;
  final KdfParams kdf;
}

class _TransferCredential {
  const _TransferCredential(this.plain, {this.key, this.slotType});

  /// Password and recovery credentials hold no native memory.
  final VaultCredential? plain;
  final _TransferKey? key;
  final KeySlotType? slotType;
}

class _OpenedKeyTransfer {
  const _OpenedKeyTransfer(this.dataKey, this.openedWith, this.derivedKey);

  final TransferrableSecureKey dataKey;
  final KeySlotType openedWith;
  final _TransferKey? derivedKey;
}

class _UnlockTransferResult {
  const _UnlockTransferResult(this.result, this.derivedKey);

  final UnlockResult result;
  final _TransferKey? derivedKey;
}

// --- Worker side ----------------------------------------------------------

Future<void> _workerMain(_JobMessage message) async {
  final reply = message.reply;
  try {
    final crypto = await CryptoService.create();
    final flag = Pointer<Uint8>.fromAddress(message.cancelFlagAddress);
    final cancel = CancellationToken(() => flag.value != 0);
    final progress = ProgressReporter(reply.send);
    final value = message.spec.run(_WorkerContext(crypto, progress, cancel));
    reply.send(_JobDone(value));
  } on EngineException catch (error) {
    reply.send(_JobFailed(error));
  } on Object catch (error) {
    reply.send(
      _JobFailed(EngineException(EngineErrorCode.ioError, error.toString())),
    );
  }
}

class _WorkerContext {
  _WorkerContext(this.crypto, this.progress, this.cancel);

  final CryptoService crypto;
  final ProgressReporter progress;
  final CancellationToken cancel;

  DerivedKey? materialize(_TransferKey? key) => key == null
      ? null
      : DerivedKey(key: crypto.fromTransferrable(key.key), kdf: key.kdf);

  _TransferKey? transfer(DerivedKey? key) => key == null
      ? null
      : _TransferKey(crypto.toTransferrable(key.key), key.kdf);

  VaultCredential credential(_TransferCredential transfer) =>
      transfer.plain ??
      DerivedKeyCredential(materialize(transfer.key)!, transfer.slotType!);
}

sealed class _JobSpec<T> {
  const _JobSpec();

  T run(_WorkerContext context);
}

final class _DeriveSpec extends _JobSpec<_TransferKey?> {
  const _DeriveSpec(this.password, this.kdf);

  final String password;
  final KdfParams kdf;

  @override
  _TransferKey? run(_WorkerContext context) {
    final key = context.crypto.deriveKey(password, kdf);
    try {
      return _TransferKey(context.crypto.toTransferrable(key), kdf);
    } finally {
      key.dispose();
    }
  }
}

final class _LockSpec extends _JobSpec<LockResult> {
  const _LockSpec(this.request, this.master, this.custom, this.recovery);

  final LockRequest request;
  final _TransferKey? master;
  final _TransferKey? custom;
  final Uint8List? recovery;

  @override
  LockResult run(_WorkerContext context) {
    final masterKey = context.materialize(master);
    final customKey = context.materialize(custom);
    try {
      return LockOperation(
        crypto: context.crypto,
        progress: context.progress,
        cancel: context.cancel,
      ).run(
        request,
        VaultSlotsSpec(
          master: masterKey,
          custom: customKey,
          recoveryPublicKey: recovery,
        ),
      );
    } finally {
      masterKey?.dispose();
      customKey?.dispose();
    }
  }
}

final class _UnlockSpec extends _JobSpec<_UnlockTransferResult> {
  const _UnlockSpec(this.request, this.credential);

  final UnlockRequest request;
  final _TransferCredential credential;

  @override
  _UnlockTransferResult run(_WorkerContext context) {
    final credential = context.credential(this.credential);
    try {
      final result = UnlockOperation(
        crypto: context.crypto,
        progress: context.progress,
        cancel: context.cancel,
      ).run(request, credential);
      // Transferring copies the key; the worker's own copy is wiped here.
      final transferred = context.transfer(result.derivedKey);
      result.derivedKey?.dispose();
      return _UnlockTransferResult(result.withDerivedKey(null), transferred);
    } finally {
      if (credential is DerivedKeyCredential) credential.key.dispose();
    }
  }
}

final class _OpenDriveKeySpec extends _JobSpec<_OpenedKeyTransfer> {
  const _OpenDriveKeySpec(this.vaultPath, this.credential);

  final String vaultPath;
  final _TransferCredential credential;

  @override
  _OpenedKeyTransfer run(_WorkerContext context) {
    final credential = context.credential(this.credential);
    try {
      final unlocked = DriveVault.openKey(
        crypto: context.crypto,
        path: vaultPath,
        credential: credential,
      );
      // Transferring copies the keys; the worker's own copies are wiped.
      try {
        return _OpenedKeyTransfer(
          context.crypto.toTransferrable(unlocked.dataKey),
          unlocked.openedWith,
          context.transfer(unlocked.derivedKey),
        );
      } finally {
        unlocked.dataKey.dispose();
        unlocked.derivedKey?.dispose();
      }
    } finally {
      if (credential is DerivedKeyCredential) credential.key.dispose();
    }
  }
}

final class _RekeySpec extends _JobSpec<List<RekeyOutcome>> {
  const _RekeySpec(
    this.vaultPaths,
    this.credential,
    this.newMaster,
    this.recoveryPublicKey,
  );

  final List<String> vaultPaths;
  final _TransferCredential credential;
  final _TransferKey newMaster;
  final Uint8List? recoveryPublicKey;

  @override
  List<RekeyOutcome> run(_WorkerContext context) {
    final credential = context.credential(this.credential);
    final newMasterKey = context.materialize(newMaster)!;
    final operation = RekeyOperation(context.crypto);
    try {
      return [
        for (final path in vaultPaths)
          _rekeyOne(operation, path, credential, newMasterKey),
      ];
    } finally {
      newMasterKey.dispose();
      if (credential is DerivedKeyCredential) credential.key.dispose();
    }
  }

  RekeyOutcome _rekeyOne(
    RekeyOperation operation,
    String path,
    VaultCredential credential,
    DerivedKey newMaster,
  ) {
    try {
      operation.run(
        vaultPath: path,
        credential: credential,
        newMaster: newMaster,
        recoveryPublicKey: recoveryPublicKey,
      );
      return RekeyOutcome(vaultPath: path);
    } on EngineException catch (error) {
      return RekeyOutcome(vaultPath: path, error: error);
    } on Object catch (error) {
      return RekeyOutcome(
        vaultPath: path,
        error: EngineException(EngineErrorCode.ioError, error.toString()),
      );
    }
  }
}

final class _ResealSpec extends _JobSpec<List<ResealOutcome>> {
  const _ResealSpec(this.targets, this.recoveryPublicKey);

  final List<(String, _TransferCredential?)> targets;
  final Uint8List recoveryPublicKey;

  @override
  List<ResealOutcome> run(_WorkerContext context) {
    final operation = ResealOperation(context.crypto);
    return [
      for (final (path, credential) in targets)
        _resealOne(operation, context, path, credential),
    ];
  }

  ResealOutcome _resealOne(
    ResealOperation operation,
    _WorkerContext context,
    String path,
    _TransferCredential? transfer,
  ) {
    final credential = transfer == null ? null : context.credential(transfer);
    try {
      return ResealOutcome(
        vaultPath: path,
        result: operation.run(
          vaultPath: path,
          recoveryPublicKey: recoveryPublicKey,
          credential: credential,
        ),
      );
    } on EngineException catch (error) {
      return ResealOutcome(vaultPath: path, error: error);
    } on Object catch (error) {
      return ResealOutcome(
        vaultPath: path,
        error: EngineException(EngineErrorCode.ioError, error.toString()),
      );
    } finally {
      if (credential is DerivedKeyCredential) credential.key.dispose();
    }
  }
}
