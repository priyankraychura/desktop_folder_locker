import 'dart:io';

import 'package:desktop_folder_locker/app/app_window.dart';
import 'package:desktop_folder_locker/features/auth/presentation/lock_screen.dart';
import 'package:desktop_folder_locker/features/items/domain/protected_item.dart';
import 'package:desktop_folder_locker/features/settings/domain/app_settings.dart';
import 'package:desktop_folder_locker/features/setup/presentation/setup_page.dart';
import 'package:desktop_folder_locker/features/shell/presentation/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';
import '../support/explorer_scenario.dart';

// Opening a locked item from Explorer: when the app isn't open, only its
// password dialog shows, in a small window that goes away afterwards.
void main() {
  testWidgets('a locked item opens with just its password dialog', (
    tester,
  ) async {
    final app = await desktopHarness(tester, initialWindow: startedByExplorer);
    final vault = await lockedFolder(tester, app);
    openFromExplorer(app, vault);

    await tester.pumpWidget(app.app);
    await settleReal(tester);
    expect(find.text('Unlock “Taxes”'), findsOneWidget);
    expect(find.byType(LockScreen), findsNothing);
    expect(find.byType(HomeShell), findsNothing);
    expect(app.window.look, 'compact');
    expect(app.tray.visible, isFalse, reason: 'the app may quit right after');

    await unlockInDialog(tester);
    final folder = app.userPath('Taxes');
    expect(Directory(folder).existsSync(), isTrue);
    expect(app.started.last.last, folder, reason: 'Explorer shows it');

    // The window goes. The app stays in the notification area, to remind
    // about the unlocked folder.
    expect(app.window.visible, isFalse);
    expect(app.window.ended, isFalse);
    expect(app.tray.visible, isTrue);
    expect(windowMode(app), WindowMode.main);

    await app.shutdown(tester);
  });

  testWidgets('cancelling ends the app that Explorer started for it', (
    tester,
  ) async {
    final app = await desktopHarness(tester, initialWindow: startedByExplorer);
    final vault = await lockedFolder(tester, app);
    openFromExplorer(app, vault);

    await tester.pumpWidget(app.app);
    await settleReal(tester);
    await tester.tap(find.text('Cancel'));
    await settleReal(tester);
    await settleUntil(tester, () => app.window.ended);
    expect(app.window.ended, isTrue);
    expect(app.tray.visible, isFalse, reason: 'not even for a moment');
    expect(File(vault).existsSync(), isTrue, reason: 'still locked');

    await app.shutdown(tester);
  });

  testWidgets('a vault that is gone says so, then the app ends', (
    tester,
  ) async {
    final app = await desktopHarness(tester, initialWindow: startedByExplorer);
    await lockedFolder(tester, app);
    openFromExplorer(app, app.userPath('Moved.flk'));

    await tester.pumpWidget(app.app);
    await settleReal(tester);
    expect(find.text('“Moved.flk” is gone'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await settleReal(tester);
    await settleUntil(tester, () => app.window.ended);
    expect(app.window.ended, isTrue);

    await app.shutdown(tester);
  });

  testWidgets('from the notification area, just the dialog; the app goes '
      'back there', (tester) async {
    final app = await desktopHarness(tester, windowVisible: false);
    // It runs in the background for "Photos", which is unlocked.
    final vault = await lockedFolder(tester, app, unlocked: ['Photos']);
    await tester.pumpWidget(app.app);
    await settleReal(tester);

    openFromExplorer(app, vault);
    await settleReal(tester);
    expect(find.text('Unlock “Taxes”'), findsOneWidget);
    expect(find.byType(LockScreen), findsNothing);
    expect(app.window.look, 'compact');

    await tester.tap(find.text('Cancel'));
    await settleReal(tester);
    expect(app.window.visible, isFalse);
    expect(app.window.ended, isFalse, reason: '“Photos” is unlocked');
    expect(windowMode(app), WindowMode.main);

    await app.shutdown(tester);
  });

  testWidgets('with the app open, the dialog shows over it', (tester) async {
    final app = await desktopHarness(tester);
    final vault = await lockedFolder(tester, app);
    await tester.pumpWidget(app.app);
    await settleReal(tester);

    openFromExplorer(app, vault);
    await settleReal(tester);
    expect(find.text('Unlock “Taxes”'), findsOneWidget);
    expect(find.byType(LockScreen), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await settleReal(tester);
    expect(app.window.visible, isTrue);
    expect(app.window.ended, isFalse);
    expect(windowMode(app), WindowMode.main);

    await app.shutdown(tester);
  });

  group('without the notification-area icon', () {
    const noIcon = AppSettings(keepRunningInTray: false);

    // With "Ask to lock when closed" on, it waits for the folder's window
    // to close (see lock_again_test.dart).
    testWidgets('an unlocked folder doesn\'t keep the app if nothing asks', (
      tester,
    ) async {
      final app = await desktopHarness(
        tester,
        initialWindow: startedByExplorer,
        settings: const AppSettings(
          keepRunningInTray: false,
          askToLockWhenClosed: false,
        ),
      );
      final vault = await lockedFolder(tester, app);
      openFromExplorer(app, vault);

      await tester.pumpWidget(app.app);
      await settleReal(tester);
      await unlockInDialog(tester);
      expect(Directory(app.userPath('Taxes')).existsSync(), isTrue);
      await settleUntil(tester, () => app.window.ended);
      expect(app.window.ended, isTrue, reason: 'nothing to remind from');

      await app.shutdown(tester);
    });

    testWidgets('an open drive shows the app, which serves it', (tester) async {
      final app = await desktopHarness(
        tester,
        initialWindow: startedByExplorer,
        settings: noIcon,
      );
      final vault = await lockedFolder(
        tester,
        app,
        method: ProtectionMethod.drive,
      );
      openFromExplorer(app, vault);

      await tester.pumpWidget(app.app);
      await settleReal(tester);
      await tester.enterText(find.byType(TextField), masterPassword);
      await tester.tap(find.text('Open'));
      await settleUntil(
        tester,
        () =>
            app.drives.isMounted(vault) &&
            windowMode(app) == WindowMode.main &&
            find.byType(LockScreen).evaluate().isNotEmpty,
      );
      expect(app.drives.isMounted(vault), isTrue);

      // Hidden, it could only be found in Task Manager. The app is locked:
      // its lock screen shows, compact.
      expect(app.window.ended, isFalse);
      expect(app.window.visible, isTrue);
      expect(app.window.look, 'compact');
      expect(windowMode(app), WindowMode.main);
      expect(find.byType(LockScreen), findsOneWidget);

      await app.shutdown(tester);
    });
  });

  testWidgets('before the app is set up, it shows the app', (tester) async {
    final app = await desktopHarness(tester, initialWindow: startedByExplorer);
    openFromExplorer(app, app.userPath('Taxes.flk'));

    await tester.pumpWidget(app.app);
    await settleReal(tester);
    expect(windowMode(app), WindowMode.main);
    expect(app.window.look, 'app');
    expect(find.byType(SetupPage), findsOneWidget);

    await app.shutdown(tester);
  });
}
