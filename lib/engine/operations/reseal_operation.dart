import 'dart:typed_data';

import '../crypto/crypto_service.dart';
import '../crypto/recovery_key.dart';
import '../format/key_slot.dart';
import '../format/vault_header.dart';
import '../vault/vault_keys.dart';

/// What [ResealOperation] did with one vault.
enum ResealResult {
  /// The vault already opened with the new recovery key.
  alreadyCurrent,

  /// Its recovery slot was replaced.
  updated,

  /// It still uses another recovery key, and no key was given to open it.
  needsKey,
}

/// Seals a vault's data key to a new recovery key, replacing the old
/// recovery slot, after the user created a new recovery key.
///
/// Only the small key-slot area is rewritten (crash-safely); password
/// slots and the encrypted contents are untouched.
class ResealOperation {
  ResealOperation(this._crypto);

  final CryptoService _crypto;

  /// Without a [credential], only checks whether the vault is current.
  ResealResult run({
    required String vaultPath,
    required Uint8List recoveryPublicKey,
    VaultCredential? credential,
  }) {
    final header = VaultHeader.read(vaultPath, _crypto);
    final fingerprint = RecoveryKey.fingerprint(_crypto, recoveryPublicKey);
    final recoverySlots = header.slots.whereType<RecoveryKeySlot>().toList();
    if (recoverySlots.length == 1 &&
        _crypto.equalBytes(recoverySlots.single.fingerprint, fingerprint)) {
      return ResealResult.alreadyCurrent;
    }
    if (credential == null) return ResealResult.needsKey;

    final keys = VaultKeys(_crypto);
    final unlocked = keys.unlock(header, credential);
    try {
      VaultHeader.rewriteSlots(
        path: vaultPath,
        current: header,
        slots: [
          ...header.slots.where((slot) => slot is! RecoveryKeySlot),
          keys.recoverySlot(
            publicKey: recoveryPublicKey,
            vaultId: header.vaultId,
            dataKey: unlocked.dataKey,
          ),
        ],
        crypto: _crypto,
      );
      return ResealResult.updated;
    } finally {
      unlocked.dataKey.dispose();
      unlocked.derivedKey?.dispose();
    }
  }
}
