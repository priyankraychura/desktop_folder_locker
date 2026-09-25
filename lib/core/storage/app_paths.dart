import 'dart:io';

import 'package:path/path.dart' as p;

import '../constants/app_info.dart';

/// Where the app keeps its own files.
///
/// On Windows this is `%APPDATA%\FolderLocker`. Other platforms are only
/// used for development and tests.
class AppPaths {
  const AppPaths(this.root);

  factory AppPaths.resolve() {
    final env = Platform.environment;
    final String base;
    if (Platform.isWindows) {
      base =
          env['APPDATA'] ??
          p.join(env['USERPROFILE'] ?? r'C:\', 'AppData', 'Roaming');
    } else {
      base =
          env['XDG_DATA_HOME'] ??
          p.join(env['HOME'] ?? Directory.systemTemp.path, '.local', 'share');
    }
    return AppPaths(p.join(base, AppInfo.dataFolderName));
  }

  final String root;

  String get keystoreFile => p.join(root, 'keystore.json');
  String get itemsFile => p.join(root, 'items.json');
  String get settingsFile => p.join(root, 'settings.json');
  String get journalDir => p.join(root, 'journal');
  String get inboxDir => p.join(root, 'inbox');
  String get instanceLockFile => p.join(root, 'instance.lock');

  /// Keys to lock unlocked items again without a password (see
  /// `RelockKeys`).
  String get relockDir => p.join(root, 'relock');

  void ensureExists() {
    for (final dir in [root, journalDir, inboxDir, relockDir]) {
      Directory(dir).createSync(recursive: true);
    }
  }
}
