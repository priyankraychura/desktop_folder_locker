import 'dart:convert';
import 'dart:typed_data';

import '../engine_exception.dart';

/// Writes little-endian binary data into a growing buffer.
class ByteWriter {
  final BytesBuilder _builder = BytesBuilder(copy: false);
  final ByteData _scratch = ByteData(8);

  int get length => _builder.length;

  void u8(int value) => _builder.addByte(value & 0xff);

  void u16(int value) {
    _scratch.setUint16(0, value, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 2).sublist(0));
  }

  void u32(int value) {
    _scratch.setUint32(0, value, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 4).sublist(0));
  }

  void u64(int value) {
    _scratch.setUint64(0, value, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 8).sublist(0));
  }

  void i64(int value) {
    _scratch.setInt64(0, value, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 8).sublist(0));
  }

  void bytes(List<int> value) => _builder.add(value);

  /// Writes [count] zero bytes.
  void zeros(int count) {
    if (count > 0) _builder.add(Uint8List(count));
  }

  /// Writes a UTF-8 string prefixed with its byte length as `u16`.
  void string16(String value) {
    final encoded = utf8.encode(value);
    if (encoded.length > 0xffff) {
      throw const EngineException(
        EngineErrorCode.unsupportedContent,
        'String is longer than 65535 bytes',
      );
    }
    u16(encoded.length);
    bytes(encoded);
  }

  /// Writes a UTF-8 string prefixed with its byte length as `u32`.
  void string32(String value) {
    final encoded = utf8.encode(value);
    u32(encoded.length);
    bytes(encoded);
  }

  Uint8List toBytes() => _builder.toBytes();
}

/// Reads little-endian binary data with bounds checks.
///
/// Any read past the end throws a [EngineErrorCode.corruptVault] error,
/// because in this app binary data always comes from vault files.
class ByteReader {
  ByteReader(this._bytes) : _view = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _view;
  int _offset = 0;

  int get offset => _offset;
  int get remaining => _bytes.length - _offset;

  void _need(int count) {
    if (count < 0 || _offset + count > _bytes.length) {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'Unexpected end of data',
      );
    }
  }

  int u8() {
    _need(1);
    return _bytes[_offset++];
  }

  int u16() {
    _need(2);
    final value = _view.getUint16(_offset, Endian.little);
    _offset += 2;
    return value;
  }

  int u32() {
    _need(4);
    final value = _view.getUint32(_offset, Endian.little);
    _offset += 4;
    return value;
  }

  int u64() {
    _need(8);
    final value = _view.getUint64(_offset, Endian.little);
    _offset += 8;
    return value;
  }

  int i64() {
    _need(8);
    final value = _view.getInt64(_offset, Endian.little);
    _offset += 8;
    return value;
  }

  Uint8List bytes(int count) {
    _need(count);
    final value = Uint8List.fromList(
      Uint8List.sublistView(_bytes, _offset, _offset + count),
    );
    _offset += count;
    return value;
  }

  void skip(int count) {
    _need(count);
    _offset += count;
  }

  String string16() => _utf8(u16());

  String string32() => _utf8(u32());

  String _utf8(int length) {
    final raw = bytes(length);
    try {
      return utf8.decode(raw);
    } on FormatException {
      throw const EngineException(
        EngineErrorCode.corruptVault,
        'Invalid UTF-8 text',
      );
    }
  }
}
