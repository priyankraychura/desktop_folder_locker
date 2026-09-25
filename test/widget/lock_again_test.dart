import 'dart:io';

import 'package:desktop_folder_locker/app/app_window.dart';
import 'package:desktop_folder_locker/features/auth/presentation/lock_screen.dart';
import 'package:desktop_folder_locker/features/items/application/folder_window_watcher.dart';
import 'package:desktop_folder_locker/features/settings/domain/app_settings.dart';
import 'package:desktop_folder_locker/platform/system_tray.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';
import '../support/explorer_scenario.dart';

// After unlocking: the question to lock a folder again once its Explorer
// window closes, locking from the notification area, and the app ending
// once nothing is left to look after.
void main() {
  /// Explorer shows [folders]; the app looks.
  Future<void> explorerShows(
    WidgetTester tester,
    AppHarness app,
    List<String> folders,
  ) async {
    app.explorer.folders = folders;
    await tester.runAsync(
      () => app.container.read(folderWindowWatcherProvider).check(),
    );
    await settleReal(tester);
  }

  TrayMenuItem trayEntry(AppHarness app, String id) =>
      app.tray.last.menu.singleWhere((entry) => entry.id == id);

  /// Explorer started the app to open "Taxes", which is unlocked now.
  Future<AppHarness> unlockedFromExplorer(WidgetTester tester) async {
    final app = await desktopHarness(tester, initialWindow: startedByExplorer);
    final vault = await lockedFolder(tester, app);
    openFromExplorer(app, vault);
    await tester.pumpWidget(app.app);
    await settleReal(tester);
    await unlockInDialog(tester);
    expect(app.window.visible, isFalse);
    return app;
  }

  testWidgets('closing the folder asks to lock it; then the app ends', (
    tester,
  ) async {
    final app = await unlockedFromExplorer(tester);
    final folder = app.userPath('Taxes');

    await explorerShows(tester, app, [folder]);
    expect(find.text('Lock “Taxes” again?'), findsNothing);
    await explorerShows(tester, app, []);
    expect(find.text('Lock “Taxes” again?'), findsOneWidget);
    expect(find.text('You closed it in Explorer.'), findsOneWidget);
    expect(find.text('Master password'), findsNothing, reason: 'key kept');
    expect(app.window.look, 'compact');
    expect(app.window.visible, isTrue);

    await tester.tap(find.text('Lock'));
    await settleReal(tester, rounds: 20);
    expect(Directory(folder).existsSync(), isFalse);
    expect(File('$folder.flk').existsSync(), isTrue);
    await settleUntil(tester, () => app.window.ended);
    expect(app.window.ended, isTrue, reason: 'nothing left to look after');

    await app.shutdown(tester);
  });

  testWidgets('asks as Explorer tells the window closed, over that window', (
    tester,
  ) async {
    final app = await desktopHarness(tester, initialWindow: startedByExplorer);
    app.explorer.watches = true;
    final vault = await lockedFolder(tester, app);
    openFromExplorer(app, vault);
    await tester.pumpWidget(app.app);
    await settleReal(tester);
    await unlockInDialog(tester);
    final folder = app.userPath('Taxes');
    const window = Rect.fromLTRB(200, 150, 1000, 750);

    app.explorer.change([folder]);
    await settleReal(tester);
    expect(find.text('Lock “Taxes” again?'), findsNothing);
    app.explorer.change([], window: window);
    await settleReal(tester);
    expect(find.text('Lock “Taxes” again?'), findsOneWidget);
    expect(app.window.look, 'compact');
    expect(app.window.shownOver, window);

    await app.shutdown(tester);
  });

  testWidgets('“Not now” keeps it unlocked; it asks again next time', (
    tester,
  ) async {
    final app = await unlockedFromExplorer(tester);
    final folder = app.userPath('Taxes');

    await explorerShows(tester, app, [folder]);
    await explorerShows(tester, app, []);
    await tester.tap(find.text('Not now'));
    await settleReal(tester);
    expect(Directory(folder).existsSync(), isTrue);
    expect(app.window.visible, isFalse);
    expect(app.window.ended, isFalse);
    expect(app.tray.visible, isTrue);

    await explorerShows(tester, app, []);
    expect(find.text('Lock “Taxes” again?'), findsNothing, reason: 'closed');
    await explorerShows(tester, app, [folder]);
    await explorerShows(tester, app, []);
    expect(find.text('Lock “Taxes” again?'), findsOneWidget);

    await app.shutdown(tester);
  });

  testWidgets('the notification area locks it while the app is locked', (
    tester,
  ) async {
    final app = await unlockedFromExplorer(tester);
    final lock = trayEntry(app, 'lockAll');
    expect(lock.label, 'Lock “Taxes”');
    expect(lock.enabled, isTrue, reason: 'its key is kept while it is open');
    final lockApp = trayEntry(app, 'lockApp');
    expect(lockApp.label, 'Cloak is locked');
    expect(lockApp.enabled, isFalse);

    app.tray.select('lockAll');
    await settleReal(tester, rounds: 20);
    expect(File('${app.userPath('Taxes')}.flk').existsSync(), isTrue);
    expect(find.byType(Dialog), findsNothing, reason: 'nothing to ask');
    await settleUntil(tester, () => app.window.ended);
    expect(app.window.ended, isTrue, reason: 'nothing left to look after');

    await app.shutdown(tester);
  });

  group('an item unlocked before the app locked', () {
    testWidgets('locks without a password once its window closes', (
      tester,
    ) async {
      final app = await desktopHarness(tester, windowVisible: false);
      await lockedFolder(tester, app, unlocked: ['Photos']);
      await tester.pumpWidget(app.app);
      await settleReal(tester);
      final folder = app.userPath('Photos');

      await explorerShows(tester, app, [folder]);
      await explorerShows(tester, app, []);
      expect(find.text('Lock “Photos” again?'), findsOneWidget);
      expect(find.text('Master password'), findsNothing, reason: 'keys kept');

      await tester.tap(find.text('Lock'));
      await settleReal(tester, rounds: 20);
      expect(Directory(folder).existsSync(), isFalse);
      expect(File('$folder.flk').existsSync(), isTrue);
      await settleUntil(tester, () => app.window.ended);
      expect(app.window.ended, isTrue);

      await app.shutdown(tester);
    });

    testWidgets('the notification area locks it without asking', (
      tester,
    ) async {
      final app = await desktopHarness(tester, windowVisible: false);
      await lockedFolder(tester, app, unlocked: ['Photos']);
      await tester.pumpWidget(app.app);
      await settleReal(tester);
      expect(trayEntry(app, 'lockAll').enabled, isTrue);

      app.tray.select('lockAll');
      await settleUntil(
        tester,
        () => File('${app.userPath('Photos')}.flk').existsSync(),
      );
      expect(File('${app.userPath('Photos')}.flk').existsSync(), isTrue);
      expect(find.byType(Dialog), findsNothing, reason: 'nothing to ask');

      await app.shutdown(tester);
    });
  });

  group('an item unlocked without the keys to lock it again', () {
    testWidgets('asks for the master password to lock it', (tester) async {
      final app = await desktopHarness(tester, windowVisible: false);
      await lockedFolder(tester, app, unlocked: ['Photos'], relockKeys: false);
      await tester.pumpWidget(app.app);
      await settleReal(tester);
      final folder = app.userPath('Photos');

      await explorerShows(tester, app, [folder]);
      await explorerShows(tester, app, []);
      expect(find.text('Lock “Photos” again?'), findsOneWidget);
      expect(app.window.look, 'compact');

      await tester.enterText(find.byType(TextField), 'wrong password');
      await tester.tap(find.text('Lock'));
      await settleReal(tester);
      expect(find.text('That password is not correct.'), findsOneWidget);
      expect(Directory(folder).existsSync(), isTrue);

      await tester.enterText(find.byType(TextField), masterPassword);
      await tester.tap(find.text('Lock'));
      await settleReal(tester, rounds: 20);
      expect(File('$folder.flk').existsSync(), isTrue);
      await settleUntil(tester, () => app.window.ended);
      expect(app.window.ended, isTrue);

      await app.shutdown(tester);
    });

    testWidgets('from the notification area, asks just for the password', (
      tester,
    ) async {
      final app = await desktopHarness(tester, windowVisible: false);
      await lockedFolder(tester, app, unlocked: ['Photos'], relockKeys: false);
      await tester.pumpWidget(app.app);
      await settleReal(tester);

      app.tray.select('lockAll');
      await settleReal(tester);
      expect(find.text('Lock “Photos” again?'), findsOneWidget);
      expect(find.text('You closed it in Explorer.'), findsNothing);
      await tester.enterText(find.byType(TextField), masterPassword);
      await tester.tap(find.text('Lock'));
      await settleReal(tester, rounds: 20);
      expect(File('${app.userPath('Photos')}.flk').existsSync(), isTrue);
      await settleUntil(tester, () => app.window.ended);
      expect(app.window.ended, isTrue);

      await app.shutdown(tester);
    });
  });

  testWidgets('without the notification-area icon, it still asks', (
    tester,
  ) async {
    final app = await desktopHarness(
      tester,
      initialWindow: startedByExplorer,
      settings: const AppSettings(keepRunningInTray: false),
    );
    final vault = await lockedFolder(tester, app);
    openFromExplorer(app, vault);
    await tester.pumpWidget(app.app);
    await settleReal(tester);
    await unlockInDialog(tester);
    expect(app.window.visible, isFalse, reason: 'waits in the background');
    expect(app.window.ended, isFalse);
    expect(app.tray.visible, isFalse);

    final folder = app.userPath('Taxes');
    await explorerShows(tester, app, [folder]);
    await explorerShows(tester, app, []);
    expect(find.text('Lock “Taxes” again?'), findsOneWidget);

    await tester.tap(find.text('Lock'));
    await settleReal(tester, rounds: 20);
    expect(File('$folder.flk').existsSync(), isTrue);
    await settleUntil(tester, () => app.window.ended);
    expect(app.window.ended, isTrue, reason: 'nothing left to look after');

    await app.shutdown(tester);
  });

  testWidgets('with the app open, the question shows over it', (tester) async {
    final app = await desktopHarness(tester);
    await lockedFolder(tester, app, unlocked: ['Photos']);
    await tester.pumpWidget(app.app);
    await settleReal(tester);

    await explorerShows(tester, app, [app.userPath('Photos')]);
    await explorerShows(tester, app, []);
    expect(find.text('Lock “Photos” again?'), findsOneWidget);
    expect(find.byType(LockScreen), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await settleReal(tester);
    expect(app.window.visible, isTrue);
    expect(app.window.ended, isFalse);

    await app.shutdown(tester);
  });

  testWidgets('closing the window keeps the app only while it is needed', (
    tester,
  ) async {
    final app = await desktopHarness(tester);
    await lockedFolder(tester, app);
    await tester.pumpWidget(app.app);
    await settleReal(tester);
    final window = app.container.read(windowStateProvider.notifier);
    expect(window.canRunInBackground, isFalse, reason: 'everything locked');

    final withPhotos = await desktopHarness(tester);
    await lockedFolder(tester, withPhotos, unlocked: ['Photos']);
    expect(
      withPhotos.container
          .read(windowStateProvider.notifier)
          .canRunInBackground,
      isTrue,
    );

    await app.shutdown(tester);
    withPhotos.container.dispose();
  });
}
