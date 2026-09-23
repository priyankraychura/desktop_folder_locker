import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_folder_locker/engine/crypto/crypto_service.dart';
import 'package:desktop_folder_locker/engine/crypto/kdf_params.dart';
import 'package:desktop_folder_locker/engine/engine_exception.dart';
import 'package:desktop_folder_locker/engine/format/archive_path.dart';
import 'package:desktop_folder_locker/engine/format/key_slot.dart';
import 'package:desktop_folder_locker/engine/format/payload_cipher.dart';
import 'package:desktop_folder_locker/engine/format/vault_header.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_env.dart';

void main() {
  late TestEnv env;
  late CryptoService crypto;

  setUpAll(() async {
    env = await TestEnv.create();
    crypto = env.crypto;
  });
  tearDownAll(() => env.dispose());

  Matcher throwsEngine(EngineErrorCode code) =>
      throwsA(isA<EngineException>().having((e) => e.code, 'code', code));

  PasswordKeySlot sampleSlot(KeySlotType type) => PasswordKeySlot(
    type: type,
    kdf: KdfPolicy.fast.withSalt(crypto.randomBytes(16)),
    nonce: crypto.randomBytes(24),
    wrappedKey: crypto.randomBytes(48),
  );

  group('VaultHeader', () {
    VaultHeader newHeader(List<KeySlot> slots) => VaultHeader(
      vaultId: crypto.randomBytes(16),
      chunkSize: VaultHeader.defaultChunkSize,
      slots: slots,
    );

    test('round-trips slots', () {
      final header = newHeader([
        sampleSlot(KeySlotType.masterPassword),
        RecoveryKeySlot(
          fingerprint: crypto.randomBytes(8),
          sealedKey: crypto.randomBytes(96),
        ),
      ]);
      final parsed = VaultHeader.parse(header.encodeNew(crypto), crypto);
      expect(parsed.vaultId, header.vaultId);
      expect(parsed.chunkSize, header.chunkSize);
      expect(parsed.slots, hasLength(2));
      final master = parsed.slots.first as PasswordKeySlot;
      final original = header.slots.first as PasswordKeySlot;
      expect(master.isMaster, isTrue);
      expect(master.kdf.salt, original.kdf.salt);
      expect(master.wrappedKey, original.wrappedKey);
      expect(parsed.slots.last, isA<RecoveryKeySlot>());
    });

    test('rejects files that are not vaults', () {
      expect(
        () => VaultHeader.parse(Uint8List(VaultHeader.blockSize), crypto),
        throwsEngine(EngineErrorCode.corruptVault),
      );
    });

    test('falls back to the other slot area when one is damaged', () {
      final header = newHeader([sampleSlot(KeySlotType.masterPassword)]);
      final block = header.encodeNew(crypto);
      block[1024 + 20] ^= 0xff; // damage area A
      expect(VaultHeader.parse(block, crypto).slots, hasLength(1));
      block[2048 + 20] ^= 0xff; // damage area B too
      expect(
        () => VaultHeader.parse(block, crypto),
        throwsEngine(EngineErrorCode.corruptVault),
      );
    });

    test('rewriteSlots alternates areas and keeps the file size', () {
      final header = newHeader([sampleSlot(KeySlotType.masterPassword)]);
      final file = File(env.path('rewrite.flk'))
        ..writeAsBytesSync([...header.encodeNew(crypto), 1, 2, 3]);
      final size = file.lengthSync();

      final replacement = [
        sampleSlot(KeySlotType.masterPassword),
        sampleSlot(KeySlotType.customPassword),
      ];
      final next = VaultHeader.rewriteSlots(
        path: file.path,
        current: VaultHeader.read(file.path, crypto),
        slots: replacement,
        crypto: crypto,
      );
      expect(file.lengthSync(), size);
      final reread = VaultHeader.read(file.path, crypto);
      expect(reread.generation, next.generation);
      expect(reread.generation, greaterThan(header.generation));
      expect(reread.slots, hasLength(2));
      expect(reread.activeArea, isNot(0));
      expect(file.readAsBytesSync().sublist(size - 3), [1, 2, 3]);
    });

    test('unknown slot types survive a rewrite untouched', () {
      final raw = Uint8List(KeySlot.encodedLength)..[0] = 99;
      expect(KeySlot.decode(raw), isA<UnknownKeySlot>());
      expect(KeySlot.decode(raw).encode(), raw);
    });
  });

  group('Payload chunks', () {
    const chunk = 4096;

    Uint8List encrypt(SecureKey key, Uint8List aad, List<Uint8List> pieces) {
      final file = File(env.path('payload_${pieces.length}.bin'));
      final raf = file.openSync(mode: FileMode.write);
      final encryptor = PayloadEncryptor(
        crypto: crypto,
        key: key,
        aad: aad,
        chunkSize: chunk,
        output: raf,
      );
      pieces.forEach(encryptor.add);
      encryptor.close();
      raf.closeSync();
      return file.readAsBytesSync();
    }

    Uint8List decrypt(SecureKey key, Uint8List aad, Uint8List data) {
      final file = File(env.path('payload_in.bin'))..writeAsBytesSync(data);
      final raf = file.openSync();
      try {
        final decryptor = PayloadDecryptor(
          crypto: crypto,
          key: key,
          aad: aad,
          chunkSize: chunk,
          input: raf,
          start: 0,
          end: data.length,
        );
        final out = BytesBuilder();
        for (
          var piece = decryptor.next();
          piece != null;
          piece = decryptor.next()
        ) {
          out.add(piece);
        }
        return out.toBytes();
      } finally {
        raf.closeSync();
      }
    }

    for (final size in [
      0,
      1,
      chunk - 1,
      chunk,
      chunk + 1,
      3 * chunk,
      3 * chunk + 7,
    ]) {
      test('round-trips $size bytes', () {
        final key = crypto.randomKey();
        final aad = crypto.randomBytes(64);
        final plain = crypto.randomBytes(size);
        // Split into odd pieces to exercise buffering.
        final pieces = <Uint8List>[];
        for (var i = 0; i < size; i += 1000) {
          pieces.add(
            Uint8List.sublistView(plain, i, (i + 1000).clamp(0, size)),
          );
        }
        final encrypted = encrypt(key, aad, pieces);
        expect(decrypt(key, aad, encrypted), plain);
      });
    }

    test('detects tampering, truncation and appended data', () {
      final key = crypto.randomKey();
      final aad = crypto.randomBytes(64);
      final encrypted = encrypt(key, aad, [crypto.randomBytes(3 * chunk + 10)]);

      final tampered = Uint8List.fromList(encrypted)..[chunk + 50] ^= 1;
      expect(
        () => decrypt(key, aad, tampered),
        throwsEngine(EngineErrorCode.corruptVault),
      );

      // Cut exactly at a chunk boundary: the last full chunk is not final.
      final truncated = Uint8List.sublistView(encrypted, 0, 2 * (chunk + 16));
      expect(
        () => decrypt(key, aad, truncated),
        throwsEngine(EngineErrorCode.corruptVault),
      );

      final extended = Uint8List.fromList([...encrypted, 0, 0, 0]);
      expect(
        () => decrypt(key, aad, extended),
        throwsEngine(EngineErrorCode.corruptVault),
      );

      expect(
        () => decrypt(key, crypto.randomBytes(64), encrypted),
        throwsEngine(EngineErrorCode.corruptVault),
      );
    });
  });

  group('ArchivePath', () {
    test('accepts normal relative paths', () {
      for (final path in [
        'file.txt',
        'Folder/Sub folder/photo 1.jpg',
        'ünïcødé/✓.txt',
        '.hidden',
      ]) {
        expect(ArchivePath.problem(path), isNull, reason: path);
      }
    });

    test('rejects traversal, absolute and Windows-invalid paths', () {
      for (final path in [
        '',
        '../evil',
        'a/../../evil',
        './a',
        '/abs',
        'C:/x',
        r'a\b',
        'con',
        'NUL.txt',
        'com1',
        'trailing.',
        'trailing ',
        'a//b',
        'bad:name',
        'q?',
      ]) {
        expect(ArchivePath.problem(path), isNotNull, reason: path);
      }
    });
  });
}
