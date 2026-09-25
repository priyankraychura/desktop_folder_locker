import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/di/core_providers.dart';
import '../../../engine/crypto/crypto_service.dart';
import '../../../engine/format/key_slot.dart';
import '../../../engine/format/vault_header.dart';
import '../../../engine/vault/vault_keys.dart';
import '../../../platform/key_protector.dart';

final relockKeysProvider = Provider<RelockKeys>(
  (ref) => RelockKeys(
    dir: ref.watch(appPathsProvider).relockDir,
    crypto: ref.watch(cryptoProvider),
    protector: ref.watch(keyProtectorProvider),
  ),
);

/// The keys of each unlocked item's next vault (see [PreparedVault]), made
/// when it was unlocked: it locks again without asking for a password,
/// even after the app locked or was closed, or Windows restarted.
///
/// Kept on the disk, one file per item, with the data key protected for
/// this Windows user (see [KeyProtector]). That key opens only the item's
/// next vault, whose files are unlocked on the disk meanwhile anyway. Each
/// is used for one vault, then deleted.
class RelockKeys {
  RelockKeys({
    required this.dir,
    required this._crypto,
    required this._protector,
  });

  final String dir;
  final CryptoService _crypto;
  final KeyProtector _protector;

  static const int _format = 1;

  String _file(String itemId) => p.join(dir, '$itemId.json');

  bool has(String itemId) => File(_file(itemId)).existsSync();

  /// Keeps [prepared] for [itemId], replacing what it had. The caller
  /// keeps [prepared]. Returns `false` if it couldn't be saved.
  bool save(String itemId, PreparedVault prepared) {
    final plain = prepared.dataKey.extractBytes();
    try {
      final protected = _protector.protect(plain);
      if (protected == null) return false;
      final file = File(_file(itemId));
      final temp = File('${file.path}.tmp');
      Directory(dir).createSync(recursive: true);
      temp.writeAsStringSync(
        jsonEncode({
          'format': _format,
          'header': base64Encode(prepared.header.encodeNew(_crypto)),
          'key': base64Encode(protected),
        }),
        flush: true,
      );
      temp.renameSync(file.path);
      return true;
    } on Object {
      return false;
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  /// The keys kept for [itemId], or `null`. The caller owns the result. A
  /// file that can't be read any more (damaged, or from another Windows
  /// user) is deleted.
  PreparedVault? read(String itemId) {
    final file = File(_file(itemId));
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      if (json['format'] != _format) throw const FormatException('format');
      final header = VaultHeader.parse(
        base64Decode(json['header']! as String),
        _crypto,
      );
      final plain = _protector.unprotect(base64Decode(json['key']! as String));
      if (plain == null || plain.length != CryptoService.keyLength) {
        throw const FormatException('key');
      }
      return PreparedVault(header: header, dataKey: _crypto.takeKey(plain));
    } on Object {
      remove(itemId);
      return null;
    }
  }

  void remove(String itemId) {
    try {
      File(_file(itemId)).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  }

  /// Items that have keys kept.
  List<String> get itemIds {
    try {
      return [
        for (final entry in Directory(dir).listSync())
          if (entry is File && entry.path.endsWith('.json'))
            p.basenameWithoutExtension(entry.path),
      ];
    } on FileSystemException {
      return const [];
    }
  }

  /// The master password or the recovery key changed: every kept vault
  /// gets a master slot for the new [master] key, and a recovery slot for
  /// the new [recoveryPublicKey] (each only if given).
  void update({DerivedKey? master, Uint8List? recoveryPublicKey}) {
    final keys = VaultKeys(_crypto);
    for (final itemId in itemIds) {
      final prepared = read(itemId);
      if (prepared == null) continue;
      try {
        final header = prepared.header;
        final slots = [
          for (final slot in header.slots)
            switch (slot) {
              PasswordKeySlot(isMaster: true) when master != null =>
                keys.passwordSlot(
                  type: KeySlotType.masterPassword,
                  key: master,
                  dataKey: prepared.dataKey,
                  prefix: header.prefix,
                ),
              RecoveryKeySlot() when recoveryPublicKey != null =>
                keys.recoverySlot(
                  publicKey: recoveryPublicKey,
                  vaultId: header.vaultId,
                  dataKey: prepared.dataKey,
                ),
              _ => slot,
            },
        ];
        save(
          itemId,
          PreparedVault(
            header: VaultHeader(
              vaultId: header.vaultId,
              chunkSize: header.chunkSize,
              slots: slots,
            ),
            dataKey: prepared.dataKey,
          ),
        );
      } finally {
        prepared.dispose();
      }
    }
  }
}
