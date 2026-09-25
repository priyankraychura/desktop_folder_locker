import 'dart:io';

import 'package:desktop_folder_locker/features/auth/application/session_controller.dart';
import 'package:desktop_folder_locker/features/items/application/items_controller.dart';
import 'package:desktop_folder_locker/features/items/application/protection_controller.dart';
import 'package:desktop_folder_locker/features/items/domain/protected_item.dart';
import 'package:desktop_folder_locker/features/settings/domain/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/app_harness.dart';

void main() {
  testWidgets('unlock, lock again and remove an item from its card', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await loadTestFonts();
    final harness = (await tester.runAsync(
      () => AppHarness.create(
        // Don't open Explorer windows on the test machine.
        settings: const AppSettings(openAfterUnlock: false),
      ),
    ))!;
    addTearDown(() => tester.runAsync(harness.dispose));

    // Set up the app and one locked folder without going through the UI.
    late String folderPath;
    await tester.runAsync(() async {
      final session = harness.container.read(
        sessionControllerProvider.notifier,
      );
      while (harness.container.read(sessionControllerProvider).status ==
          SessionStatus.loading) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await harness.container.read(itemsControllerProvider.future);
      await session.setUp(password: 'master-password');
      session.finishOnboarding();

      final folder = Directory(harness.userPath('Taxes'))
        ..createSync(recursive: true);
      File(p.join(folder.path, 'return.pdf')).writeAsStringSync('PDF');
      folderPath = folder.path;
      await harness.container
          .read(protectionControllerProvider.notifier)
          .protectNew(
            ProtectRequest(
              path: folder.path,
              method: ProtectionMethod.encrypt,
              hide: false,
              passwordMode: PasswordMode.master,
            ),
          );
    });

    await tester.pumpWidget(harness.app);
    await settleReal(tester);
    expect(find.text('Taxes'), findsOneWidget);
    expect(find.text('Locked'), findsWidgets);

    // The card's button, once it can be pressed: it waits while an
    // operation finishes (the Windows runners can be slow).
    bool canPress(String label) {
      final button = find.widgetWithText(FilledButton, label);
      return button.evaluate().isNotEmpty &&
          tester.widget<FilledButton>(button).onPressed != null;
    }

    // The app is unlocked, so no password is asked.
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await settleReal(tester, rounds: 20);
    await settleUntil(tester, () => canPress('Lock'));
    expect(Directory(folderPath).existsSync(), isTrue);
    expect(find.text('Unlocked'), findsWidgets);

    await tester.tap(find.widgetWithText(FilledButton, 'Lock'));
    await settleReal(tester, rounds: 20);
    await settleUntil(tester, () => canPress('Unlock'));
    expect(Directory(folderPath).existsSync(), isFalse);
    expect(File('$folderPath.flk').existsSync(), isTrue);

    // "Remove from list" is disabled while the item is locked.
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    final remove = find.widgetWithText(MenuItemButton, 'Remove from list');
    expect(tester.widget<MenuItemButton>(remove).onPressed, isNull);
    await tester.tapAt(const Offset(10, 790));
    await tester.pumpAndSettle();

    // Unlock again, then remove it (the folder stays where it is).
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await settleReal(tester, rounds: 20);
    await settleUntil(tester, () => canPress('Lock'));
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, 'Remove from list'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await settleReal(tester);

    expect(find.text('Nothing protected yet'), findsOneWidget);
    expect(Directory(folderPath).existsSync(), isTrue);

    await harness.shutdown(tester);
  });
  testWidgets('a drive item opens, locks and becomes a folder again', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await loadTestFonts();
    final harness = (await tester.runAsync(
      () => AppHarness.create(
        settings: const AppSettings(openAfterUnlock: false),
      ),
    ))!;
    addTearDown(() => tester.runAsync(harness.dispose));

    late ProtectedItem item;
    await tester.runAsync(() async {
      final session = harness.container.read(
        sessionControllerProvider.notifier,
      );
      while (harness.container.read(sessionControllerProvider).status ==
          SessionStatus.loading) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await harness.container.read(itemsControllerProvider.future);
      await session.setUp(password: 'master-password');
      session.finishOnboarding();

      final folder = Directory(harness.userPath('Photos'))
        ..createSync(recursive: true);
      File(p.join(folder.path, 'cat.jpg')).writeAsStringSync('meow');
      item = await harness.container
          .read(protectionControllerProvider.notifier)
          .protectNew(
            ProtectRequest(
              path: folder.path,
              method: ProtectionMethod.drive,
              hide: false,
              passwordMode: PasswordMode.master,
            ),
          );
    });

    await tester.pumpWidget(harness.app);
    await settleReal(tester);
    expect(find.text('Photos'), findsOneWidget);
    expect(find.text('Drive'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Open'));
    await settleReal(tester, rounds: 20);
    expect(find.text(r'Open as V:'), findsOneWidget);
    expect(harness.drives.isMounted(item.vaultPath!), isTrue);

    // A program has a file open on the drive: closing it asks first.
    harness.drives.busy.add(item.vaultPath!);
    await tester.tap(find.widgetWithText(FilledButton, 'Lock'));
    await settleReal(tester, rounds: 20);
    expect(find.text('Files on V: are still open'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await settleReal(tester);
    expect(find.text(r'Open as V:'), findsOneWidget);
    expect(harness.drives.isMounted(item.vaultPath!), isTrue);

    await tester.tap(find.widgetWithText(FilledButton, 'Lock'));
    await settleReal(tester, rounds: 20);
    await tester.tap(find.widgetWithText(FilledButton, 'Close anyway'));
    await settleReal(tester, rounds: 20);
    expect(find.text('Locked'), findsWidgets);
    expect(harness.drives.isMounted(item.vaultPath!), isFalse);

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(MenuItemButton, 'Decrypt to a folder…'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Decrypt'));
    await settleReal(tester, rounds: 20);

    expect(find.text('Unlocked'), findsWidgets);
    expect(File(p.join(item.itemPath, 'cat.jpg')).readAsStringSync(), 'meow');
    expect(Directory(item.vaultPath!).existsSync(), isFalse);

    await harness.shutdown(tester);
  });
}
