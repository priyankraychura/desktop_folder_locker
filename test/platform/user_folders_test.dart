import 'dart:io';

import 'package:desktop_folder_locker/platform/user_folders.dart';
import 'package:desktop_folder_locker/platform/windows/win32_ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  final skip = Platform.isWindows ? false : 'Windows only';

  bool listed(List<String> folders, String path) => folders.any(
    (folder) => p.equals(folder.toLowerCase(), path.toLowerCase()),
  );

  test('finds where Windows keeps the user\'s folders', () {
    final profile = Platform.environment['USERPROFILE']!;
    // FOLDERID_Profile: the GUID bytes must be laid out right.
    expect(
      Win32.knownFolderPath('5E6C858F-0E22-4760-9AFE-EA3317B67173'),
      profile,
    );
    final folders = UserFolders.find();
    // The profile comes from ProfileList, Documents from the known folders.
    expect(listed(folders, profile), isTrue, reason: '$folders');
    expect(
      folders.any((folder) => p.basename(folder).contains('Documents')),
      isTrue,
      reason: '$folders',
    );
  }, skip: skip);

  test('finds nothing outside Windows', () {
    expect(UserFolders.find(), isEmpty);
  }, skip: Platform.isWindows ? 'Not on Windows' : false);
}
