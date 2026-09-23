import 'dart:io';

import 'package:path/path.dart' as p;

import 'windows/win32_ffi.dart';

/// Small Explorer helpers. They never throw: opening a window is a
/// convenience, so a failure only returns `false`.
abstract final class ShellActions {
  /// Opens a folder in Explorer, or shows a file selected in its folder.
  static Future<bool> reveal(String path) {
    final isDirectory =
        FileSystemEntity.typeSync(path) == FileSystemEntityType.directory;
    if (Platform.isWindows) {
      return _start('explorer.exe', isDirectory ? [path] : ['/select,$path']);
    }
    if (Platform.isMacOS) {
      return _start('open', isDirectory ? [path] : ['-R', path]);
    }
    return _start('xdg-open', [isDirectory ? path : p.dirname(path)]);
  }

  /// Opens a web page in the default browser.
  static Future<bool> openUrl(String url) {
    if (Platform.isWindows) return _start('explorer.exe', [url]);
    if (Platform.isMacOS) return _start('open', [url]);
    return _start('xdg-open', [url]);
  }

  /// Tells Explorer that [path] changed (created, deleted, hidden…), so
  /// open windows refresh right away.
  static void notifyChanged(String path) {
    if (!Platform.isWindows) return;
    Win32.shChangeNotify(Win32.shcneUpdateItem, path: path);
    Win32.shChangeNotify(Win32.shcneUpdateDir, path: p.dirname(path));
  }

  static Future<bool> _start(String executable, List<String> args) async {
    try {
      await Process.start(executable, args, mode: ProcessStartMode.detached);
      return true;
    } on ProcessException {
      return false;
    }
  }
}
