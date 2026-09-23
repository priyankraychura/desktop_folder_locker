import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../crypto/crypto_service.dart';
import '../engine_exception.dart';

/// Something that accepts plaintext bytes.
abstract interface class ByteSink {
  void add(Uint8List data);
}

/// Something that hands out plaintext in pieces. Returns `null` at the end.
abstract interface class ByteSource {
  Uint8List? next();
}

/// Nonce for chunk [index]: `u64 index (LE) | u8 final flag | 15 zero bytes`.
///
/// Every vault has its own random data key, so a counter-based nonce never
/// repeats for the same key. The final flag makes truncation detectable
/// (the "STREAM" construction also used by age and Tink).
Uint8List _chunkNonce(int nonceLength, int index, {required bool isFinal}) {
  final nonce = Uint8List(nonceLength);
  ByteData.sublistView(nonce).setUint64(0, index, Endian.little);
  nonce[8] = isFinal ? 1 : 0;
  return nonce;
}

/// Encrypts a stream of plaintext into fixed-size authenticated chunks.
///
/// All chunks hold exactly `chunkSize` bytes except the last one, which is
/// flagged as final and may be shorter (or empty for an empty payload).
class PayloadEncryptor implements ByteSink {
  PayloadEncryptor({
    required this._crypto,
    required this._key,
    required this._aad,
    required int chunkSize,
    required this._output,
  }) : _chunkSize = chunkSize,
       _buffer = Uint8List(chunkSize);

  final CryptoService _crypto;
  final SecureKey _key;
  final Uint8List _aad;
  final int _chunkSize;
  final RandomAccessFile _output;
  final Uint8List _buffer;
  int _filled = 0;
  int _index = 0;
  bool _closed = false;

  @override
  void add(Uint8List data) {
    if (_closed) throw StateError('PayloadEncryptor is closed');
    var offset = 0;
    while (offset < data.length) {
      // A full buffer is only written once more data arrives, so a
      // non-final chunk is never the last one in the file.
      if (_filled == _chunkSize) _writeChunk(isFinal: false);
      final count = math.min(_chunkSize - _filled, data.length - offset);
      _buffer.setRange(_filled, _filled + count, data, offset);
      _filled += count;
      offset += count;
    }
  }

  /// Writes the final chunk. Must be called exactly once.
  void close() {
    if (_closed) return;
    _writeChunk(isFinal: true);
    _closed = true;
  }

  void _writeChunk({required bool isFinal}) {
    final cipherText = _crypto.encrypt(
      message: Uint8List.sublistView(_buffer, 0, _filled),
      key: _key,
      nonce: _chunkNonce(_crypto.nonceLength, _index, isFinal: isFinal),
      aad: _aad,
    );
    _output.writeFromSync(cipherText);
    _index++;
    _filled = 0;
  }
}

/// Decrypts and authenticates chunks written by [PayloadEncryptor].
class PayloadDecryptor implements ByteSource {
  PayloadDecryptor({
    required this._crypto,
    required this._key,
    required this._aad,
    required this._chunkSize,
    required this._input,
    required int start,
    required this._end,
  }) : _position = start;

  final CryptoService _crypto;
  final SecureKey _key;
  final Uint8List _aad;
  final int _chunkSize;
  final RandomAccessFile _input;
  final int _end;
  int _position;
  int _index = 0;
  bool _done = false;

  /// Bytes of the file consumed so far (for progress).
  int get position => _position;

  @override
  Uint8List? next() {
    if (_done) return null;
    final fullChunk = _chunkSize + _crypto.tagLength;
    final remaining = _end - _position;
    final isFinal = remaining <= fullChunk;
    final length = isFinal ? remaining : fullChunk;
    if (length < _crypto.tagLength) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'The vault is truncated',
      );
    }

    _input.setPositionSync(_position);
    final cipherText = _input.readSync(length);
    if (cipherText.length != length) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'The vault is truncated',
      );
    }
    final plain = _crypto.decrypt(
      cipherText: cipherText,
      key: _key,
      nonce: _chunkNonce(_crypto.nonceLength, _index, isFinal: isFinal),
      aad: _aad,
    );
    if (plain == null) {
      throw EngineException(
        EngineErrorCode.corruptVault,
        'Chunk $_index is damaged or was modified',
      );
    }
    _position += length;
    _index++;
    _done = isFinal;
    return plain;
  }
}
