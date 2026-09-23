import 'dart:typed_data';

/// Settings for turning a password into a key with Argon2id.
///
/// They are stored next to every password-protected key, so the cost can be
/// raised in the future without breaking existing vaults.
class KdfParams {
  const KdfParams({
    required this.opsLimit,
    required this.memLimitKiB,
    required this.salt,
  });

  /// Number of Argon2id passes.
  final int opsLimit;

  /// Memory used by Argon2id, in KiB.
  final int memLimitKiB;

  /// 16 random bytes, unique per password.
  final Uint8List salt;

  static const int saltLength = 16;

  int get memLimitBytes => memLimitKiB * 1024;

  KdfParams withSalt(Uint8List newSalt) =>
      KdfParams(opsLimit: opsLimit, memLimitKiB: memLimitKiB, salt: newSalt);

  Map<String, Object?> toJson() => {
    'algorithm': 'argon2id13',
    'opsLimit': opsLimit,
    'memLimitKiB': memLimitKiB,
    'salt': _encodeSalt(salt),
  };

  static KdfParams fromJson(Map<String, Object?> json) => KdfParams(
    opsLimit: json['opsLimit']! as int,
    memLimitKiB: json['memLimitKiB']! as int,
    salt: _decodeSalt(json['salt']! as String),
  );

  static String _encodeSalt(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _decodeSalt(String hex) => Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

/// How expensive password hashing should be.
///
/// Production uses libsodium's "moderate" profile (3 passes, 256 MiB), which
/// takes roughly half a second on a typical PC. Tests use [fast] so the suite
/// stays quick.
class KdfPolicy {
  const KdfPolicy({required this.opsLimit, required this.memLimitKiB});

  final int opsLimit;
  final int memLimitKiB;

  static const KdfPolicy standard = KdfPolicy(
    opsLimit: 3,
    memLimitKiB: 256 * 1024,
  );

  /// Minimum Argon2id cost. Only for tests.
  static const KdfPolicy fast = KdfPolicy(opsLimit: 1, memLimitKiB: 8);

  KdfParams withSalt(Uint8List salt) =>
      KdfParams(opsLimit: opsLimit, memLimitKiB: memLimitKiB, salt: salt);
}
