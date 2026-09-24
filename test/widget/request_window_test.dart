import 'dart:io';

import 'package:desktop_folder_locker/app/app_window.dart';
import 'package:desktop_folder_locker/features/auth/application/session_controller.dart';
import 'package:desktop_folder_locker/features/auth/presentation/lock_screen.dart';
import 'package:desktop_folder_locker/features/items/application/items_controller.dart';
import 'package:desktop_folder_locker/features/items/application/protection_controller.dart';
import 'package:desktop_folder_locker/features/items/domain/protected_item.dart';
import 'package:desktop_folder_locker/features/settings/domain/app_settings.dart';
import 'package:desktop_folder_locker/features/setup/presentation/setup_page.dart';
import 'package:desktop_folder_locker/features/shell/application/launch_intents.dart';
import 'package:desktop_folder_locker/features/shell/presentation/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/app_harness.dart';

// Opening a locked item from Explorer: when the app isn't open, only its
// password dialog shows, in a small window that goes away afterwards.
void main() {
  const password = 'master-password';
  const startedByExplorer = WindowState(
    mode: WindowMode.request,
    startedForRequest: true,
  );

  Future<AppHarness> harness(
    WidgetTester tester, {
    WindowState initialWindow = const WindowState(),
    bool windowVisible = true,
    AppSettings settings = const AppSettings(),
  }) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final harness = (await tester.runAsync(
      () => AppHarness.create(
        initialWindow: initialWindow,
        windowVisible: windowVisible,
        settings: settings,
      ),
    ))!;
    addTearDown(() => tester.runAsync(harness.dispose));
    return harness;
  }

  /// A set-up app with the folder "Taxes" locked in a vault, and the app
  /// itself locked, as after a restart. Returns the vault.
  Future<String> lockedFolder(
    WidgetTester tester,
    AppHarness harness, {
    ProtectionMethod method = ProtectionMethod.encrypt,
  }) async {
    late String vault;
    await tester.runAsync(() async {
      final session = harness.container.read(
        sessionControllerProvider.notifier,
      );
      while (harness.container.read(sessionControllerProvider).status ==
          SessionStatus.loading) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await harness.container.read(itemsControllerProvider.future);
      await session.setUp(password: password);
      session.finishOnboarding();
      final folder = Directory(harness.userPath('Taxes'))
        ..createSync(recursive: true);
      File(p.join(folder.path, 'return.pdf')).writeAsStringSync('PDF');
      final item = await harness.container
          .read(protectionControllerProvider.notifier)
          .protectNew(
            ProtectRequest(
              path: folder.path,
              method: method,
              hide: false,
              passwordMode: PasswordMode.master,
            ),
          );
      vault = item.vaultPath!;
      session.lock();
    });
    return vault;
  }

  void open(AppHarness harness, String vault) => harness.container
      .read(launchIntentsProvider.notifier)
      .addArgs(['--open', vault]);

  WindowMode mode(AppHarness harness) =>
      harness.container.read(windowStateProvider).mode;

  testWidgets('a locked item opens with just its password dialog', (
    tester,
  ) async {
    final app = await harness(tester, initialWindow: startedByExplorer);
    final vault = await lockedFolder(tester, app);
    open(app, vault);

    await tester.pumpWidget(app.app);
    await settleReal(tester);
    expect(find.text('Unlock “Taxes”'), findsOneWidget);
    expect(find.byType(LockScreen), findsNothing);
    expect(find.byType(HomeShell), findsNothing);
    expect(app.window.look, 'request');
    expect(app.tray.visible, isFalse, reason: 'the app may quit right after');

    await tester.enterText(find.byType(TextField), password);
    await tester.tap(find.text('Unlock'));
    await settleReal(tester, rounds: 20);
    final folder = app.userPath('Taxes');
    expect(Directory(folder).existsSync(), isTrue);
    expect(app.started.last.last, folder, reason: 'Explorer shows it');

    // The window goes. The app stays in the notification area, to remind
    // about the unlocked folder.
    expect(app.window.visible, isFalse);
    expect(app.window.ended, isFalse);
    expect(app.tray.visible, isTrue);
    expect(mode(app), WindowMode.main);

    await app.shutdown(tester);
  });

  testWidgets('cancelling ends the app that Explorer started for it', (
    tester,
  ) async {
    final app = await harness(tester, initialWindow: startedByExplorer);
    final vault = await lockedFolder(tester, app);
    open(app, vault);

    await tester.pumpWidget(app.app);
    await settleReal(tester);
    await tester.tap(find.text('Cancel'));
    await settleReal(tester);
    expect(app.window.ended, isTrue);
    expect(app.tray.visible, isFalse, reason: 'not even for a moment');
    expect(File(vault).existsSync(), isTrue, reason: 'still locked');

    await app.shutdown(tester);
  });

  testWidgets('a vault that is gone says so, then the app ends', (
    tester,
  ) async {
    final app = await harness(tester, initialWindow: startedByExplorer);
    await lockedFolder(tester, app);
    open(app, app.userPath('Moved.flk'));

    await tester.pumpWidget(app.app);
    await settleReal(tester);
    expect(find.text('“Moved.flk” is gone'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await settleReal(tester);
    expect(app.window.ended, isTrue);

    await app.shutdown(tester);
  });

  testWidgets('from the notification area, just the dialog; the app stays', (
    tester,
  ) async {
    final app = await harness(tester, windowVisible: false);
    final vault = await lockedFolder(tester, app);
    await tester.pumpWidget(app.app);
    await settleReal(tester);

    open(app, vault);
    await settleReal(tester);
    expect(find.text('Unlock “Taxes”'), findsOneWidget);
    expect(find.byType(LockScreen), findsNothing);
    expect(app.window.look, 'request');

    await tester.tap(find.text('Cancel'));
    await settleReal(tester);
    expect(app.window.visible, isFalse);
    expect(app.window.ended, isFalse, reason: 'it ran before');
    expect(mode(app), WindowMode.main);

    await app.shutdown(tester);
  });

  testWidgets('with the app open, the dialog shows over it', (tester) async {
    final app = await harness(tester);
    final vault = await lockedFolder(tester, app);
    await tester.pumpWidget(app.app);
    await settleReal(tester);

    open(app, vault);
    await settleReal(tester);
    expect(find.text('Unlock “Taxes”'), findsOneWidget);
    expect(find.byType(LockScreen), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await settleReal(tester);
    expect(app.window.visible, isTrue);
    expect(app.window.ended, isFalse);
    expect(mode(app), WindowMode.main);

    await app.shutdown(tester);
  });

  group('without the notification-area icon', () {
    const noIcon = AppSettings(keepRunningInTray: false);

    testWidgets('an unlocked folder doesn\'t keep the app', (tester) async {
      final app = await harness(
        tester,
        initialWindow: startedByExplorer,
        settings: noIcon,
      );
      final vault = await lockedFolder(tester, app);
      open(app, vault);

      await tester.pumpWidget(app.app);
      await settleReal(tester);
      await tester.enterText(find.byType(TextField), password);
      await tester.tap(find.text('Unlock'));
      await settleReal(tester, rounds: 20);
      expect(Directory(app.userPath('Taxes')).existsSync(), isTrue);
      expect(app.window.ended, isTrue, reason: 'nothing to remind from');

      await app.shutdown(tester);
    });

    testWidgets('an open drive shows the app, which serves it', (tester) async {
      final app = await harness(
        tester,
        initialWindow: startedByExplorer,
        settings: noIcon,
      );
      final vault = await lockedFolder(
        tester,
        app,
        method: ProtectionMethod.drive,
      );
      open(app, vault);

      await tester.pumpWidget(app.app);
      await settleReal(tester);
      await tester.enterText(find.byType(TextField), password);
      await tester.tap(find.text('Open'));
      await settleReal(tester, rounds: 20);
      expect(app.drives.isMounted(vault), isTrue);

      // Hidden, it could only be found in Task Manager.
      expect(app.window.ended, isFalse);
      expect(app.window.visible, isTrue);
      expect(app.window.look, 'main');
      expect(mode(app), WindowMode.main);
      expect(find.byType(LockScreen), findsOneWidget);

      await app.shutdown(tester);
    });
  });

  testWidgets('before the app is set up, it shows the app', (tester) async {
    final app = await harness(tester, initialWindow: startedByExplorer);
    open(app, app.userPath('Taxes.flk'));

    await tester.pumpWidget(app.app);
    await settleReal(tester);
    expect(mode(app), WindowMode.main);
    expect(app.window.look, 'main');
    expect(find.byType(SetupPage), findsOneWidget);

    await app.shutdown(tester);
  });
}
