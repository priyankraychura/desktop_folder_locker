import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../crypto/crypto_service.dart';
import '../engine_exception.dart';
import '../operations/journal.dart';
import '../operations/operation_progress.dart';
import '../vault/drive_vault.dart';
import '../vault/fs_utils.dart';
import '../vault/source_scanner.dart';
import '../vault/vault_keys.dart';
import 'drive_service.dart';

/// Result of turning a folder into a drive vault.
class DriveLockResult {
  const DriveLockResult({
    required this.vaultPath,
    required this.stats,
    required this.cleanupFailures,
  });

  final String vaultPath;
  final DriveStats stats;

  /// Original files that could not be deleted (the vault is complete).
  final List<String> cleanupFailures;
}

/// Result of turning a drive vault back into a folder.
class DriveExportResult {
  const DriveExportResult({required this.folderPath, required this.stats});

  /// Where the folder was restored (`Name (2)` if the name was taken).
  final String folderPath;
  final DriveStats stats;
}

/// Turns folders into drive vaults and back, crash-safely, with the same
/// journal as `.flk` vaults (so startup recovery finishes or rolls back an
/// interrupted operation the same way):
///
/// Lock: scan → rename the folder to a temporary name → create the vault
/// folder with its header → the helper encrypts and then compares every
/// file → move the vault into place → delete the original.
///
/// Export: the helper decrypts into a temporary folder and compares it
/// with the vault → move the folder into place → delete the vault.
class DriveOperations {
  DriveOperations({required this.crypto, required this.drives});

  final CryptoService crypto;
  final DriveService drives;

  Future<DriveLockResult> lock({
    required String operationId,
    required String folderPath,
    required String vaultPath,
    required String journalDir,
    required VaultSlotsSpec slots,
    String? tag,
    void Function(OperationProgress progress)? onProgress,
    DriveCancelToken? cancel,
  }) async {
    folderPath = p.normalize(folderPath);
    vaultPath = p.normalize(vaultPath);
    if (FsUtils.exists(vaultPath)) {
      throw EngineException(
        EngineErrorCode.alreadyExists,
        'A vault with this name already exists',
        path: vaultPath,
      );
    }
    if (!FsUtils.isDirectory(folderPath)) {
      throw EngineException(
        EngineErrorCode.unsupportedContent,
        'Only folders can become drives',
        path: folderPath,
      );
    }
    onProgress?.call(const OperationProgress(phase: OperationPhase.preparing));
    // Refuses links and other content a vault can't hold, before any change.
    final totalBytes = await Isolate.run(
      () => SourceScanner.scan(folderPath).totalBytes,
    );
    FsUtils.checkFreeSpace(
      p.dirname(folderPath),
      totalBytes + totalBytes ~/ 50 + 4 * 1024 * 1024,
    );

    final shortId = operationId.substring(0, 8);
    final baseName = p.basename(folderPath);
    final dir = p.dirname(folderPath);
    final journal = Journal(journalDir);
    var entry = JournalEntry(
      id: operationId,
      kind: JournalKind.lock,
      phase: JournalPhase.started,
      itemPath: folderPath,
      workPath: p.join(dir, '$baseName.$shortId.flk-locking'),
      partialPath: p.join(dir, '$baseName.$shortId.flkd-partial'),
      vaultPath: vaultPath,
      tag: tag,
      startedAt: DateTime.now(),
    );
    final staged = entry.workPath;
    final partial = entry.partialPath!;

    journal.save(entry);
    try {
      // Fails fast if a file inside is open in another program.
      await Isolate.run(() => FsUtils.rename(folderPath, staged));
    } on Object {
      journal.remove(entry.id);
      rethrow;
    }

    final DriveStats stats;
    try {
      final dataKey = DriveVault.create(
        crypto: crypto,
        path: partial,
        slots: slots,
      );
      try {
        stats = await drives.importFolder(
          vault: partial,
          key: dataKey,
          source: staged,
          onProgress: onProgress,
          cancel: cancel,
        );
      } finally {
        dataKey.dispose();
      }
      entry = entry.withPhase(JournalPhase.verified);
      journal.save(entry);
      onProgress?.call(
        const OperationProgress(phase: OperationPhase.finishing),
      );
      await Isolate.run(() => FsUtils.rename(partial, vaultPath));
    } on Object {
      await _rollbackLock(journal, entry);
      rethrow;
    }

    // The vault is in place: from here on, the lock is never rolled back.
    try {
      entry = entry.withPhase(JournalPhase.committed);
      journal.save(entry);
    } on Object {
      // Startup recovery completes a "verified" entry just the same.
    }
    final failures = await Isolate.run(() => FsUtils.deleteTree(staged));
    if (failures.isEmpty) journal.remove(entry.id);
    return DriveLockResult(
      vaultPath: vaultPath,
      stats: stats,
      cleanupFailures: failures,
    );
  }

  Future<void> _rollbackLock(Journal journal, JournalEntry entry) async {
    try {
      await Isolate.run(() {
        if (entry.partialPath case final partial?) FsUtils.deleteTree(partial);
        if (FsUtils.exists(entry.workPath) && !FsUtils.exists(entry.itemPath)) {
          FsUtils.rename(entry.workPath, entry.itemPath);
        }
      });
      if (!FsUtils.exists(entry.workPath)) journal.remove(entry.id);
    } on Object {
      // Keep the journal: startup recovery tries again.
    }
  }

  /// Decrypts the vault at [vaultPath] into a folder at [folderPath] (or
  /// the next free name) and deletes the vault. [dataKey] stays owned by
  /// the caller.
  Future<DriveExportResult> export({
    required String operationId,
    required String vaultPath,
    required String folderPath,
    required String journalDir,
    required SecureKey dataKey,
    String? tag,
    void Function(OperationProgress progress)? onProgress,
    DriveCancelToken? cancel,
  }) async {
    vaultPath = p.normalize(vaultPath);
    final target = FsUtils.freePath(p.normalize(folderPath));
    final shortId = operationId.substring(0, 8);
    final journal = Journal(journalDir);
    var entry = JournalEntry(
      id: operationId,
      kind: JournalKind.unlock,
      phase: JournalPhase.started,
      itemPath: target,
      workPath: p.join(
        p.dirname(vaultPath),
        '${p.basenameWithoutExtension(vaultPath)}.$shortId.flk-restoring',
      ),
      vaultPath: vaultPath,
      tag: tag,
      startedAt: DateTime.now(),
    );
    final work = entry.workPath;
    journal.save(entry);

    final DriveStats stats;
    try {
      stats = await drives.exportFolder(
        vault: vaultPath,
        key: dataKey,
        target: work,
        onProgress: onProgress,
        cancel: cancel,
      );
      onProgress?.call(
        const OperationProgress(phase: OperationPhase.finishing),
      );
      await Isolate.run(() => FsUtils.rename(work, target));
    } on Object {
      try {
        await Isolate.run(() => FsUtils.deleteTree(work));
        journal.remove(entry.id);
      } on Object {
        // Startup recovery deletes it.
      }
      rethrow;
    }

    try {
      entry = entry.withPhase(JournalPhase.committed);
      journal.save(entry);
    } on Object {
      // The folder is in place; recovery would only delete leftovers.
    }
    final failures = await Isolate.run(() => FsUtils.deleteTree(vaultPath));
    if (failures.isEmpty) journal.remove(entry.id);
    return DriveExportResult(folderPath: target, stats: stats);
  }
}
