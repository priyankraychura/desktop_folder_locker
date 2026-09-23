import 'dart:io';

import 'package:path/path.dart' as p;

import '../crypto/crypto_service.dart';
import '../engine_exception.dart';
import '../format/archive.dart';
import '../format/key_slot.dart';
import '../format/vault_header.dart';
import '../vault/fs_utils.dart';
import '../vault/vault_keys.dart';
import '../vault/vault_reader.dart';
import 'journal.dart';
import 'operation_progress.dart';

/// Everything needed to unlock one vault (plain data, can cross isolates).
class UnlockRequest {
  const UnlockRequest({
    required this.operationId,
    required this.vaultPath,
    required this.targetPath,
    required this.journalDir,
    this.tag,
  });

  final String operationId;
  final String vaultPath;

  /// Where the item should be restored. If something already exists there,
  /// a free name like `Name (2)` is used instead.
  final String targetPath;
  final String journalDir;
  final String? tag;
}

class UnlockResult {
  const UnlockResult({
    required this.restoredPath,
    required this.kind,
    required this.fileCount,
    required this.folderCount,
    required this.totalBytes,
    required this.openedWith,
    required this.vaultRemoved,
    this.derivedKey,
  });

  final String restoredPath;
  final ItemKind kind;
  final int fileCount;
  final int folderCount;
  final int totalBytes;
  final KeySlotType openedWith;

  /// `false` if the vault file could not be deleted after restoring (it is
  /// retried at the next start).
  final bool vaultRemoved;

  /// The key derived from a typed password (for locking again later).
  final DerivedKey? derivedKey;

  UnlockResult withDerivedKey(DerivedKey? key) => UnlockResult(
    restoredPath: restoredPath,
    kind: kind,
    fileCount: fileCount,
    folderCount: folderCount,
    totalBytes: totalBytes,
    openedWith: openedWith,
    vaultRemoved: vaultRemoved,
    derivedKey: key,
  );
}

/// Restores the item stored in a vault:
///
/// 1. check the password/key (nothing is written before this succeeds),
/// 2. decrypt everything into a temporary folder next to the vault,
/// 3. move the result to its final name,
/// 4. delete the vault.
class UnlockOperation {
  UnlockOperation({
    required this._crypto,
    required this._progress,
    required this._cancel,
  });

  final CryptoService _crypto;
  final ProgressReporter _progress;
  final CancellationToken _cancel;

  UnlockResult run(UnlockRequest request, VaultCredential credential) {
    final vaultPath = p.normalize(request.vaultPath);
    _progress.report(
      const OperationProgress(phase: OperationPhase.preparing),
      force: true,
    );
    final header = VaultHeader.read(vaultPath, _crypto);
    final unlocked = VaultKeys(_crypto).unlock(header, credential);

    final dir = p.dirname(vaultPath);
    final shortId = request.operationId.substring(0, 8);
    final journal = Journal(request.journalDir);
    var entry = JournalEntry(
      id: request.operationId,
      kind: JournalKind.unlock,
      phase: JournalPhase.started,
      itemPath: p.normalize(request.targetPath),
      workPath: p.join(
        dir,
        '${p.basenameWithoutExtension(vaultPath)}.$shortId.flk-restoring',
      ),
      vaultPath: vaultPath,
      tag: request.tag,
      startedAt: DateTime.now(),
    );
    final workDir = entry.workPath;

    final VaultContents contents;
    final String target;
    try {
      final vaultSize = FsUtils.guard(
        () => File(vaultPath).lengthSync(),
        path: vaultPath,
      );
      FsUtils.checkFreeSpace(dir, vaultSize + 4 * 1024 * 1024);

      journal.save(entry);
      FsUtils.guard(() => Directory(workDir).createSync(), path: workDir);

      contents = VaultReader(_crypto).read(
        vaultPath: vaultPath,
        header: header,
        dataKey: unlocked.dataKey,
        progress: _progress,
        cancel: _cancel,
        outputDir: workDir,
      );
      _cancel.throwIfCancelled();

      _progress.report(
        const OperationProgress(phase: OperationPhase.finishing),
        force: true,
      );
      final kind = contents.metadata.kind;
      final source = kind == ItemKind.folder ? workDir : _singleFile(workDir);
      target = FsUtils.freePath(
        entry.itemPath,
        keepExtension: kind == ItemKind.file,
      );
      FsUtils.rename(source, target);
    } on Object {
      if (FsUtils.deleteTree(workDir).isEmpty) journal.remove(entry.id);
      unlocked.derivedKey?.dispose();
      rethrow;
    } finally {
      unlocked.dataKey.dispose();
    }

    // The item is restored: from here on nothing is rolled back.
    entry = JournalEntry(
      id: entry.id,
      kind: entry.kind,
      phase: JournalPhase.committed,
      itemPath: target,
      workPath: workDir,
      vaultPath: vaultPath,
      tag: entry.tag,
      startedAt: entry.startedAt,
    );
    try {
      journal.save(entry);
    } on Object {
      // Recovery can't finish this without the journal; the stale vault
      // would simply open again later.
    }
    final leftovers = [
      ...FsUtils.deleteTree(workDir),
      ...FsUtils.deleteTree(vaultPath),
    ];
    if (leftovers.isEmpty) journal.remove(entry.id);

    return UnlockResult(
      restoredPath: target,
      kind: contents.metadata.kind,
      fileCount: contents.fileCount,
      folderCount: contents.folderCount,
      totalBytes: contents.totalBytes,
      openedWith: unlocked.openedWith,
      vaultRemoved: !FsUtils.exists(vaultPath),
      derivedKey: unlocked.derivedKey,
    );
  }

  static String _singleFile(String dir) {
    final files = Directory(dir).listSync(followLinks: false);
    if (files.length != 1 || files.single is! File) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'The vault should contain exactly one file',
      );
    }
    return files.single.path;
  }
}
