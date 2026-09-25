import 'dart:io';

import 'windows/win32_ffi.dart';

/// Whether the app is the Microsoft Store version: installed from an MSIX
/// package (`installer/msix`), which declares the Explorer entries itself
/// and can't install Dokany or the lock badge.
///
/// The Windows 11 menu package (`installer/sparse`) is a package too, but
/// the app it points to is the one Setup installed.
abstract final class AppPackage {
  /// The identity name of the Windows 11 menu package.
  static const String menuPackageName = 'Cloak.ExplorerMenu';

  static final bool isStoreApp = _detect();

  static bool _detect() {
    if (!Platform.isWindows) return false;
    try {
      final fullName = Win32.currentPackageFullName();
      return fullName != null && isStorePackage(fullName);
    } on Object {
      // Not told: the app works as installed by Setup.
      return false;
    }
  }

  /// Whether the package of [fullName] (`Name_Version_Arch_Resource_Id`) is
  /// the Store version's.
  static bool isStorePackage(String fullName) =>
      fullName.split('_').first != menuPackageName;
}
