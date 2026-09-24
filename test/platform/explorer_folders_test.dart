import 'dart:io';

import 'package:desktop_folder_locker/platform/explorer_folders.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The Explorer plug-in built by `cargo build` in `native/`, if any.
String? _builtPlugin() {
  for (final profile in ['release', 'debug']) {
    final path = p.join('native', 'target', profile, 'folder_locker_shell.dll');
    if (File(path).existsSync()) return p.absolute(path);
  }
  return null;
}

/// The app asking Explorer which folders it shows, through the real
/// plug-in: a folder that a window opens is listed, and not any more once
/// the window is closed. It opens an Explorer window, so it runs only when
/// `FLK_SHELL_E2E` is set (CI does).
void main() {
  final plugin = Platform.isWindows ? _builtPlugin() : null;
  final skip = !Platform.isWindows
      ? 'Windows only'
      : plugin == null
      ? 'Build the plug-in first: cargo build in native/'
      : Platform.environment['FLK_SHELL_E2E'] == null
      ? 'Set FLK_SHELL_E2E=1 to open an Explorer window'
      : false;

  test(
    'lists the folders that Explorer shows',
    () async {
      final explorer = NativeExplorerFolders(plugin!);
      final temp = await Directory.systemTemp.createTemp('flk_shown_');
      addTearDown(() => temp.delete(recursive: true));
      // Long names, as Explorer reports them (%TEMP% can be C:\Users\RUNNER~1).
      final folder = p.join(temp.resolveSymbolicLinksSync(), 'Taxes, 2024 #1');
      Directory(folder).createSync();

      Future<bool> shown() async {
        final folders = await explorer.shown();
        expect(folders, isNotNull, reason: 'Explorer answers');
        return folders!.any((shown) => p.equals(shown, folder));
      }

      Future<void> waitFor(String what, Future<bool> Function() done) async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!await done()) {
          if (DateTime.now().isAfter(deadline)) fail('Timed out: $what');
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }

      expect(await shown(), isFalse);
      // As the app shows a folder it unlocked.
      await Process.start('explorer.exe', [folder]);
      await waitFor('Explorer shows the folder', shown);

      // Closes it, as the user would.
      final closed = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-Command',
          r'(New-Object -ComObject Shell.Application).Windows() | '
              r'Where-Object { $_.Document.Folder.Self.Path -eq $env:FLK_FOLDER } | '
              r'ForEach-Object { $_.Quit() }',
        ],
        environment: {'FLK_FOLDER': folder},
      );
      expect(closed.exitCode, 0, reason: '${closed.stderr}');
      await waitFor('its window closes', () async => !await shown());
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
