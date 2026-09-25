import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// The few Win32 functions the app calls directly.
///
/// These signatures have been stable for decades, so binding them here keeps
/// the app independent from larger wrapper packages. Only call these on
/// Windows (guard with `Platform.isWindows`).
abstract final class Win32 {
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');
  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

  static const int invalidFileAttributes = 0xFFFFFFFF;

  static final int Function(Pointer<Utf16>) _getFileAttributes = _kernel32
      .lookupFunction<
        Uint32 Function(Pointer<Utf16>),
        int Function(Pointer<Utf16>)
      >('GetFileAttributesW');

  static final int Function(Pointer<Utf16>, int) _setFileAttributes = _kernel32
      .lookupFunction<
        Int32 Function(Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, int)
      >('SetFileAttributesW');

  static final int Function(
    Pointer<Utf16>,
    Pointer<Uint64>,
    Pointer<Uint64>,
    Pointer<Uint64>,
  )
  _getDiskFreeSpaceEx = _kernel32
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        ),
        int Function(
          Pointer<Utf16>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        )
      >('GetDiskFreeSpaceExW');

  static final void Function(int, int, Pointer<Void>, Pointer<Void>)
  _shChangeNotify = _shell32
      .lookupFunction<
        Void Function(Int32, Uint32, Pointer<Void>, Pointer<Void>),
        void Function(int, int, Pointer<Void>, Pointer<Void>)
      >('SHChangeNotify');

  static final int Function(Pointer<Uint32>, Pointer<Utf16>)
  _getCurrentPackageFullName = _kernel32
      .lookupFunction<
        Int32 Function(Pointer<Uint32>, Pointer<Utf16>),
        int Function(Pointer<Uint32>, Pointer<Utf16>)
      >('GetCurrentPackageFullName');

  static final int Function(int) _allowSetForegroundWindow = _user32
      .lookupFunction<Int32 Function(Uint32), int Function(int)>(
        'AllowSetForegroundWindow',
      );

  /// Returns the attribute bits of [path], or `null` if it can't be read.
  static int? getFileAttributes(String path) => using((arena) {
    final value = _getFileAttributes(path.toNativeUtf16(allocator: arena));
    return value == invalidFileAttributes ? null : value;
  });

  static bool setFileAttributes(String path, int attributes) => using((arena) {
    return _setFileAttributes(
          path.toNativeUtf16(allocator: arena),
          attributes,
        ) !=
        0;
  });

  /// Free bytes available to the current user on the volume of [path].
  static int? freeDiskSpace(String path) => using((arena) {
    final available = arena<Uint64>();
    final ok = _getDiskFreeSpaceEx(
      path.toNativeUtf16(allocator: arena),
      available,
      nullptr,
      nullptr,
    );
    return ok == 0 ? null : available.value;
  });

  // SHChangeNotify event ids and flags.
  static const int shcneRenameItem = 0x00000001;
  static const int shcneCreate = 0x00000002;
  static const int shcneDelete = 0x00000004;
  static const int shcneMkDir = 0x00000008;
  static const int shcneRmDir = 0x00000010;
  static const int shcneUpdateDir = 0x00001000;
  static const int shcneUpdateItem = 0x00002000;
  static const int shcneAttributes = 0x00000800;
  static const int shcneAssocChanged = 0x08000000;
  static const int shcnfIdList = 0x0000;
  static const int shcnfPathW = 0x0005;
  static const int shcnfFlush = 0x1000;
  static const int shcnfFlushNoWait = 0x3000;

  /// Tells Explorer that something changed at [path] (or globally when
  /// [path] is null, e.g. for file associations).
  static void shChangeNotify(int event, {String? path, String? path2}) {
    using((arena) {
      final first = path == null
          ? nullptr
          : path.toNativeUtf16(allocator: arena).cast<Void>();
      final second = path2 == null
          ? nullptr
          : path2.toNativeUtf16(allocator: arena).cast<Void>();
      final flags = path == null
          ? shcnfIdList | shcnfFlush
          : shcnfPathW | shcnfFlushNoWait;
      _shChangeNotify(event, flags, first, second);
    });
  }

  /// The full name of the package the app runs from (like
  /// `Name_1.2.0.0_x64__publisherid`), or `null` without one.
  static String? currentPackageFullName() => using((arena) {
    // PACKAGE_FULL_NAME_MAX_LENGTH, and the NUL.
    const capacity = 128;
    final length = arena<Uint32>()..value = capacity;
    final name = arena<Uint16>(capacity).cast<Utf16>();
    // ERROR_SUCCESS; otherwise APPMODEL_ERROR_NO_PACKAGE.
    if (_getCurrentPackageFullName(length, name) != 0) return null;
    return name.toDartString();
  });

  /// `ASFW_ANY`: lets any process bring its window to the foreground.
  static const int asfwAny = 0xFFFFFFFF;

  static bool allowSetForegroundWindow([int processId = asfwAny]) =>
      _allowSetForegroundWindow(processId) != 0;
}
