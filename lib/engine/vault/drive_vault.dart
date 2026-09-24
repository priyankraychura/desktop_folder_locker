import 'dart:io';

import 'package:path/path.dart' as p;

import '../crypto/crypto_service.dart';
import '../engine_exception.dart';
import '../format/vault_header.dart';
import 'fs_utils.dart';
import 'vault_keys.dart';

/// Drive vaults: a folder (`Name.flkd`) that holds the header with the key
/// slots (`vault.flk`) and the encrypted files (`data`).
///
/// This engine only writes and reads the header. The drive helper
/// (`cloak_drive.exe`) imports, mounts and exports the files, with
/// the data key the header protects. See `docs/DRIVE_VAULT.md`.
abstract final class DriveVault {
  /// Extension of drive vault folders (with the dot).
  static const String extension = '.flkd';

  static const String headerFileName = VaultHeader.driveHeaderFileName;
  static const String dataDirName = 'data';

  /// Whether [path] looks like a drive vault folder, or the header inside
  /// one.
  static bool isDrivePath(String path) =>
      p.extension(path).toLowerCase() == extension ||
      (p.basename(path).toLowerCase() == headerFileName &&
          p.extension(p.dirname(path)).toLowerCase() == extension);

  /// The vault folder for [path], which may be the header inside it.
  static String folderOf(String path) =>
      p.basename(path).toLowerCase() == headerFileName &&
          p.extension(p.dirname(path)).toLowerCase() == extension
      ? p.dirname(path)
      : path;

  /// Creates the vault folder at [path] with a new header and returns the
  /// new data key, which the caller disposes. The helper creates `data`
  /// when it imports the files.
  static SecureKey create({
    required CryptoService crypto,
    required String path,
    required VaultSlotsSpec slots,
  }) {
    if (FsUtils.exists(path)) {
      throw EngineException(
        EngineErrorCode.alreadyExists,
        'A vault with this name already exists',
        path: path,
      );
    }
    final vaultId = crypto.randomBytes(VaultHeader.vaultIdLength);
    final dataKey = crypto.randomKey();
    try {
      final prefix = VaultHeader.buildPrefix(
        vaultId: vaultId,
        chunkSize: VaultHeader.driveBlockSize,
        version: VaultHeader.driveVersion,
        flags: VaultHeader.flagDrive,
      );
      final header = VaultHeader(
        vaultId: vaultId,
        chunkSize: VaultHeader.driveBlockSize,
        version: VaultHeader.driveVersion,
        flags: VaultHeader.flagDrive,
        slots: VaultKeys(crypto).buildSlots(
          prefix: prefix,
          vaultId: vaultId,
          dataKey: dataKey,
          spec: slots,
        ),
      );
      FsUtils.guard(() {
        Directory(path).createSync();
        File(p.join(path, headerFileName))
            .writeAsBytesSync(header.encodeNew(crypto), flush: true);
      }, path: path);
      return dataKey;
    } on Object {
      dataKey.dispose();
      rethrow;
    }
  }

  /// Opens the data key of the drive vault at [path] with [credential].
  static UnlockedKey openKey({
    required CryptoService crypto,
    required String path,
    required VaultCredential credential,
  }) {
    final header = VaultHeader.read(path, crypto);
    if (!header.isDrive) {
      throw EngineException(
        EngineErrorCode.unsupportedContent,
        'This is not a drive vault',
        path: path,
      );
    }
    return VaultKeys(crypto).unlock(header, credential);
  }
}
