import 'dart:io';

import 'package:path/path.dart' as p;

import '../../platform/file_system_info.dart';
import '../crypto/crypto_service.dart';
import '../engine_exception.dart';
import '../format/archive.dart';
import '../format/payload_cipher.dart';
import '../format/vault_header.dart';
import '../operations/operation_progress.dart';
import 'fs_utils.dart';
import 'vault_writer.dart';

/// Summary of a vault that was read completely.
class VaultContents {
  const VaultContents({
    required this.metadata,
    required this.fileCount,
    required this.folderCount,
    required this.totalBytes,
  });

  final ArchiveMetadata metadata;
  final int fileCount;
  final int folderCount;
  final int totalBytes;
}

/// Decrypts vaults, either to disk or just to check them.
class VaultReader {
  VaultReader(this._crypto);

  final CryptoService _crypto;

  /// Reads the whole vault at [vaultPath].
  ///
  /// With an [outputDir], files and folders are recreated inside it (the
  /// directory must exist and be empty). Without one, everything is
  /// decrypted and checked but nothing is written ("verify").
  VaultContents read({
    required String vaultPath,
    required VaultHeader header,
    required SecureKey dataKey,
    required ProgressReporter progress,
    required CancellationToken cancel,
    String? outputDir,
  }) {
    final phase = outputDir == null
        ? OperationPhase.verifying
        : OperationPhase.decrypting;
    final input = FsUtils.guard(
      () => File(vaultPath).openSync(),
      path: vaultPath,
    );
    final payloadKey = payloadKeyFor(_crypto, dataKey, header.vaultId);
    try {
      final decryptor = PayloadDecryptor(
        crypto: _crypto,
        key: payloadKey,
        aad: header.prefix,
        chunkSize: header.chunkSize,
        input: input,
        start: VaultHeader.blockSize,
        end: FsUtils.guard(input.lengthSync, path: vaultPath),
      );
      final archive = ArchiveReader(decryptor);
      final metadata = archive.readStart();
      final extractor = _Extractor(
        outputDir: outputDir,
        metadata: metadata,
        progress: progress,
        phase: phase,
        cancel: cancel,
      );
      FsUtils.guard(() => extractor.run(archive), path: outputDir);
      return VaultContents(
        metadata: metadata,
        fileCount: extractor.files,
        folderCount: extractor.folders,
        totalBytes: extractor.bytes,
      );
    } finally {
      payloadKey.dispose();
      input.closeSync();
    }
  }
}

class _Extractor {
  _Extractor({
    required this.outputDir,
    required this.metadata,
    required this.progress,
    required this.phase,
    required this.cancel,
  });

  final String? outputDir;
  final ArchiveMetadata metadata;
  final ProgressReporter progress;
  final OperationPhase phase;
  final CancellationToken cancel;

  final Set<String> _seen = {};
  final List<(String, int)> _folderAttributes = [];
  int files = 0;
  int folders = 0;
  int bytes = 0;

  void _report(String? current, {bool force = false}) => progress.report(
    OperationProgress(
      phase: phase,
      processedBytes: bytes,
      totalBytes: metadata.totalBytes,
      processedFiles: files,
      totalFiles: metadata.fileCount,
      currentItem: current,
    ),
    force: force,
  );

  void run(ArchiveReader archive) {
    _report(null, force: true);
    while (true) {
      cancel.throwIfCancelled();
      final entry = archive.nextEntry();
      if (entry == null) break;
      _checkEntry(entry);
      switch (entry) {
        case FolderEntry():
          folders++;
          final target = _targetPath(entry.path);
          if (target != null) {
            Directory(target).createSync(recursive: true);
            if (entry.attributes != 0) {
              _folderAttributes.add((target, entry.attributes));
            }
          }
        case FileEntry():
          _extractFile(archive, entry);
      }
    }
    if (metadata.kind == ItemKind.file && files != 1) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'The vault should contain exactly one file',
      );
    }
    // Folder attributes last: a read-only folder can still receive files
    // on Windows, but this keeps the order predictable.
    for (final (path, attributes) in _folderAttributes) {
      FileSystemInfo.setAttributes(path, attributes);
    }
    _report(null, force: true);
  }

  void _checkEntry(ArchiveEntry entry) {
    if (!_seen.add(entry.path.toLowerCase())) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'The vault contains the same path twice',
      );
    }
    if (metadata.kind == ItemKind.file &&
        (entry is! FileEntry || entry.path.contains('/'))) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'Unexpected entry in a single-file vault',
      );
    }
  }

  void _extractFile(ArchiveReader archive, FileEntry entry) {
    final target = _targetPath(entry.path);
    RandomAccessFile? out;
    if (target != null) {
      Directory(p.dirname(target)).createSync(recursive: true);
      out = File(target).openSync(mode: FileMode.writeOnly);
    }
    try {
      archive.readFileData(entry.size, (data) {
        out?.writeFromSync(data);
        bytes += data.length;
        _report(entry.path);
        cancel.throwIfCancelled();
      });
    } finally {
      out?.closeSync();
    }
    if (target != null) {
      if (entry.modified case final modified?) {
        File(target).setLastModifiedSync(modified);
      }
      if (entry.attributes != 0) {
        FileSystemInfo.setAttributes(target, entry.attributes);
      }
    }
    files++;
    _report(entry.path);
  }

  /// Output path for [relativePath], or `null` when only verifying.
  String? _targetPath(String relativePath) {
    final root = outputDir;
    if (root == null) return null;
    final target = p.normalize(p.joinAll([root, ...relativePath.split('/')]));
    if (!p.isWithin(root, target)) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'The vault tries to write outside the target folder',
      );
    }
    return target;
  }
}
