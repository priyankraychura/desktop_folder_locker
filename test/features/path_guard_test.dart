import 'dart:io';

import 'package:desktop_folder_locker/features/items/application/path_guard.dart';
import 'package:desktop_folder_locker/features/items/domain/protected_item.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late PathGuard guard;

  String dir(String relative) {
    final path = p.join(root.path, relative);
    Directory(path).createSync(recursive: true);
    return path;
  }

  ProtectedItem item(String path, {String? vault}) => ProtectedItem(
    id: path,
    name: p.basename(path),
    kind: ItemKind.folder,
    itemPath: path,
    vaultPath: vault,
    method: ProtectionMethod.encrypt,
    hide: false,
    passwordMode: PasswordMode.master,
    status: vault == null
        ? ProtectionStatus.unprotected
        : ProtectionStatus.protected,
    addedAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('flk_guard_');
    guard = PathGuard(
      appDataDir: dir('AppData/Roaming/FolderLocker'),
      executableDir: dir('Program Files/Cloak'),
      environment: {
        'ProgramFiles': p.join(root.path, 'Program Files'),
        'windir': dir('Windows'),
        'APPDATA': p.join(root.path, 'AppData', 'Roaming'),
        'USERPROFILE': dir('Users/me'),
      },
    );
  });
  tearDown(() => root.delete(recursive: true));

  test('allows normal folders and files', () {
    expect(guard.check(dir('Users/me/Documents/Secret'), []), isNull);
    final file = File(p.join(dir('Users/me/Desktop'), 'notes.txt'))
      ..writeAsStringSync('x');
    expect(guard.check(file.path, []), isNull);
    expect(guard.check(dir('D/Projects'), []), isNull);
  });

  test('refuses missing paths, drive roots and vault files', () {
    expect(guard.check(p.join(root.path, 'nope'), []), PathProblem.notFound);
    expect(guard.check(p.rootPrefix(root.path), []), PathProblem.driveRoot);
    final vault = File(p.join(root.path, 'x.flk'))..writeAsStringSync('v');
    expect(guard.check(vault.path, []), PathProblem.isVault);
    // Drive vaults are folders: they, and everything in them, are vaults.
    expect(guard.check(dir('Taxes.flkd'), []), PathProblem.isVault);
    expect(guard.check(dir('Taxes.flkd/data'), []), PathProblem.isVault);
  });

  test('refuses system folders, their contents and their parents', () {
    expect(guard.check(dir('Windows'), []), PathProblem.systemLocation);
    expect(
      guard.check(dir('Windows/System32'), []),
      PathProblem.systemLocation,
    );
    expect(
      guard.check(dir('Program Files/Other'), []),
      PathProblem.systemLocation,
    );
    expect(guard.check(root.path, []), isNotNull);
  });

  test('refuses the app folders', () {
    expect(
      guard.check(dir('AppData/Roaming/FolderLocker/journal'), []),
      anyOf(PathProblem.appFolder, PathProblem.systemLocation),
    );
  });

  test('refuses main user folders but allows what is inside', () {
    expect(guard.check(dir('Users/me'), []), PathProblem.userFolderRoot);
    expect(
      guard.check(dir('Users/me/Documents'), []),
      PathProblem.userFolderRoot,
    );
    expect(guard.check(dir('Users/me/Documents/Taxes'), []), isNull);
  });

  test('refuses overlaps with items already in the list', () {
    final secret = dir('D/Secret');
    final items = [item(secret)];
    expect(guard.check(secret, items), PathProblem.alreadyProtected);
    expect(
      guard.check(dir('D/Secret/Inner'), items),
      PathProblem.insideProtectedItem,
    );
    expect(guard.check(dir('D'), items), PathProblem.containsProtectedItem);
  });

  test('refuses symbolic links', () {
    final link = Link(p.join(root.path, 'link'))..createSync(dir('D/Target'));
    expect(guard.check(link.path, []), PathProblem.isLink);
  }, skip: Platform.isWindows ? 'Needs developer mode on Windows' : false);
}
