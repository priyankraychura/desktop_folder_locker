import 'dart:io';
import 'dart:typed_data';

import '../crypto/crypto_service.dart';
import '../engine_exception.dart';
import '../format/archive.dart';
import '../format/payload_cipher.dart';
import '../format/vault_header.dart';
import '../operations/operation_progress.dart';
import 'fs_utils.dart';
import 'source_scanner.dart';
import 'vault_keys.dart';

/// A freshly written vault. The caller owns [dataKey] (used to verify the
/// vault right away) and must dispose it.
class WrittenVault {
  WrittenVault({
    required this.header,
    required this.dataKey,
    required this.fileCount,
    required this.folderCount,
    required this.totalBytes,
  });

  final VaultHeader header;
  final SecureKey dataKey;
  final int fileCount;
  final int folderCount;
  final int totalBytes;

  void dispose() => dataKey.dispose();
}

/// Derives the key that encrypts the payload from the vault's data key.
SecureKey payloadKeyFor(
  CryptoService crypto,
  SecureKey dataKey,
  Uint8List vaultId,
) => crypto.deriveSubkey(
  master: dataKey,
  salt: vaultId,
  context: 'folder-locker/payload/v1',
);

/// Writes the contents of a scanned item into a new vault file.
class VaultWriter {
  VaultWriter(this._crypto);

  final CryptoService _crypto;

  static const int _readBufferSize = 1024 * 1024;

  WrittenVault write({
    required SourceSnapshot source,
    required String sourceRoot,
    required String outputPath,
    required VaultSlotsSpec slots,
    required ProgressReporter progress,
    required CancellationToken cancel,
    int chunkSize = VaultHeader.defaultChunkSize,
  }) {
    final vaultId = _crypto.randomBytes(VaultHeader.vaultIdLength);
    final dataKey = _crypto.randomKey();
    final prefix = VaultHeader.buildPrefix(
      vaultId: vaultId,
      chunkSize: chunkSize,
    );
    final header = VaultHeader(
      vaultId: vaultId,
      chunkSize: chunkSize,
      slots: VaultKeys(_crypto).buildSlots(
        prefix: prefix,
        vaultId: vaultId,
        dataKey: dataKey,
        spec: slots,
      ),
    );

    final payloadKey = payloadKeyFor(_crypto, dataKey, vaultId);
    final RandomAccessFile out;
    try {
      out = FsUtils.guard(
        () => File(outputPath).openSync(mode: FileMode.writeOnly),
        path: outputPath,
      );
    } on Object {
      payloadKey.dispose();
      dataKey.dispose();
      rethrow;
    }

    try {
      FsUtils.guard(() => out.writeFromSync(header.encodeNew(_crypto)));
      final encryptor = PayloadEncryptor(
        crypto: _crypto,
        key: payloadKey,
        aad: prefix,
        chunkSize: chunkSize,
        output: out,
      );
      final archive = ArchiveWriter(encryptor)
        ..start(
          ArchiveMetadata(
            kind: source.kind,
            name: source.name,
            createdAt: DateTime.now(),
            fileCount: source.fileCount,
            folderCount: source.folderCount,
            totalBytes: source.totalBytes,
          ),
        );

      FsUtils.guard(
        () => _writeEntries(source, sourceRoot, archive, progress, cancel),
      );
      archive.finish();
      FsUtils.guard(() {
        encryptor.close();
        out.flushSync();
      }, path: outputPath);

      return WrittenVault(
        header: header,
        dataKey: dataKey,
        fileCount: archive.fileCount,
        folderCount: archive.folderCount,
        totalBytes: archive.totalBytes,
      );
    } on Object {
      dataKey.dispose();
      rethrow;
    } finally {
      payloadKey.dispose();
      out.closeSync();
    }
  }

  void _writeEntries(
    SourceSnapshot source,
    String sourceRoot,
    ArchiveWriter archive,
    ProgressReporter progress,
    CancellationToken cancel,
  ) {
    final buffer = Uint8List(_readBufferSize);
    var doneBytes = 0;
    var doneFiles = 0;

    void report(String? current, {bool force = false}) => progress.report(
      OperationProgress(
        phase: OperationPhase.encrypting,
        processedBytes: doneBytes,
        totalBytes: source.totalBytes,
        processedFiles: doneFiles,
        totalFiles: source.fileCount,
        currentItem: current,
      ),
      force: force,
    );

    report(null, force: true);
    for (final entry in source.entries) {
      cancel.throwIfCancelled();
      if (entry.isFolder) {
        archive.addFolder(
          entry.relativePath,
          modified: entry.modified,
          attributes: entry.attributes,
        );
        continue;
      }

      final path = source.resolve(sourceRoot, entry);
      final input = File(path).openSync();
      try {
        // Use the size at open time: the item was renamed before locking,
        // so no program can still be writing to it.
        final size = input.lengthSync();
        archive.beginFile(
          entry.relativePath,
          size: size,
          modified: entry.modified,
          attributes: entry.attributes,
        );
        var remaining = size;
        while (remaining > 0) {
          cancel.throwIfCancelled();
          final read = input.readIntoSync(
            buffer,
            0,
            remaining < buffer.length ? remaining : buffer.length,
          );
          if (read <= 0) {
            throw EngineException(
              EngineErrorCode.ioError,
              'File became shorter while reading',
              path: path,
            );
          }
          archive.addFileData(Uint8List.sublistView(buffer, 0, read));
          remaining -= read;
          doneBytes += read;
          report(entry.relativePath);
        }
        archive.endFile();
      } finally {
        input.closeSync();
      }
      doneFiles++;
      report(entry.relativePath);
    }
    report(null, force: true);
  }
}
