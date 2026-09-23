import 'dart:typed_data';

import 'package:desktop_folder_locker/engine/crypto/crypto_service.dart';
import 'package:desktop_folder_locker/engine/crypto/kdf_params.dart';
import 'package:desktop_folder_locker/engine/crypto/recovery_key.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late CryptoService crypto;

  setUpAll(() async => crypto = await CryptoService.create());

  group('RecoveryKey', () {
    test('formats as 8 groups of 4 and parses back', () {
      final key = RecoveryKey.generate(crypto);
      final text = key.format();
      expect(text, matches(RegExp(r'^([0-9A-Z]{4}-){7}[0-9A-Z]{4}$')));
      expect(text, isNot(contains(RegExp('[ILOU]'))));
      final parsed = RecoveryKey.tryParse(text)!;
      expect(parsed.format(), text);
    });

    test('parsing ignores case, spaces and look-alike letters', () {
      final key = RecoveryKey.generate(crypto);
      final text = key.format();
      final messy = ' ${text.toLowerCase().replaceAll('-', ' ')} '
          .replaceAll('0', 'o')
          .replaceAll('1', 'l');
      expect(RecoveryKey.tryParse(messy)!.format(), text);
    });

    test('rejects wrong length and invalid characters', () {
      expect(RecoveryKey.tryParse(''), isNull);
      expect(RecoveryKey.tryParse('ABCD-EFGH'), isNull);
      expect(RecoveryKey.tryParse('U' * 32), isNull);
    });

    test('derives the same key pair from the same key', () {
      final key = RecoveryKey.generate(crypto);
      final a = key.keyPair(crypto);
      final b = RecoveryKey.tryParse(key.format())!.keyPair(crypto);
      expect(a.publicKey, b.publicKey);
      expect(
        RecoveryKey.fingerprint(crypto, a.publicKey),
        RecoveryKey.fingerprint(crypto, b.publicKey),
      );
    });
  });

  group('CryptoService', () {
    test('wraps and unwraps keys, rejects the wrong key and aad', () {
      final dataKey = crypto.randomKey();
      final kek = crypto.randomKey();
      final nonce = crypto.randomBytes(crypto.nonceLength);
      final aad = Uint8List.fromList([1, 2, 3]);
      final wrapped = crypto.wrapKey(
        key: dataKey,
        wrappingKey: kek,
        nonce: nonce,
        aad: aad,
      );

      final unwrapped = crypto.unwrapKey(
        wrapped: wrapped,
        wrappingKey: kek,
        nonce: nonce,
        aad: aad,
      );
      expect(unwrapped, isNotNull);
      expect(unwrapped!.extractBytes(), dataKey.extractBytes());

      expect(
        crypto.unwrapKey(
          wrapped: wrapped,
          wrappingKey: crypto.randomKey(),
          nonce: nonce,
          aad: aad,
        ),
        isNull,
      );
      expect(
        crypto.unwrapKey(
          wrapped: wrapped,
          wrappingKey: kek,
          nonce: nonce,
          aad: Uint8List.fromList([9]),
        ),
        isNull,
      );
    });

    test('password derivation is deterministic per salt', () {
      final salt = crypto.randomBytes(KdfParams.saltLength);
      final kdf = KdfPolicy.fast.withSalt(salt);
      final a = crypto.deriveKey('secret', kdf).extractBytes();
      final b = crypto.deriveKey('secret', kdf).extractBytes();
      final c = crypto.deriveKey('Secret', kdf).extractBytes();
      expect(a, b);
      expect(a, isNot(c));
    });

    test('sealed boxes only open with the matching key pair', () {
      final pair = RecoveryKey.generate(crypto).keyPair(crypto);
      final other = RecoveryKey.generate(crypto).keyPair(crypto);
      final message = Uint8List.fromList(List.generate(48, (i) => i));
      final sealed = crypto.sealTo(message, pair.publicKey);
      expect(crypto.openSealed(sealed, pair), message);
      expect(crypto.openSealed(sealed, other), isNull);
    });
  });
}
