import 'dart:io';
import 'dart:ui';

import 'package:desktop_folder_locker/features/auth/application/session_controller.dart';
import 'package:desktop_folder_locker/features/items/application/folder_window_watcher.dart';
import 'package:desktop_folder_locker/features/items/application/items_controller.dart';
import 'package:desktop_folder_locker/features/items/application/protection_controller.dart';
import 'package:desktop_folder_locker/features/items/domain/protected_item.dart';
import 'package:desktop_folder_locker/features/settings/application/settings_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/app_harness.dart';

/// Rounds run only when a test says so.
final _watcherProvider = Provider<FolderWindowWatcher>((ref) {
  final watcher = FolderWindowWatcher(ref, interval: const Duration(hours: 1));
  ref.onDispose(watcher.dispose);
  return watcher;
});

/// The same, made after the test says whether Explorer tells changes.
final _watchingProvider = Provider<FolderWindowWatcher>((ref) {
  final watcher = FolderWindowWatcher(ref, interval: const Duration(hours: 1));
  ref.onDispose(watcher.dispose);
  return watcher;
});

void main() {
  late AppHarness harness;
  late FolderWindowWatcher watcher;
  late List<String> closed;

  ProtectionController protection() =>
      harness.container.read(protectionControllerProvider.notifier);

  setUp(() async {
    harness = await AppHarness.create();
    while (harness.container.read(sessionControllerProvider).status ==
        SessionStatus.loading) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await harness.container.read(itemsControllerProvider.future);
    await harness.container
        .read(sessionControllerProvider.notifier)
        .setUp(password: 'master-password');
    harness.container
        .read(sessionControllerProvider.notifier)
        .finishOnboarding();
    watcher = harness.container.read(_watcherProvider);
    closed = [];
    watcher.closed.listen((event) => closed.add(event.item.name));
  });

  tearDown(() async {
    harness.container.dispose();
    await harness.dispose();
  });

  /// Protects a new folder with [method] and unlocks it again.
  Future<ProtectedItem> unlocked(
    String name, {
    ProtectionMethod method = ProtectionMethod.encrypt,
  }) async {
    final folder = Directory(harness.userPath(name))
      ..createSync(recursive: true);
    File(p.join(folder.path, 'a.txt')).writeAsStringSync('A');
    final item = await protection().protectNew(
      ProtectRequest(
        path: folder.path,
        method: method,
        hide: false,
        passwordMode: PasswordMode.master,
      ),
    );
    return (await protection().unlock(item)).item;
  }

  /// Explorer shows [folders], then the watcher looks.
  Future<void> explorerShows(List<String>? folders) async {
    harness.explorer.folders = folders;
    await watcher.check();
    await Future<void>.delayed(Duration.zero);
  }

  test('reports a folder once its last window closes', () async {
    final taxes = await unlocked('Taxes');

    await explorerShows([]);
    expect(closed, isEmpty, reason: 'it was never open');
    await explorerShows([taxes.itemPath, harness.userPath('Other')]);
    expect(closed, isEmpty);
    await explorerShows([harness.userPath('Other')]);
    expect(closed, ['Taxes']);
    await explorerShows([]);
    expect(closed, ['Taxes'], reason: 'once, until it opens again');

    await explorerShows([taxes.itemPath]);
    await explorerShows([]);
    expect(closed, ['Taxes', 'Taxes']);
  });

  test('a window inside the folder counts; one above it doesn\'t', () async {
    final taxes = await unlocked('Taxes');

    await explorerShows([p.join(taxes.itemPath, '2024')]);
    await explorerShows([taxes.itemPath]);
    expect(closed, isEmpty);
    await explorerShows([p.dirname(taxes.itemPath)]);
    expect(closed, ['Taxes']);
  });

  test('a drive counts as its drive', () async {
    final photos = await unlocked('Photos', method: ProtectionMethod.drive);
    expect(photos.isMounted, isTrue);

    await explorerShows([photos.mountPoint!]);
    await explorerShows([]);
    expect(closed, ['Photos']);
  });

  test('Explorer that doesn\'t answer closes nothing', () async {
    final taxes = await unlocked('Taxes');

    await explorerShows([taxes.itemPath]);
    await explorerShows(null);
    expect(closed, isEmpty);
    await explorerShows([]);
    expect(closed, ['Taxes']);
  });

  test('items locked meanwhile are forgotten', () async {
    final taxes = await unlocked('Taxes');

    await explorerShows([taxes.itemPath]);
    await protection().lockAgain(taxes);
    await explorerShows([]);
    expect(closed, isEmpty);
  });

  group('as Explorer tells it', () {
    late FolderWindowWatcher watching;
    late List<(String, Rect?)> reported;

    setUp(() {
      harness.explorer.watches = true;
      watching = harness.container.read(_watchingProvider);
      reported = [];
      watching.closed.listen(
        (event) => reported.add((event.item.name, event.window)),
      );
    });

    /// Explorer tells that it shows [folders] now, after a change in
    /// [window].
    Future<void> change(List<String> folders, {Rect? window}) async {
      harness.explorer.change(folders, window: window);
      await Future<void>.delayed(Duration.zero);
    }

    test('reports a folder as its window closes, with where it was', () async {
      final taxes = await unlocked('Taxes');
      const window = Rect.fromLTRB(100, 80, 900, 700);

      await change([taxes.itemPath]);
      expect(reported, isEmpty);
      await change([], window: window);
      expect(reported, [('Taxes', window)]);
      await change([]);
      expect(reported, hasLength(1), reason: 'once, until it opens again');
    });

    test('going to another folder in the window counts too', () async {
      final taxes = await unlocked('Taxes');

      await change([p.join(taxes.itemPath, '2024')]);
      await change([p.dirname(taxes.itemPath)]);
      expect(reported.map((r) => r.$1), ['Taxes']);
    });

    test('a folder that showed before it was unlocked counts', () async {
      final folder = harness.userPath('Taxes');
      await change([folder]);
      await unlocked('Taxes');
      await Future<void>.delayed(Duration.zero);

      await change([]);
      expect(reported.map((r) => r.$1), ['Taxes']);
    });

    test('never asks Explorer itself', () async {
      final taxes = await unlocked('Taxes');
      await change([taxes.itemPath]);

      harness.explorer.folders = [];
      await watching.check();
      expect(reported, isEmpty);
    });

    test('asks Explorer again once watching stops working', () async {
      final taxes = await unlocked('Taxes');
      await change([taxes.itemPath]);
      await harness.explorer.stopWatching();
      await Future<void>.delayed(Duration.zero);

      harness.explorer.folders = [];
      await watching.check();
      await Future<void>.delayed(Duration.zero);
      expect(reported.map((r) => r.$1), ['Taxes']);
    });
  });

  test('nothing with the setting off', () async {
    final taxes = await unlocked('Taxes');
    await harness.container
        .read(settingsControllerProvider.notifier)
        .setAskToLockWhenClosed(false);

    await explorerShows([taxes.itemPath]);
    await explorerShows([]);
    expect(closed, isEmpty);
  });
}
