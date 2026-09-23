import 'dart:io';

import 'windows/win32_ffi.dart';

/// Windows file attributes and disk information, with safe fallbacks on
/// other platforms (used by tests and development on Linux/macOS).
abstract final class FileSystemInfo {
  static const int readOnly = 0x1;
  static const int hidden = 0x2;
  static const int system = 0x4;
  static const int normal = 0x80;

  /// The attribute bits the vault stores and restores.
  static const int preserved = readOnly | hidden | system;

  /// Attribute bits of [path] limited to [preserved]; `0` when unknown.
  static int preservedAttributes(String path) {
    if (!Platform.isWindows) return 0;
    return (Win32.getFileAttributes(path) ?? 0) & preserved;
  }

  static int? attributes(String path) =>
      Platform.isWindows ? Win32.getFileAttributes(path) : null;

  /// Sets the attribute bits of [path]. No-op on other platforms.
  static bool setAttributes(String path, int attributes) {
    if (!Platform.isWindows) return true;
    return Win32.setFileAttributes(path, attributes == 0 ? normal : attributes);
  }

  /// Adds and/or removes attribute bits, keeping the others.
  static bool updateAttributes(String path, {int add = 0, int remove = 0}) {
    if (!Platform.isWindows) return true;
    final current = Win32.getFileAttributes(path);
    if (current == null) return false;
    // Only the settable bits: read-only, hidden, system, archive,
    // not-content-indexed.
    const settable = 0x1 | 0x2 | 0x4 | 0x20 | 0x2000;
    final next = ((current & settable) | add) & ~remove;
    return setAttributes(path, next);
  }

  static bool isHidden(String path) =>
      Platform.isWindows && ((attributes(path) ?? 0) & hidden) != 0;

  /// Free space available on the drive holding [path], or `null` when it
  /// can't be determined.
  static int? freeSpace(String path) =>
      Platform.isWindows ? Win32.freeDiskSpace(path) : null;
}
