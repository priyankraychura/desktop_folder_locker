import 'dart:typed_data';

import 'windows/dpapi.dart';

/// Protects small secrets that the app keeps on the disk, so only this
/// Windows user can read them.
abstract interface class KeyProtector {
  /// [data] protected, or `null` if that failed.
  Uint8List? protect(Uint8List data);

  /// What [protect] made, or `null` if it can't be read. The caller should
  /// wipe the result.
  Uint8List? unprotect(Uint8List data);
}

/// Windows' Data Protection API (see [Dpapi]).
class DpapiKeyProtector implements KeyProtector {
  const DpapiKeyProtector();

  @override
  Uint8List? protect(Uint8List data) => Dpapi.protect(data);

  @override
  Uint8List? unprotect(Uint8List data) => Dpapi.unprotect(data);
}

/// Keeps the bytes as they are: only for development and tests on other
/// platforms, which the app doesn't ship for.
class PlainKeyProtector implements KeyProtector {
  const PlainKeyProtector();

  @override
  Uint8List? protect(Uint8List data) => Uint8List.fromList(data);

  @override
  Uint8List? unprotect(Uint8List data) => Uint8List.fromList(data);
}
