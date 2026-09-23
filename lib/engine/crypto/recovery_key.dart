import 'dart:convert';
import 'dart:typed_data';

import 'crypto_service.dart';

/// The recovery key shown to the user once, during setup.
///
/// It is 160 random bits written as 32 Crockford base32 characters in groups
/// of four (`7K3M-Q9TD-…`). It is only used to derive an X25519 key pair:
/// the app keeps the *public* key and seals every vault key to it, so the
/// recovery secret itself is never stored anywhere.
class RecoveryKey {
  RecoveryKey._(this._bytes);

  final Uint8List _bytes;

  static const int byteLength = 20;
  static const int _charCount = 32;
  static const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static final Uint8List _seedContext = utf8.encode(
    'folder-locker/recovery-seed/v1',
  );
  static final Uint8List _fingerprintContext = utf8.encode(
    'folder-locker/recovery-fingerprint/v1',
  );

  /// Creates a new random recovery key.
  static RecoveryKey generate(CryptoService crypto) =>
      RecoveryKey._(crypto.randomBytes(byteLength));

  /// Parses what the user typed. Spaces, dashes and case are ignored, and
  /// look-alike letters are accepted (`O`→`0`, `I`/`L`→`1`).
  ///
  /// Returns `null` if the text can't be a recovery key.
  static RecoveryKey? tryParse(String input) {
    final normalized = input
        .toUpperCase()
        .replaceAll(RegExp(r'[\s\-_]'), '')
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1');
    if (normalized.length != _charCount) return null;

    final bytes = Uint8List(byteLength);
    var buffer = 0;
    var bits = 0;
    var index = 0;
    for (final char in normalized.split('')) {
      final value = _alphabet.indexOf(char);
      if (value < 0) return null;
      buffer = (buffer << 5) | value;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        bytes[index++] = (buffer >> bits) & 0xff;
      }
    }
    return RecoveryKey._(bytes);
  }

  /// The key as the user sees it: `XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX`.
  String format() {
    final chars = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final byte in _bytes) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        chars.write(_alphabet[(buffer >> bits) & 0x1f]);
      }
    }
    final text = chars.toString();
    return [for (var i = 0; i < text.length; i += 4) text.substring(i, i + 4)]
        .join('-');
  }

  /// The X25519 key pair derived from this recovery key.
  KeyPair keyPair(CryptoService crypto) {
    final seed = crypto.hash([_seedContext, _bytes]);
    try {
      return crypto.keyPairFromSeed(seed);
    } finally {
      seed.fillRange(0, seed.length, 0);
    }
  }

  /// A short, non-secret identifier of a recovery public key. Stored in
  /// vaults so the app can tell which recovery key a vault expects.
  static Uint8List fingerprint(CryptoService crypto, Uint8List publicKey) =>
      // BLAKE2b outputs at least 16 bytes; 8 are plenty for an identifier.
      Uint8List.sublistView(
        crypto.hash([_fingerprintContext, publicKey], length: 16),
        0,
        8,
      );

  /// Wipes the key from memory.
  void dispose() => _bytes.fillRange(0, _bytes.length, 0);
}
