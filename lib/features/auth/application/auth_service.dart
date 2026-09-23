import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/core_providers.dart';
import '../../../engine/crypto/crypto_service.dart';
import '../../../engine/crypto/kdf_params.dart';
import '../../../engine/crypto/recovery_key.dart';
import '../../../engine/engine_runner.dart';
import '../../../engine/vault/vault_keys.dart';
import '../data/keystore_repository.dart';
import '../domain/keystore.dart';

final authServiceProvider = Provider<AuthService>(
  (ref) => AuthService(
    crypto: ref.watch(cryptoProvider),
    runner: ref.watch(engineRunnerProvider),
    repository: ref.watch(keystoreRepositoryProvider),
    kdfPolicy: ref.watch(kdfPolicyProvider),
  ),
);

/// Result of creating the master password.
class MasterSetup {
  const MasterSetup({
    required this.keystore,
    required this.masterKey,
    required this.recoveryKey,
  });

  final Keystore keystore;
  final DerivedKey masterKey;

  /// Shown to the user once; never stored.
  final String recoveryKey;
}

/// Result of changing or resetting the master password.
class PasswordChange {
  const PasswordChange({
    required this.keystore,
    required this.masterKey,
    required this.failedVaults,
  });

  final Keystore keystore;
  final DerivedKey masterKey;

  /// Vaults that could not be updated (for example on a removed drive).
  /// They still open with the old password or the recovery key.
  final List<RekeyOutcome> failedVaults;
}

/// A new recovery key that is not saved yet: the user must confirm they
/// wrote it down first.
class RecoveryKeyDraft {
  const RecoveryKeyDraft({required this.text, required this.publicKey});

  /// Shown to the user once; never stored.
  final String text;
  final Uint8List publicKey;
}

/// Master password logic: setup, verification, change and reset.
class AuthService {
  AuthService({
    required this._crypto,
    required this._runner,
    required this._repository,
    this._kdfPolicy = KdfPolicy.standard,
  });

  final CryptoService _crypto;
  final EngineRunner _runner;
  final KeystoreRepository _repository;
  final KdfPolicy _kdfPolicy;

  static final Uint8List _verifierPlain = utf8.encode(
    'folder-locker/verifier/v1',
  );

  Future<Keystore?> load() => _repository.load();

  Future<MasterSetup> setUp({required String password, String? hint}) async {
    final kdf = _kdfPolicy.withSalt(_crypto.randomBytes(KdfParams.saltLength));
    final masterKey = await _runner.deriveKey(password, kdf);
    final recovery = RecoveryKey.generate(_crypto);
    final pair = recovery.keyPair(_crypto);
    final publicKey = Uint8List.fromList(pair.publicKey);
    pair.dispose();

    final verifier = _makeVerifier(masterKey);
    final now = DateTime.now();
    final keystore = Keystore(
      kdf: kdf,
      verifierNonce: verifier.nonce,
      verifierCipherText: verifier.cipherText,
      recoveryPublicKey: publicKey,
      hint: _cleanHint(hint),
      createdAt: now,
      passwordChangedAt: now,
      recoveryCreatedAt: now,
    );
    await _repository.save(keystore);
    final text = recovery.format();
    recovery.dispose();
    return MasterSetup(
      keystore: keystore,
      masterKey: masterKey,
      recoveryKey: text,
    );
  }

  /// Returns the master key if [password] is correct, otherwise `null`.
  Future<DerivedKey?> unlock(Keystore keystore, String password) async {
    final key = await _runner.deriveKey(password, keystore.kdf);
    if (_checkVerifier(keystore, key)) return key;
    key.dispose();
    return null;
  }

  /// Whether [recoveryKey] belongs to this keystore.
  bool matchesRecoveryKey(Keystore keystore, RecoveryKey recoveryKey) {
    final pair = recoveryKey.keyPair(_crypto);
    try {
      return _crypto.equalBytes(pair.publicKey, keystore.recoveryPublicKey);
    } finally {
      pair.dispose();
    }
  }

  /// Sets a new master password and updates every vault in [vaultPaths].
  ///
  /// [credential] must open those vaults: the current master key, or the
  /// recovery key when the password was forgotten. The keystore is saved
  /// first, so the app always accepts the new password; vaults that could
  /// not be updated are reported in [PasswordChange.failedVaults].
  Future<PasswordChange> changePassword({
    required Keystore keystore,
    required VaultCredential credential,
    required String newPassword,
    required List<String> vaultPaths,
    String? hint,
  }) async {
    final kdf = _kdfPolicy.withSalt(_crypto.randomBytes(KdfParams.saltLength));
    final masterKey = await _runner.deriveKey(newPassword, kdf);
    final verifier = _makeVerifier(masterKey);
    final updated = keystore.copyWith(
      kdf: kdf,
      verifierNonce: verifier.nonce,
      verifierCipherText: verifier.cipherText,
      hint: _cleanHint(hint),
      clearHint: _cleanHint(hint) == null,
      passwordChangedAt: DateTime.now(),
    );
    await _repository.save(updated);

    final outcomes = vaultPaths.isEmpty
        ? const <RekeyOutcome>[]
        : await _runner.rekey(
            vaultPaths: vaultPaths,
            credential: credential,
            newMaster: masterKey,
            recoveryPublicKey: keystore.recoveryPublicKey,
          );
    return PasswordChange(
      keystore: updated,
      masterKey: masterKey,
      failedVaults: outcomes.where((o) => !o.success).toList(),
    );
  }

  /// Creates a new recovery key (not saved yet).
  RecoveryKeyDraft newRecoveryKey() {
    final recovery = RecoveryKey.generate(_crypto);
    final pair = recovery.keyPair(_crypto);
    final publicKey = Uint8List.fromList(pair.publicKey);
    pair.dispose();
    final text = recovery.format();
    recovery.dispose();
    return RecoveryKeyDraft(text: text, publicKey: publicKey);
  }

  /// Makes [draft] the recovery key. From now on only it can reset the
  /// master password; vaults still have to be sealed to it.
  Future<Keystore> saveRecoveryKey(
    Keystore keystore,
    RecoveryKeyDraft draft,
  ) async {
    final updated = keystore.copyWith(
      recoveryPublicKey: draft.publicKey,
      recoveryCreatedAt: DateTime.now(),
      recoveryUpdatePending: true,
    );
    await _repository.save(updated);
    return updated;
  }

  Future<Keystore> setRecoveryUpdatePending(
    Keystore keystore, {
    required bool pending,
  }) async {
    if (keystore.recoveryUpdatePending == pending) return keystore;
    final updated = keystore.copyWith(recoveryUpdatePending: pending);
    await _repository.save(updated);
    return updated;
  }

  ({Uint8List nonce, Uint8List cipherText}) _makeVerifier(DerivedKey key) {
    final nonce = _crypto.randomBytes(_crypto.nonceLength);
    return (
      nonce: nonce,
      cipherText: _crypto.encrypt(
        message: _verifierPlain,
        key: key.key,
        nonce: nonce,
        aad: key.kdf.salt,
      ),
    );
  }

  bool _checkVerifier(Keystore keystore, DerivedKey key) {
    final plain = _crypto.decrypt(
      cipherText: keystore.verifierCipherText,
      key: key.key,
      nonce: keystore.verifierNonce,
      aad: keystore.kdf.salt,
    );
    return plain != null && _crypto.equalBytes(plain, _verifierPlain);
  }

  static String? _cleanHint(String? hint) {
    final trimmed = hint?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
