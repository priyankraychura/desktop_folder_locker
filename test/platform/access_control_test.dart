import 'dart:io';

import 'package:desktop_folder_locker/platform/access_control.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// These tests change real NTFS permissions, so they only run on Windows
// (in CI). The rules are always removed again in tearDown.
void main() {
  test('reports that rules are unsupported off Windows', () {
    expect(AccessControl.check(Directory.systemTemp.path), isNotNull);
    expect(AccessControl.current(Directory.systemTemp.path), isNull);
  }, skip: Platform.isWindows ? 'Checked by the Windows tests below' : false);

  group('on Windows', () {
    late Directory root;
    late Directory folder;
    late File file;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('flk_acl_');
      folder = Directory(p.join(root.path, 'Secret'))..createSync();
      file = File(p.join(folder.path, 'notes.txt'))..writeAsStringSync('hi');
      Directory(p.join(folder.path, 'sub')).createSync();
    });

    tearDown(() async {
      // A rule left behind would make the folder impossible to delete.
      for (final path in [file.path, folder.path]) {
        try {
          AccessControl.remove(path);
        } on Object {
          // Already gone.
        }
      }
      await root.delete(recursive: true);
    });

    test('the user may put rules on their own folders', () {
      expect(AccessControl.check(folder.path), isNull);
      expect(AccessControl.current(folder.path), isNull);
    });

    test('blockAll stops listing, reading and deleting', () {
      AccessControl.apply(folder.path, AccessRule.blockAll);
      expect(AccessControl.current(folder.path), AccessRule.blockAll);
      expect(folder.existsSync(), isTrue);
      expect(folder.listSync, throwsA(isA<FileSystemException>()));
      expect(file.readAsStringSync, throwsA(isA<FileSystemException>()));
      expect(file.deleteSync, throwsA(isA<FileSystemException>()));

      AccessControl.remove(folder.path);
      expect(AccessControl.current(folder.path), isNull);
      expect(folder.listSync(), hasLength(2));
      expect(file.readAsStringSync(), 'hi');
    });

    test('readOnly allows reading but no changes', () {
      AccessControl.apply(folder.path, AccessRule.readOnly);
      expect(folder.listSync(), hasLength(2));
      expect(file.readAsStringSync(), 'hi');
      expect(
        () => file.writeAsStringSync('changed'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        () => File(p.join(folder.path, 'new.txt')).writeAsStringSync('x'),
        throwsA(isA<FileSystemException>()),
      );
      expect(file.deleteSync, throwsA(isA<FileSystemException>()));

      AccessControl.remove(folder.path);
      file.writeAsStringSync('changed');
      expect(file.readAsStringSync(), 'changed');
    });

    test('applying again replaces the rule instead of adding one', () {
      AccessControl.apply(folder.path, AccessRule.readOnly);
      AccessControl.apply(folder.path, AccessRule.blockAll);
      expect(AccessControl.current(folder.path), AccessRule.blockAll);

      AccessControl.remove(folder.path);
      expect(AccessControl.current(folder.path), isNull);
      expect(folder.listSync(), hasLength(2));
    });

    test('works on a single file', () {
      AccessControl.apply(file.path, AccessRule.blockAll);
      expect(AccessControl.current(file.path), AccessRule.blockAll);
      expect(file.readAsStringSync, throwsA(isA<FileSystemException>()));

      AccessControl.remove(file.path);
      expect(file.readAsStringSync(), 'hi');
    });

    test('removing without a rule changes nothing', () {
      AccessControl.remove(folder.path);
      expect(folder.listSync(), hasLength(2));
    });
  }, skip: Platform.isWindows ? false : 'Windows only');
}
