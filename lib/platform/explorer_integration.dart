import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

import '../core/constants/app_info.dart';
import 'windows/win32_ffi.dart';

/// Registers the app with Windows Explorer, for the current user only (no
/// administrator rights needed):
///
/// * `.flk` vault files get the lock icon and open with the app, which
///   shows the password dialog (`app.exe --open "<vault>"`);
/// * folders and files get "Lock with Folder Locker" in their right-click
///   menu (`app.exe --lock "<path>"`). On Windows 11 it appears under
///   "Show more options".
class ExplorerIntegration {
  const ExplorerIntegration(this.executablePath);

  final String executablePath;

  static bool get isSupported => Platform.isWindows;

  static const String _classes = r'Software\Classes';
  static const String _progIdPath = '$_classes\\${AppInfo.vaultProgId}';
  static const String _extensionPath = '$_classes\\${AppInfo.vaultExtension}';
  static const List<String> _lockTargets = ['Directory', '*'];

  String get _openCommand => '"$executablePath" --open "%1"';
  String get _lockCommand => '"$executablePath" --lock "%1"';

  /// Whether the registry points to this executable.
  bool get isRegistered {
    if (!isSupported) return false;
    return _readDefault('$_progIdPath\\shell\\open\\command') == _openCommand;
  }

  void register() {
    if (!isSupported) return;
    _writeDefault(_extensionPath, AppInfo.vaultProgId);
    _writeDefault(_progIdPath, 'Locked item');
    _writeDefault(
      '$_progIdPath\\DefaultIcon',
      '"$executablePath",-${AppInfo.vaultIconResourceId}',
    );
    _writeDefault('$_progIdPath\\shell', 'open');
    _writeDefault('$_progIdPath\\shell\\open', 'Unlock with ${AppInfo.name}');
    _writeDefault('$_progIdPath\\shell\\open\\command', _openCommand);

    for (final target in _lockTargets) {
      final verb = '$_classes\\$target\\shell\\${AppInfo.lockVerbKey}';
      _writeDefault(verb, 'Lock with ${AppInfo.name}');
      _writeValue(verb, 'Icon', '"$executablePath",0');
      _writeDefault('$verb\\command', _lockCommand);
    }
    Win32.shChangeNotify(Win32.shcneAssocChanged);
  }

  void unregister() {
    if (!isSupported) return;
    _removeKey(_classes, AppInfo.vaultProgId);
    if (_readDefault(_extensionPath) == AppInfo.vaultProgId) {
      _removeKey(_classes, AppInfo.vaultExtension);
    }
    for (final target in _lockTargets) {
      _removeKey('$_classes\\$target\\shell', AppInfo.lockVerbKey);
    }
    Win32.shChangeNotify(Win32.shcneAssocChanged);
  }

  static void _writeDefault(String path, String value) =>
      _writeValue(path, '', value);

  static void _writeValue(String path, String name, String value) {
    final key = CURRENT_USER.create(path);
    try {
      key.setValue(name, RegistryValue.string(value));
    } finally {
      key.close();
    }
  }

  static String? _readDefault(String path) {
    try {
      final key = CURRENT_USER.open(path);
      try {
        return key.getString('');
      } finally {
        key.close();
      }
    } on Exception {
      return null;
    }
  }

  static void _removeKey(String parentPath, String name) {
    try {
      final parent = CURRENT_USER.open(
        parentPath,
        config: const RegistryOpenConfig(access: RegistryAccess.all),
      );
      try {
        parent.removeSubkey(name);
      } finally {
        parent.close();
      }
    } on Exception {
      // Already gone.
    }
  }
}
