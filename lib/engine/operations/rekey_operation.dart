import 'dart:typed_data';

import '../crypto/crypto_service.dart';
import '../format/key_slot.dart';
import '../format/vault_header.dart';
import '../vault/vault_keys.dart';

/// Replaces the master-password slot of an existing vault, for example
/// after the master password was changed or reset with the recovery key.
///
/// Only the small key-slot area is rewritten (crash-safely); the encrypted
/// contents are untouched.
class RekeyOperation {
  RekeyOperation(this._crypto);

  final CryptoService _crypto;

  void run({
    required String vaultPath,
    required VaultCredential credential,
    required DerivedKey newMaster,
    Uint8List? recoveryPublicKey,
  }) {
    final header = VaultHeader.read(vaultPath, _crypto);
    final keys = VaultKeys(_crypto);
    final unlocked = keys.unlock(header, credential);
    try {
      final others = header.slots
          .where((slot) => !(slot is PasswordKeySlot && slot.isMaster))
          .toList();
      final hasRecovery = others.any((slot) => slot is RecoveryKeySlot);
      final slots = <KeySlot>[
        keys.passwordSlot(
          type: KeySlotType.masterPassword,
          key: newMaster,
          dataKey: unlocked.dataKey,
          prefix: header.prefix,
        ),
        ...others,
        if (!hasRecovery && recoveryPublicKey != null)
          keys.recoverySlot(
            publicKey: recoveryPublicKey,
            vaultId: header.vaultId,
            dataKey: unlocked.dataKey,
          ),
      ];
      VaultHeader.rewriteSlots(
        path: vaultPath,
        current: header,
        slots: slots,
        crypto: _crypto,
      );
    } finally {
      unlocked.dataKey.dispose();
      unlocked.derivedKey?.dispose();
    }
  }
}
