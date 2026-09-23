import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../crypto/crypto_service.dart';
import '../engine_exception.dart';
import 'byte_io.dart';
import 'key_slot.dart';

/// The first 4096 bytes of every `.flk` vault.
///
/// ```text
/// offset  size  field
/// 0       64    prefix (immutable, authenticated with every chunk)
///                 magic "FLKVAULT", format version, flags, header size,
///                 vault id (16 random bytes), chunk size, cipher id
/// 1024    1024  key-slot area A
/// 2048    1024  key-slot area B
/// ```
///
/// Key slots live in two copies ("areas"). Each area has a generation number
/// and a BLAKE2b checksum. Changing a password rewrites only the *older*
/// area, so a crash in the middle of a rewrite always leaves one valid copy.
///
/// Drive vaults (format version 2, see `docs/DRIVE_VAULT.md`) use the same
/// header as `vault.flk` inside their folder, with the [flagDrive] flag;
/// their "chunk size" is the block size of their files. Their contents are
/// read and written by the drive helper, not by this engine.
class VaultHeader {
  const VaultHeader({
    required this.vaultId,
    required this.chunkSize,
    required this.slots,
    this.version = classicVersion,
    this.flags = 0,
    this.generation = 1,
    this.activeArea = 0,
  });

  static final Uint8List magic = ascii.encode('FLKVAULT');

  /// A single-file vault (`Name.flk`).
  static const int classicVersion = 1;

  /// A drive vault (`Name.flkd` folder).
  static const int driveVersion = 2;

  /// Set in drive vaults.
  static const int flagDrive = 1;

  /// Block size of the files in new drive vaults.
  static const int driveBlockSize = 64 * 1024;

  static const int blockSize = 4096;
  static const int prefixLength = 64;
  static const int vaultIdLength = 16;
  static const int cipherXChaCha20Poly1305 = 1;
  static const int defaultChunkSize = 256 * 1024;

  static const List<int> _areaOffsets = [1024, 2048];
  static const int _areaSize = 1024;
  static const int _areaHeaderLength = 16;
  static const int _checksumLength = 32;

  /// How many key slots fit in one area.
  static const int maxSlots =
      (_areaSize - _areaHeaderLength - _checksumLength) ~/
      KeySlot.encodedLength;

  final Uint8List vaultId;
  final int chunkSize;
  final List<KeySlot> slots;

  /// [classicVersion] or [driveVersion].
  final int version;
  final int flags;

  /// Generation of the slot area this header was read from.
  final int generation;

  /// Index (0 or 1) of the slot area this header was read from.
  final int activeArea;

  bool get isDrive => version == driveVersion;

  /// The immutable first 64 bytes. Used as associated data, so chunks and
  /// key slots can't be moved into another vault.
  Uint8List get prefix => buildPrefix(
    vaultId: vaultId,
    chunkSize: chunkSize,
    version: version,
    flags: flags,
  );

  static Uint8List buildPrefix({
    required Uint8List vaultId,
    required int chunkSize,
    int version = classicVersion,
    int flags = 0,
  }) {
    final writer = ByteWriter()
      ..bytes(magic)
      ..u16(version)
      ..u16(flags)
      ..u32(blockSize)
      ..bytes(vaultId)
      ..u32(chunkSize)
      ..u8(cipherXChaCha20Poly1305);
    writer.zeros(prefixLength - writer.length);
    return writer.toBytes();
  }

  /// Encodes the whole header block for a brand-new vault. Both slot areas
  /// get the same content, which also protects against a damaged sector.
  Uint8List encodeNew(CryptoService crypto) {
    final block = Uint8List(blockSize);
    final prefixBytes = prefix;
    block.setRange(0, prefixLength, prefixBytes);
    final area = encodeSlotArea(crypto, prefixBytes, generation, slots);
    for (final offset in _areaOffsets) {
      block.setRange(offset, offset + _areaSize, area);
    }
    return block;
  }

  static Uint8List encodeSlotArea(
    CryptoService crypto,
    Uint8List prefix,
    int generation,
    List<KeySlot> slots,
  ) {
    if (slots.isEmpty || slots.length > maxSlots) {
      throw ArgumentError('A vault needs between 1 and $maxSlots key slots');
    }
    final writer = ByteWriter()
      ..u64(generation)
      ..u8(slots.length)
      ..zeros(7);
    for (final slot in slots) {
      writer.bytes(slot.encode());
    }
    writer.zeros(_areaSize - _checksumLength - writer.length);
    final body = writer.toBytes();
    final checksum = crypto.hash([prefix, body]);
    return Uint8List.fromList([...body, ...checksum]);
  }

  /// Parses and validates a header block.
  static VaultHeader parse(Uint8List block, CryptoService crypto) {
    if (block.length < blockSize) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'The vault header is incomplete',
      );
    }
    final reader = ByteReader(Uint8List.sublistView(block, 0, prefixLength));
    final fileMagic = reader.bytes(magic.length);
    if (!_sameBytes(fileMagic, magic)) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'This is not a Folder Locker vault',
      );
    }
    final version = reader.u16();
    final flags = reader.u16();
    final headerSize = reader.u32();
    final known = switch (version) {
      classicVersion => flags == 0,
      driveVersion => flags == flagDrive,
      _ => false,
    };
    if (!known || headerSize != blockSize) {
      throw const EngineException(
        EngineErrorCode.unsupportedVersion,
        'The vault was created by a newer version of Folder Locker',
      );
    }
    final vaultId = reader.bytes(vaultIdLength);
    final chunkSize = reader.u32();
    final cipher = reader.u8();
    if (cipher != cipherXChaCha20Poly1305 ||
        chunkSize < 4096 ||
        chunkSize > 16 * 1024 * 1024) {
      throw const EngineException(
        EngineErrorCode.unsupportedVersion,
        'Unsupported vault settings',
      );
    }

    final prefixBytes = Uint8List.sublistView(block, 0, prefixLength);
    ({int generation, List<KeySlot> slots, int area})? best;
    for (var area = 0; area < _areaOffsets.length; area++) {
      final offset = _areaOffsets[area];
      final parsed = _parseArea(
        crypto,
        prefixBytes,
        Uint8List.sublistView(block, offset, offset + _areaSize),
      );
      if (parsed == null) continue;
      if (best == null || parsed.generation > best.generation) {
        best = (generation: parsed.generation, slots: parsed.slots, area: area);
      }
    }
    if (best == null) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'The key slots of this vault are damaged',
      );
    }
    return VaultHeader(
      vaultId: vaultId,
      chunkSize: chunkSize,
      slots: best.slots,
      version: version,
      flags: flags,
      generation: best.generation,
      activeArea: best.area,
    );
  }

  static ({int generation, List<KeySlot> slots})? _parseArea(
    CryptoService crypto,
    Uint8List prefix,
    Uint8List area,
  ) {
    final body = Uint8List.sublistView(area, 0, _areaSize - _checksumLength);
    final checksum = Uint8List.sublistView(area, _areaSize - _checksumLength);
    if (!crypto.equalBytes(crypto.hash([prefix, body]), checksum)) {
      return null;
    }
    final reader = ByteReader(body);
    final generation = reader.u64();
    final count = reader.u8();
    reader.skip(7);
    if (count == 0 || count > maxSlots) return null;
    final slots = <KeySlot>[
      for (var i = 0; i < count; i++)
        KeySlot.decode(reader.bytes(KeySlot.encodedLength)),
    ];
    return (generation: generation, slots: slots);
  }

  /// The file that holds the header of the vault at [path]: the vault
  /// itself, or `vault.flk` inside a drive vault's folder.
  static String headerFile(String path) =>
      FileSystemEntity.isDirectorySync(path)
      ? p.join(path, driveHeaderFileName)
      : path;

  /// Name of the header file inside a drive vault's folder.
  static const String driveHeaderFileName = 'vault.flk';

  /// Reads and parses the header of the vault at [path] (a vault file or a
  /// drive vault's folder).
  static VaultHeader read(String path, CryptoService crypto) {
    path = headerFile(path);
    final file = File(path);
    final RandomAccessFile raf;
    try {
      raf = file.openSync();
    } on PathNotFoundException {
      throw EngineException(
        EngineErrorCode.notFound,
        'Vault not found',
        path: path,
      );
    } on FileSystemException catch (e) {
      throw EngineException(EngineErrorCode.ioError, e.message, path: path);
    }
    try {
      final block = raf.readSync(blockSize);
      return parse(block, crypto);
    } finally {
      raf.closeSync();
    }
  }

  /// Replaces the key slots of an existing vault, crash-safely.
  ///
  /// Writes the area that is *not* active, with a higher generation, and
  /// flushes it to disk. Until that write completes, the old area stays
  /// valid and is what readers use.
  static VaultHeader rewriteSlots({
    required String path,
    required VaultHeader current,
    required List<KeySlot> slots,
    required CryptoService crypto,
  }) {
    final nextArea = 1 - current.activeArea;
    final nextGeneration = current.generation + 1;
    final area = encodeSlotArea(crypto, current.prefix, nextGeneration, slots);
    final raf = File(headerFile(path)).openSync(mode: FileMode.append);
    try {
      raf
        ..setPositionSync(_areaOffsets[nextArea])
        ..writeFromSync(area)
        ..flushSync();
    } finally {
      raf.closeSync();
    }
    return VaultHeader(
      vaultId: current.vaultId,
      chunkSize: current.chunkSize,
      slots: slots,
      version: current.version,
      flags: current.flags,
      generation: nextGeneration,
      activeArea: nextArea,
    );
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
