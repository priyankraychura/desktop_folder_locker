import 'dart:io';

import 'package:desktop_folder_locker/platform/explorer_integration.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:win32_registry/win32_registry.dart';

// The entries go under a test key in HKEY_CURRENT_USER instead of
// Software\Classes, so Explorer never sees them. Windows only (in CI).
void main() {
  const testKey = 'CloakTests';
  const classes = 'Software\\$testKey\\Classes';
  const classId = ExplorerIntegration.pluginClassId;
  late Directory app;
  late String exe;
  late ExplorerIntegration integration;

  String verb(String target) => '$classes\\$target\\shell\\FolderLocker.Lock';

  String? read(String path, [String name = '']) {
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

  bool exists(String path) {
    try {
      CURRENT_USER.open(path).close();
      return true;
    } on Exception {
      return false;
    }
  }

  setUp(() {
    app = Directory.systemTemp.createTempSync('flk_explorer_');
    exe = p.join(app.path, 'cloak.exe');
    integration = ExplorerIntegration(exe, classesPath: classes);
  });

  tearDown(() {
    try {
      final software = CURRENT_USER.open(
        'Software',
        config: const RegistryOpenConfig(access: RegistryAccess.all),
      );
      try {
        software.removeSubkey(testKey);
      } finally {
        software.close();
      }
    } on Exception {
      // Nothing was written.
    }
    app.deleteSync(recursive: true);
  });

  test('without the plug-in, folders and files get "Lock with"', () {
    expect(integration.hasPlugin, isFalse);
    expect(integration.isRegistered, isFalse);

    integration.register();
    expect(integration.isRegistered, isTrue);
    expect(read('$classes\\.flk'), 'FolderLocker.Vault');
    expect(
      read('$classes\\FolderLocker.Vault\\shell\\open\\command'),
      '"$exe" --open "%1"',
    );
    for (final target in ['Directory', '*']) {
      expect(read(verb(target)), 'Lock with Cloak');
      expect(read('${verb(target)}\\command'), '"$exe" --lock "%1"');
    }
    expect(exists(verb('Drive')), isFalse);
    expect(exists('$classes\\CLSID\\$classId'), isFalse);

    integration.unregister();
    expect(integration.isRegistered, isFalse);
    expect(exists('$classes\\.flk'), isFalse);
    expect(exists(verb('Directory')), isFalse);
  }, skip: !Platform.isWindows);

  test('with the plug-in, its entry replaces "Lock with"', () {
    // Registered before the plug-in shipped.
    integration.register();
    final dll = File(p.join(app.path, 'cloak_shell.dll'))
      ..writeAsBytesSync(const []);
    expect(integration.hasPlugin, isTrue);
    expect(integration.isRegistered, isFalse);

    integration.register();
    expect(integration.isRegistered, isTrue);
    expect(read('$classes\\CLSID\\$classId\\InprocServer32'), dll.path);
    expect(
      read('$classes\\CLSID\\$classId\\InprocServer32', 'ThreadingModel'),
      'Apartment',
    );
    for (final target in ['Directory', '*', 'Drive']) {
      expect(read(verb(target), 'ExplorerCommandHandler'), classId);
      // The plug-in gives the title and runs the app itself.
      expect(read(verb(target)), isNull);
      expect(exists('${verb(target)}\\command'), isFalse);
    }

    // An older version without the plug-in is installed over it.
    dll.deleteSync();
    expect(integration.isRegistered, isFalse);
    integration.register();
    expect(integration.isRegistered, isTrue);
    expect(exists('$classes\\CLSID\\$classId'), isFalse);
    expect(read(verb('Directory'), 'ExplorerCommandHandler'), isNull);
    expect(exists(verb('Drive')), isFalse);

    integration.unregister();
    expect(exists('$classes\\CLSID\\$classId'), isFalse);
    expect(exists(verb('*')), isFalse);
  }, skip: !Platform.isWindows);
}
