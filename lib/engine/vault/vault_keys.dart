import 'dart:typed_data';

import '../crypto/crypto_service.dart';
import '../crypto/kdf_params.dart';
import '../crypto/recovery_key.dart';
import '../engine_exception.dart';
import '../format/key_slot.dart';
import '../format/vault_header.dart';

/// A key derived from a password, together with the settings used, so the
/// same key can be used again for another vault (for example when locking
/// an item again without asking for the password).
class DerivedKey {
  DerivedKey({required this.key, required this.kdf});

  final SecureKey key;
  final KdfParams kdf;

  void dispose() => key.dispose();
}

/// Which key slots a new vault gets.
class VaultSlotsSpec {
  const VaultSlotsSpec({this.master, this.custom, this.recoveryPublicKey})
    : assert(
        master != null || custom != null,
        'A vault needs at least one password slot',
      );

  final DerivedKey? master;
  final DerivedKey? custom;
  final Uint8List? recoveryPublicKey;
}

/// What the user (or the app session) offers to open a vault.
sealed class VaultCredential {
  const VaultCredential();
}

/// A password typed by the user. Tried against every password slot.
final class PasswordCredential extends VaultCredential {
  const PasswordCredential(this.password);

  final String password;
}

/// A key the app already derived (master key of the unlocked session, or a
/// remembered item key). Only slots with the same salt can match.
final class DerivedKeyCredential extends VaultCredential {
  const DerivedKeyCredential(this.key, this.slotType);

  final DerivedKey key;
  final KeySlotType slotType;
}

/// The recovery key typed by the user.
final class RecoveryCredential extends VaultCredential {
  const RecoveryCredential(this.recoveryKey);

  final RecoveryKey recoveryKey;
}

/// The result of opening a vault's data key.
class UnlockedKey {
  UnlockedKey({
    required this.dataKey,
    required this.openedWith,
    this.derivedKey,
  });

  final SecureKey dataKey;
  final KeySlotType openedWith;

  /// Set when a typed password was used; the caller may keep it to lock the
  /// item again later, and must dispose it.
  final DerivedKey? derivedKey;
}

/// Creates and opens key slots.
class VaultKeys {
  VaultKeys(this._crypto);

  final CryptoService _crypto;

  List<KeySlot> buildSlots({
    required Uint8List prefix,
    required Uint8List vaultId,
    required SecureKey dataKey,
    required VaultSlotsSpec spec,
  }) => [
    if (spec.master case final master?)
      passwordSlot(
        type: KeySlotType.masterPassword,
        key: master,
        dataKey: dataKey,
        prefix: prefix,
      ),
    if (spec.custom case final custom?)
      passwordSlot(
        type: KeySlotType.customPassword,
        key: custom,
        dataKey: dataKey,
        prefix: prefix,
      ),
    if (spec.recoveryPublicKey case final publicKey?)
      recoverySlot(publicKey: publicKey, vaultId: vaultId, dataKey: dataKey),
  ];

  PasswordKeySlot passwordSlot({
    required KeySlotType type,
    required DerivedKey key,
    required SecureKey dataKey,
    required Uint8List prefix,
  }) {
    final nonce = _crypto.randomBytes(_crypto.nonceLength);
    return PasswordKeySlot(
      type: type,
      kdf: key.kdf,
      nonce: nonce,
      wrappedKey: _crypto.wrapKey(
        key: dataKey,
        wrappingKey: key.key,
        nonce: nonce,
        aad: _slotAad(prefix, type),
      ),
    );
  }

  RecoveryKeySlot recoverySlot({
    required Uint8List publicKey,
    required Uint8List vaultId,
    required SecureKey dataKey,
  }) {
    final message = dataKey.runUnlockedSync(
      (key) => Uint8List.fromList([...vaultId, ...key]),
    );
    try {
      return RecoveryKeySlot(
        fingerprint: RecoveryKey.fingerprint(_crypto, publicKey),
        sealedKey: _crypto.sealTo(message, publicKey),
      );
    } finally {
      message.fillRange(0, message.length, 0);
    }
  }

  /// Opens the data key of [header]. Throws [EngineErrorCode.wrongPassword]
  /// if [credential] matches no slot.
  UnlockedKey unlock(VaultHeader header, VaultCredential credential) {
    final result = switch (credential) {
      PasswordCredential(:final password) => _unlockWithPassword(
        header,
        password,
      ),
      DerivedKeyCredential(:final key, :final slotType) => _unlockWithKey(
        header,
        key,
        slotType,
      ),
      RecoveryCredential(:final recoveryKey) => _unlockWithRecovery(
        header,
        recoveryKey,
      ),
    };
    if (result == null) {
      throw const EngineException(
        EngineErrorCode.wrongPassword,
        'The password or recovery key does not match',
      );
    }
    return result;
  }

  UnlockedKey? _unlockWithPassword(VaultHeader header, String password) {
    for (final slot in header.slots.whereType<PasswordKeySlot>()) {
      final derived = DerivedKey(
        key: _crypto.deriveKey(password, slot.kdf),
        kdf: slot.kdf,
      );
      final dataKey = _openPasswordSlot(header, slot, derived.key);
      if (dataKey != null) {
        return UnlockedKey(
          dataKey: dataKey,
          openedWith: slot.type,
          derivedKey: derived,
        );
      }
      derived.dispose();
    }
    return null;
  }

  UnlockedKey? _unlockWithKey(
    VaultHeader header,
    DerivedKey key,
    KeySlotType slotType,
  ) {
    for (final slot in header.slots.whereType<PasswordKeySlot>()) {
      if (slot.type != slotType ||
          !_crypto.equalBytes(slot.kdf.salt, key.kdf.salt)) {
        continue;
      }
      final dataKey = _openPasswordSlot(header, slot, key.key);
      if (dataKey != null) {
        return UnlockedKey(dataKey: dataKey, openedWith: slot.type);
      }
    }
    return null;
  }

  UnlockedKey? _unlockWithRecovery(VaultHeader header, RecoveryKey recovery) {
    final keyPair = recovery.keyPair(_crypto);
    try {
      final fingerprint = RecoveryKey.fingerprint(_crypto, keyPair.publicKey);
      final slots = header.slots.whereType<RecoveryKeySlot>().where(
        (slot) => _crypto.equalBytes(slot.fingerprint, fingerprint),
      );
      for (final slot in slots) {
        final opened = _crypto.openSealed(slot.sealedKey, keyPair);
        if (opened == null ||
            opened.length !=
                VaultHeader.vaultIdLength + CryptoService.keyLength) {
          continue;
        }
        final vaultId = Uint8List.sublistView(
          opened,
          0,
          VaultHeader.vaultIdLength,
        );
        if (!_crypto.equalBytes(vaultId, header.vaultId)) {
          opened.fillRange(0, opened.length, 0);
          continue;
        }
        final dataKey = _crypto.takeKey(
          Uint8List.fromList(opened.sublist(VaultHeader.vaultIdLength)),
        );
        opened.fillRange(0, opened.length, 0);
        return UnlockedKey(dataKey: dataKey, openedWith: KeySlotType.recovery);
      }
      return null;
    } finally {
      keyPair.dispose();
    }
  }

  SecureKey? _openPasswordSlot(
    VaultHeader header,
    PasswordKeySlot slot,
    SecureKey wrappingKey,
  ) => _crypto.unwrapKey(
    wrapped: slot.wrappedKey,
    wrappingKey: wrappingKey,
    nonce: slot.nonce,
    aad: _slotAad(header.prefix, slot.type),
  );

  static Uint8List _slotAad(Uint8List prefix, KeySlotType type) =>
      Uint8List.fromList([...prefix, type.id]);
}
