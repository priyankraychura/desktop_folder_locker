import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Windows' Data Protection API: encrypts bytes with a key that only this
/// Windows user, signed in, can use. Only call it on Windows.
abstract final class Dpapi {
  static final DynamicLibrary _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  /// No dialog may show: fail instead.
  static const int _uiForbidden = 0x1;

  static final int Function(
    Pointer<_DataBlob>,
    Pointer<Utf16>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_DataBlob>,
  )
  _protect = _crypt32
      .lookupFunction<
        Int32 Function(
          Pointer<_DataBlob>,
          Pointer<Utf16>,
          Pointer<_DataBlob>,
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Pointer<_DataBlob>,
        ),
        int Function(
          Pointer<_DataBlob>,
          Pointer<Utf16>,
          Pointer<_DataBlob>,
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<_DataBlob>,
        )
      >('CryptProtectData');

  static final int Function(
    Pointer<_DataBlob>,
    Pointer<Pointer<Utf16>>,
    Pointer<_DataBlob>,
    Pointer<Void>,
    Pointer<Void>,
    int,
    Pointer<_DataBlob>,
  )
  _unprotect = _crypt32
      .lookupFunction<
        Int32 Function(
          Pointer<_DataBlob>,
          Pointer<Pointer<Utf16>>,
          Pointer<_DataBlob>,
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Pointer<_DataBlob>,
        ),
        int Function(
          Pointer<_DataBlob>,
          Pointer<Pointer<Utf16>>,
          Pointer<_DataBlob>,
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<_DataBlob>,
        )
      >('CryptUnprotectData');

  static final Pointer<Void> Function(Pointer<Void>) _localFree = _kernel32
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');

  /// [data] encrypted for this user, or `null` if Windows refused.
  static Uint8List? protect(Uint8List data) => _run(data, (input, output) {
    return _protect(
      input,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      _uiForbidden,
      output,
    );
  });

  /// What [protect] encrypted, or `null` if it can't be read (another
  /// user or PC, or damaged). The caller should wipe the result.
  static Uint8List? unprotect(Uint8List data) => _run(data, (input, output) {
    return _unprotect(
      input,
      nullptr,
      nullptr,
      nullptr,
      nullptr,
      _uiForbidden,
      output,
    );
  });

  static Uint8List? _run(
    Uint8List data,
    int Function(Pointer<_DataBlob> input, Pointer<_DataBlob> output) call,
  ) => using((arena) {
    final bytes = arena<Uint8>(data.isEmpty ? 1 : data.length);
    bytes.asTypedList(data.length).setAll(0, data);
    final input = arena<_DataBlob>()
      ..ref.size = data.length
      ..ref.data = bytes;
    final output = arena<_DataBlob>();
    try {
      if (call(input, output) == 0) return null;
      final out = output.ref;
      final result = Uint8List.fromList(out.data.asTypedList(out.size));
      out.data.asTypedList(out.size).fillRange(0, out.size, 0);
      _localFree(out.data.cast());
      return result;
    } finally {
      bytes.asTypedList(data.length).fillRange(0, data.length, 0);
    }
  });
}

/// DATA_BLOB.
final class _DataBlob extends Struct {
  @Uint32()
  external int size;

  external Pointer<Uint8> data;
}
