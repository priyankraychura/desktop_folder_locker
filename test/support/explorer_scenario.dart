import 'dart:io';

import 'package:desktop_folder_locker/app/app_window.dart';
import 'package:desktop_folder_locker/features/auth/application/session_controller.dart';
import 'package:desktop_folder_locker/features/items/application/items_controller.dart';
import 'package:desktop_folder_locker/features/items/application/protection_controller.dart';
import 'package:desktop_folder_locker/features/items/domain/protected_item.dart';
import 'package:desktop_folder_locker/features/settings/domain/app_settings.dart';
import 'package:desktop_folder_locker/features/shell/application/launch_intents.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'app_harness.dart';

/// The master password of [lockedFolder]'s app.
const masterPassword = 'master-password';

/// Explorer started the app to open a locked item.
const startedByExplorer = WindowState(
  mode: WindowMode.request,
  startedForRequest: true,
);

/// The app for a widget test, disposed at the end.
Future<AppHarness> desktopHarness(
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

/// Sets the app up with the folder "Taxes" locked in a vault, and locks
/// the app, as after a restart. Returns the vault.
///
/// The folders named in [unlocked] are locked and unlocked again first,
/// while the app is unlocked: they need the master password to lock again
/// once the app is locked.
Future<String> lockedFolder(
  WidgetTester tester,
  AppHarness harness, {
  ProtectionMethod method = ProtectionMethod.encrypt,
  List<String> unlocked = const [],
}) async {
  late String vault;
  await tester.runAsync(() async {
    final session = harness.container.read(sessionControllerProvider.notifier);
    while (harness.container.read(sessionControllerProvider).status ==
        SessionStatus.loading) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await harness.container.read(itemsControllerProvider.future);
    await session.setUp(password: masterPassword);
    session.finishOnboarding();
    final protection = harness.container.read(
      protectionControllerProvider.notifier,
    );

    Future<ProtectedItem> protect(String name, ProtectionMethod method) {
      final folder = Directory(harness.userPath(name))
        ..createSync(recursive: true);
      File(p.join(folder.path, 'return.pdf')).writeAsStringSync('PDF');
      return protection.protectNew(
        ProtectRequest(
          path: folder.path,
          method: method,
          hide: false,
          passwordMode: PasswordMode.master,
        ),
      );
    }

    vault = (await protect('Taxes', method)).vaultPath!;
    for (final name in unlocked) {
      await protection.unlock(await protect(name, ProtectionMethod.encrypt));
    }
    session.lock();
  });
  return vault;
}

/// Explorer asks the app to open [vault] (a double-click).
void openFromExplorer(AppHarness harness, String vault) => harness.container
    .read(launchIntentsProvider.notifier)
    .addArgs(['--open', vault]);

/// How the app's window shows.
WindowMode windowMode(AppHarness harness) =>
    harness.container.read(windowStateProvider).mode;

/// Unlocks "Taxes" in its password dialog, typing the master password.
Future<void> unlockInDialog(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), masterPassword);
  await tester.tap(find.text('Unlock'));
  await settleReal(tester, rounds: 20);
}
