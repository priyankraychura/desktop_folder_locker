import 'dart:convert';
import 'dart:typed_data';

import '../../../engine/crypto/kdf_params.dart';

/// What the app stores about the master password. It contains no secret:
/// only the Argon2id settings, a small encrypted "verifier" that proves a
/// typed password is correct, and the recovery *public* key.
class Keystore {
  const Keystore({
    required this.kdf,
    required this.verifierNonce,
    required this.verifierCipherText,
    required this.recoveryPublicKey,
    required this.createdAt,
    required this.passwordChangedAt,
    this.hint,
  });

  factory Keystore.fromJson(Map<String, Object?> json) {
    final verifier = json['verifier']! as Map<String, Object?>;
    final recovery = json['recovery']! as Map<String, Object?>;
    return Keystore(
      kdf: KdfParams.fromJson(json['kdf']! as Map<String, Object?>),
      verifierNonce: base64Decode(verifier['nonce']! as String),
      verifierCipherText: base64Decode(verifier['cipherText']! as String),
      recoveryPublicKey: base64Decode(recovery['publicKey']! as String),
      hint: json['hint'] as String?,
      createdAt: DateTime.parse(json['createdAt']! as String),
      passwordChangedAt: DateTime.parse(json['passwordChangedAt']! as String),
    );
  }

  static const int version = 1;

  final KdfParams kdf;
  final Uint8List verifierNonce;
  final Uint8List verifierCipherText;
  final Uint8List recoveryPublicKey;

  /// Optional hint shown on the lock screen.
  final String? hint;
  final DateTime createdAt;
  final DateTime passwordChangedAt;

  Keystore copyWith({
    KdfParams? kdf,
    Uint8List? verifierNonce,
    Uint8List? verifierCipherText,
    String? hint,
    bool clearHint = false,
    DateTime? passwordChangedAt,
  }) => Keystore(
    kdf: kdf ?? this.kdf,
    verifierNonce: verifierNonce ?? this.verifierNonce,
    verifierCipherText: verifierCipherText ?? this.verifierCipherText,
    recoveryPublicKey: recoveryPublicKey,
    hint: clearHint ? null : hint ?? this.hint,
    createdAt: createdAt,
    passwordChangedAt: passwordChangedAt ?? this.passwordChangedAt,
  );

  Map<String, Object?> toJson() => {
    'version': version,
    'kdf': kdf.toJson(),
    'verifier': {
      'nonce': base64Encode(verifierNonce),
      'cipherText': base64Encode(verifierCipherText),
    },
    'recovery': {'publicKey': base64Encode(recoveryPublicKey)},
    'hint': hint,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'passwordChangedAt': passwordChangedAt.toUtc().toIso8601String(),
  };
}
