import 'package:path/path.dart' as p;

import '../crypto/crypto_service.dart';
import '../engine_exception.dart';
import '../format/archive.dart';
import '../vault/fs_utils.dart';
import '../vault/source_scanner.dart';
import '../vault/vault_keys.dart';
import '../vault/vault_reader.dart';
import '../vault/vault_writer.dart';
import 'journal.dart';
import 'operation_progress.dart';

/// Everything needed to lock one item (plain data, can cross isolates).
class LockRequest {
  const LockRequest({
    required this.operationId,
    required this.itemPath,
    required this.vaultPath,
    required this.journalDir,
    this.tag,
  });

  final String operationId;

  /// The file or folder to lock.
  final String itemPath;

  /// Where the vault goes. Must not exist yet.
  final String vaultPath;
  final String journalDir;

  /// Stored in the journal for the caller (item id).
  final String? tag;
}

class LockResult {
  const LockResult({
    required this.vaultPath,
    required this.kind,
    required this.fileCount,
    required this.folderCount,
    required this.totalBytes,
    required this.cleanupFailures,
  });

  final String vaultPath;
  final ItemKind kind;
  final int fileCount;
  final int folderCount;
  final int totalBytes;

  /// Original files that could not be deleted after locking (the vault is
  /// complete; these can be removed manually).
  final List<String> cleanupFailures;
}

/// Turns a file or folder into a vault, safely:
///
/// 1. scan the item (nothing changed yet; unsupported content is refused),
/// 2. rename it to a temporary name (fails fast if a file is open),
/// 3. write the vault to a `.flk-partial` file,
/// 4. decrypt the whole vault again to verify it,
/// 5. move the vault into place,
/// 6. delete the original.
///
/// A journal entry is saved before each step, and any error rolls back to
/// the original item.
class LockOperation {
  LockOperation({
    required this._crypto,
    required this._progress,
    required this._cancel,
  });

  final CryptoService _crypto;
  final ProgressReporter _progress;
  final CancellationToken _cancel;

  LockResult run(LockRequest request, VaultSlotsSpec slots) {
    final itemPath = p.normalize(request.itemPath);
    final vaultPath = p.normalize(request.vaultPath);
    if (FsUtils.exists(vaultPath)) {
      throw EngineException(
        EngineErrorCode.alreadyExists,
        'A vault with this name already exists',
        path: vaultPath,
      );
    }

    _progress.report(
      const OperationProgress(phase: OperationPhase.preparing),
      force: true,
    );
    final snapshot = SourceScanner.scan(itemPath, cancel: _cancel);
    // The vault is a little larger than its contents, and both exist on
    // disk until the original is deleted.
    FsUtils.checkFreeSpace(
      p.dirname(itemPath),
      snapshot.totalBytes + snapshot.totalBytes ~/ 100 + 4 * 1024 * 1024,
    );

    final shortId = request.operationId.substring(0, 8);
    final baseName = p.basename(itemPath);
    final dir = p.dirname(itemPath);
    final journal = Journal(request.journalDir);
    var entry = JournalEntry(
      id: request.operationId,
      kind: JournalKind.lock,
      phase: JournalPhase.started,
      itemPath: itemPath,
      workPath: p.join(dir, '$baseName.$shortId.flk-locking'),
      partialPath: p.join(dir, '$baseName.$shortId.flk-partial'),
      vaultPath: vaultPath,
      tag: request.tag,
      startedAt: DateTime.now(),
    );
    final staged = entry.workPath;
    final partial = entry.partialPath!;

    journal.save(entry);
    try {
      FsUtils.rename(itemPath, staged);
    } on Object {
      journal.remove(entry.id);
      rethrow;
    }

    final WrittenVault written;
    try {
      written = VaultWriter(_crypto).write(
        source: snapshot,
        sourceRoot: staged,
        outputPath: partial,
        slots: slots,
        progress: _progress,
        cancel: _cancel,
      );
    } on Object {
      _rollback(journal, entry);
      rethrow;
    }

    try {
      final contents = VaultReader(_crypto).read(
        vaultPath: partial,
        header: written.header,
        dataKey: written.dataKey,
        progress: _progress,
        cancel: _cancel,
      );
      if (contents.fileCount != written.fileCount ||
          contents.folderCount != written.folderCount ||
          contents.totalBytes != written.totalBytes) {
        throw const EngineException(
          EngineErrorCode.corruptVault,
          'Verification failed: the vault does not match the original',
        );
      }
      entry = entry.withPhase(JournalPhase.verified);
      journal.save(entry);

      _progress.report(
        const OperationProgress(phase: OperationPhase.finishing),
        force: true,
      );
      FsUtils.rename(partial, vaultPath);
    } on Object {
      _rollback(journal, entry);
      rethrow;
    } finally {
      written.dispose();
    }

    // The vault is in place: from here on the lock is never rolled back.
    // (If this journal write fails, the "verified" entry is completed by
    // startup recovery just the same.)
    try {
      entry = entry.withPhase(JournalPhase.committed);
      journal.save(entry);
    } on Object {
      // See above.
    }

    final failures = FsUtils.deleteTree(staged);
    if (failures.isEmpty) {
      journal.remove(entry.id);
    }
    // If some files could not be deleted, the journal stays so the next
    // start retries the cleanup.

    return LockResult(
      vaultPath: vaultPath,
      kind: snapshot.kind,
      fileCount: written.fileCount,
      folderCount: written.folderCount,
      totalBytes: written.totalBytes,
      cleanupFailures: failures,
    );
  }

  /// Restores the original item after a failure before the vault was
  /// committed.
  void _rollback(Journal journal, JournalEntry entry) {
    try {
      final partial = entry.partialPath;
      if (partial != null) FsUtils.deleteTree(partial);
      if (FsUtils.exists(entry.workPath) && !FsUtils.exists(entry.itemPath)) {
        FsUtils.rename(entry.workPath, entry.itemPath);
      }
      if (!FsUtils.exists(entry.workPath)) journal.remove(entry.id);
    } on Object {
      // Keep the journal: startup recovery will try again.
    }
  }
}
