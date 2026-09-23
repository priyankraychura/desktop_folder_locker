import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:win32_registry/win32_registry.dart';

import '../core/constants/app_info.dart';
import 'windows/win32_ffi.dart';

/// Registers the app with Windows Explorer, for the current user only (no
/// administrator rights needed):
///
/// * `.flk` vault files get the lock icon and open with the app, which
///   shows the password dialog (`app.exe --open "<vault>"`);
/// * folders, files and open drives get one right-click entry. With the
///   Explorer plug-in next to the app (`folder_locker_shell.dll`, see
///   `native/shell`), the entry follows each item: “Lock with…”, “Unlock
///   with…” or “Open with…”, which run `app.exe --lock`, `--unlock` or
///   `--open "<path>"`. Without it, folders and files get “Lock with Folder
///   Locker” (`app.exe --lock "<path>"`).
///
/// On Windows 11 the entry is under “Show more options”. The installer
/// writes the same entries (installer/folder_locker.iss): keep both in sync.
class ExplorerIntegration {
  const ExplorerIntegration(
    this.executablePath, {
    this.classesPath = defaultClassesPath,
  });

  final String executablePath;

  /// Where the entries go, under HKEY_CURRENT_USER. Tests use another key.
  final String classesPath;

  static const String defaultClassesPath = r'Software\Classes';

  /// The plug-in's class id (`CLSID_MENU` in native/shell/src/com.rs).
  static const String pluginClassId = '{3C1C048E-1C62-4B0B-87AC-55EDAD0E97BB}';
  static const String pluginFileName = 'folder_locker_shell.dll';

  static bool get isSupported => Platform.isWindows;

  /// Folders and files get the entry; with the plug-in, drives too (to
  /// close a vault that is open as a drive).
  static const List<String> _staticTargets = ['Directory', '*'];
  static const List<String> _pluginTargets = ['Directory', '*', 'Drive'];

  String get pluginPath => p.join(p.dirname(executablePath), pluginFileName);

  /// Whether the plug-in ships next to the app.
  bool get hasPlugin => File(pluginPath).existsSync();

  String get _progIdPath => '$classesPath\\${AppInfo.vaultProgId}';
  String get _extensionPath => '$classesPath\\${AppInfo.vaultExtension}';
  String get _classPath => '$classesPath\\CLSID\\$pluginClassId';
  String _verbPath(String target) =>
      '$classesPath\\$target\\shell\\${AppInfo.lockVerbKey}';

  String get _openCommand => '"$executablePath" --open "%1"';
  String get _lockCommand => '"$executablePath" --lock "%1"';

  /// Whether the registry points to this executable, with the plug-in if
  /// it ships next to it.
  bool get isRegistered {
    if (!isSupported) return false;
    if (_readValue('$_progIdPath\\shell\\open\\command') != _openCommand) {
      return false;
    }
    final handler = _readValue(
      _verbPath('Directory'),
      name: 'ExplorerCommandHandler',
    );
    if (hasPlugin) {
      return handler == pluginClassId &&
          _readValue('$_classPath\\InprocServer32') == pluginPath;
    }
    return handler == null &&
        _readValue('${_verbPath('Directory')}\\command') == _lockCommand;
  }

  void register() {
    if (!isSupported) return;
    _writeValue(_extensionPath, AppInfo.vaultProgId);
    _writeValue(_progIdPath, 'Locked item');
    _writeValue(
      '$_progIdPath\\DefaultIcon',
      '"$executablePath",-${AppInfo.vaultIconResourceId}',
    );
    _writeValue('$_progIdPath\\shell', 'open');
    _writeValue('$_progIdPath\\shell\\open', 'Unlock with ${AppInfo.name}');
    _writeValue('$_progIdPath\\shell\\open\\command', _openCommand);

    // The right-click entry is written anew, so nothing of the other kind
    // is left in it.
    _removeEntry();
    if (hasPlugin) {
      _writeValue(_classPath, '${AppInfo.name} Explorer plug-in');
      _writeValue('$_classPath\\InprocServer32', pluginPath);
      _writeValue(
        '$_classPath\\InprocServer32',
        'Apartment',
        name: 'ThreadingModel',
      );
      for (final target in _pluginTargets) {
        _writeValue(
          _verbPath(target),
          pluginClassId,
          name: 'ExplorerCommandHandler',
        );
      }
    } else {
      for (final target in _staticTargets) {
        _writeValue(_verbPath(target), 'Lock with ${AppInfo.name}');
        _writeValue(_verbPath(target), '"$executablePath",0', name: 'Icon');
        _writeValue('${_verbPath(target)}\\command', _lockCommand);
      }
    }
    Win32.shChangeNotify(Win32.shcneAssocChanged);
  }

  void unregister() {
    if (!isSupported) return;
    _removeKey(classesPath, AppInfo.vaultProgId);
    if (_readValue(_extensionPath) == AppInfo.vaultProgId) {
      _removeKey(classesPath, AppInfo.vaultExtension);
    }
    _removeEntry();
    Win32.shChangeNotify(Win32.shcneAssocChanged);
  }

  void _removeEntry() {
    for (final target in _pluginTargets) {
      _removeKey('$classesPath\\$target\\shell', AppInfo.lockVerbKey);
    }
    _removeKey('$classesPath\\CLSID', pluginClassId);
  }

  static void _writeValue(String path, String value, {String name = ''}) {
    final key = CURRENT_USER.create(path);
    try {
      key.setValue(name, RegistryValue.string(value));
    } finally {
      key.close();
    }
  }

  static String? _readValue(String path, {String name = ''}) {
    try {
      final key = CURRENT_USER.open(path);
      try {
        return key.getString(name);
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
