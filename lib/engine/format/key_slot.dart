import 'dart:typed_data';

import '../crypto/kdf_params.dart';
import '../engine_exception.dart';
import 'byte_io.dart';

/// Identifies what can open a key slot.
enum KeySlotType {
  /// The app's master password.
  masterPassword(1),

  /// A password chosen for this one item.
  customPassword(2),

  /// The recovery key (X25519 sealed box).
  recovery(3);

  const KeySlotType(this.id);

  final int id;

  static KeySlotType? fromId(int id) {
    for (final type in values) {
      if (type.id == id) return type;
    }
    return null;
  }
}

/// A copy of the vault's data key, encrypted for one way of unlocking.
///
/// A vault holds several slots (for example master password + recovery key),
/// each one able to recover the same data key. Every slot is stored in a
/// fixed-size 160-byte record.
sealed class KeySlot {
  const KeySlot();

  static const int encodedLength = 160;
  static const int _version = 1;
  static const int _headerLength = 4;

  /// Serializes the slot to exactly [encodedLength] bytes.
  Uint8List encode() {
    final payload = encodePayload();
    final writer = ByteWriter()
      ..u8(typeId)
      ..u8(_version)
      ..u16(payload.length)
      ..bytes(payload);
    writer.zeros(encodedLength - writer.length);
    return writer.toBytes();
  }

  int get typeId;

  Uint8List encodePayload();

  /// Parses one 160-byte record. Unknown types are kept as
  /// [UnknownKeySlot] so newer slots survive a rewrite by this version.
  static KeySlot decode(Uint8List raw) {
    if (raw.length != encodedLength) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'Key slot has the wrong size',
      );
    }
    final reader = ByteReader(raw);
    final typeId = reader.u8();
    final version = reader.u8();
    final payloadLength = reader.u16();
    if (payloadLength > encodedLength - _headerLength) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'Key slot payload is too long',
      );
    }
    final type = KeySlotType.fromId(typeId);
    if (type == null || version != _version) return UnknownKeySlot(raw);

    final payload = ByteReader(reader.bytes(payloadLength));
    return switch (type) {
      KeySlotType.masterPassword ||
      KeySlotType.customPassword => PasswordKeySlot._decode(type, payload),
      KeySlotType.recovery => RecoveryKeySlot._decode(payload),
    };
  }
}

/// A data key encrypted with a key derived from a password (Argon2id).
final class PasswordKeySlot extends KeySlot {
  const PasswordKeySlot({
    required this.type,
    required this.kdf,
    required this.nonce,
    required this.wrappedKey,
  }) : assert(
         type == KeySlotType.masterPassword ||
             type == KeySlotType.customPassword,
         'PasswordKeySlot only supports password slot types',
       );

  factory PasswordKeySlot._decode(KeySlotType type, ByteReader reader) {
    final opsLimit = reader.u32();
    final memLimitKiB = reader.u32();
    final salt = reader.bytes(KdfParams.saltLength);
    final nonce = reader.bytes(_nonceLength);
    final wrapped = reader.bytes(_wrappedLength);
    return PasswordKeySlot(
      type: type,
      kdf: KdfParams(opsLimit: opsLimit, memLimitKiB: memLimitKiB, salt: salt),
      nonce: nonce,
      wrappedKey: wrapped,
    );
  }

  static const int _nonceLength = 24;
  static const int _wrappedLength = 48;

  final KeySlotType type;
  final KdfParams kdf;
  final Uint8List nonce;
  final Uint8List wrappedKey;

  bool get isMaster => type == KeySlotType.masterPassword;

  @override
  int get typeId => type.id;

  @override
  Uint8List encodePayload() {
    if (nonce.length != _nonceLength || wrappedKey.length != _wrappedLength) {
      throw ArgumentError('Invalid password slot sizes');
    }
    return (ByteWriter()
          ..u32(kdf.opsLimit)
          ..u32(kdf.memLimitKiB)
          ..bytes(kdf.salt)
          ..bytes(nonce)
          ..bytes(wrappedKey))
        .toBytes();
  }
}

/// A data key sealed to the recovery public key.
final class RecoveryKeySlot extends KeySlot {
  const RecoveryKeySlot({required this.fingerprint, required this.sealedKey});

  factory RecoveryKeySlot._decode(ByteReader reader) {
    final fingerprint = reader.bytes(fingerprintLength);
    final sealedLength = reader.u16();
    return RecoveryKeySlot(
      fingerprint: fingerprint,
      sealedKey: reader.bytes(sealedLength),
    );
  }

  static const int fingerprintLength = 8;

  /// Identifies the recovery key this slot was sealed for.
  final Uint8List fingerprint;

  /// `seal(vaultId || dataKey)`.
  final Uint8List sealedKey;

  @override
  int get typeId => KeySlotType.recovery.id;

  @override
  Uint8List encodePayload() =>
      (ByteWriter()
            ..bytes(fingerprint)
            ..u16(sealedKey.length)
            ..bytes(sealedKey))
          .toBytes();
}

/// A slot written by a newer version of the app. Kept byte-for-byte.
final class UnknownKeySlot extends KeySlot {
  const UnknownKeySlot(this.raw);

  final Uint8List raw;

  @override
  int get typeId => raw[0];

  @override
  Uint8List encode() => Uint8List.fromList(raw);

  @override
  Uint8List encodePayload() => Uint8List(0);
}
