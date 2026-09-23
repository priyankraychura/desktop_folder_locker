import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import 'kdf_params.dart';

export 'package:sodium/sodium_sumo.dart'
    show KeyPair, SecureKey, TransferrableSecureKey;

/// All cryptography used by the app, in one place.
///
/// It wraps libsodium (through the `sodium` package) and exposes only the
/// few building blocks the vault format needs:
///
/// * Argon2id to turn passwords into keys,
/// * XChaCha20-Poly1305 for authenticated encryption,
/// * X25519 sealed boxes for the recovery key,
/// * BLAKE2b and HKDF-SHA256 for hashing and key separation.
///
/// Each isolate needs its own instance ([create] is cheap).
class CryptoService {
  CryptoService._(this._sodium);

  final SodiumSumo _sodium;

  /// Loads libsodium for the current isolate.
  static Future<CryptoService> create() async {
    final sodium = await SodiumSumoInit.init();
    return CryptoService._(sodium);
  }

  /// Length of every symmetric key, in bytes.
  static const int keyLength = 32;

  Aead get _aead => _sodium.crypto.aeadXChaCha20Poly1305IETF;

  /// Nonce length for [encrypt] / [decrypt] (24 bytes).
  int get nonceLength => _aead.nonceBytes;

  /// Authentication tag added by [encrypt] (16 bytes).
  int get tagLength => _aead.aBytes;

  /// Overhead added by [sealTo] (48 bytes).
  int get sealOverhead => _sodium.crypto.box.sealBytes;

  Uint8List randomBytes(int length) => _sodium.randombytes.buf(length);

  SecureKey randomKey() => _sodium.secureRandom(keyLength);

  /// Copies [bytes] into protected memory and wipes the original list.
  SecureKey takeKey(Uint8List bytes) {
    final key = _sodium.secureCopy(bytes);
    bytes.fillRange(0, bytes.length, 0);
    return key;
  }

  /// Argon2id(password, salt) → 32-byte key.
  SecureKey deriveKey(String password, KdfParams params) =>
      _sodium.crypto.pwhash.callStr(
        outLen: keyLength,
        password: password,
        salt: params.salt,
        opsLimit: params.opsLimit,
        memLimit: params.memLimitBytes,
        alg: CryptoPwhashAlgorithm.argon2id13,
      );

  /// Encrypts and authenticates [message] (and [aad], which stays plain).
  Uint8List encrypt({
    required Uint8List message,
    required SecureKey key,
    required Uint8List nonce,
    Uint8List? aad,
  }) => _aead.encrypt(
    message: message,
    nonce: nonce,
    key: key,
    additionalData: aad,
  );

  /// Decrypts [cipherText]. Returns `null` if the key is wrong or the data
  /// was changed.
  Uint8List? decrypt({
    required Uint8List cipherText,
    required SecureKey key,
    required Uint8List nonce,
    Uint8List? aad,
  }) {
    try {
      return _aead.decrypt(
        cipherText: cipherText,
        nonce: nonce,
        key: key,
        additionalData: aad,
      );
    } on SodiumException {
      return null;
    }
  }

  /// Encrypts [key] with [wrappingKey]. Used for key slots.
  Uint8List wrapKey({
    required SecureKey key,
    required SecureKey wrappingKey,
    required Uint8List nonce,
    required Uint8List aad,
  }) => key.runUnlockedSync(
    (bytes) =>
        encrypt(message: bytes, key: wrappingKey, nonce: nonce, aad: aad),
  );

  /// Reverse of [wrapKey]. Returns `null` when [wrappingKey] is wrong.
  SecureKey? unwrapKey({
    required Uint8List wrapped,
    required SecureKey wrappingKey,
    required Uint8List nonce,
    required Uint8List aad,
  }) {
    final plain = decrypt(
      cipherText: wrapped,
      key: wrappingKey,
      nonce: nonce,
      aad: aad,
    );
    if (plain == null || plain.length != keyLength) return null;
    return takeKey(plain);
  }

  /// BLAKE2b hash of all [parts] joined together.
  Uint8List hash(List<Uint8List> parts, {int length = 32}) {
    final builder = BytesBuilder(copy: false);
    parts.forEach(builder.add);
    return _sodium.crypto.genericHash(
      message: builder.toBytes(),
      outLen: length,
    );
  }

  /// Derives a purpose-specific key from [master] with HKDF-SHA256.
  SecureKey deriveSubkey({
    required SecureKey master,
    required Uint8List salt,
    required String context,
  }) {
    final hkdf = _sodium.crypto.kdfHkdfSha256;
    final prk = master.runUnlockedSync(
      (ikm) => hkdf.extract(salt: salt, ikm: ikm),
    );
    try {
      return hkdf.expand(masterKey: prk, context: context, outLen: keyLength);
    } finally {
      prk.dispose();
    }
  }

  /// Deterministic X25519 key pair from a 32-byte [seed].
  KeyPair keyPairFromSeed(Uint8List seed) {
    final secureSeed = _sodium.secureCopy(seed);
    try {
      return _sodium.crypto.box.seedKeyPair(secureSeed);
    } finally {
      secureSeed.dispose();
    }
  }

  /// Anonymous public-key encryption: anyone can seal, only the owner of the
  /// matching secret key can open.
  Uint8List sealTo(Uint8List message, Uint8List publicKey) =>
      _sodium.crypto.box.seal(message: message, publicKey: publicKey);

  /// Opens a sealed box. Returns `null` if it was not sealed for [keyPair].
  Uint8List? openSealed(Uint8List cipherText, KeyPair keyPair) {
    try {
      return _sodium.crypto.box.sealOpen(
        cipherText: cipherText,
        publicKey: keyPair.publicKey,
        secretKey: keyPair.secretKey,
      );
    } on SodiumException {
      return null;
    }
  }

  /// Compares two byte lists in constant time.
  bool equalBytes(Uint8List a, Uint8List b) =>
      a.length == b.length && _sodium.memcmp(a, b);

  TransferrableSecureKey toTransferrable(SecureKey key) =>
      _sodium.createTransferrableSecureKey(key);

  SecureKey fromTransferrable(TransferrableSecureKey key) =>
      _sodium.materializeTransferrableSecureKey(key);
}
