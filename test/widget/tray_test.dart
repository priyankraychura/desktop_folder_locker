import 'dart:io';

import 'package:desktop_folder_locker/features/auth/application/session_controller.dart';
import 'package:desktop_folder_locker/features/items/application/items_controller.dart';
import 'package:desktop_folder_locker/features/items/application/protection_controller.dart';
import 'package:desktop_folder_locker/features/items/domain/protected_item.dart';
import 'package:desktop_folder_locker/features/settings/domain/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets('the tray icon follows the items and runs its menu', (
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
      final folder = Directory(harness.userPath('Projects'))
        ..createSync(recursive: true);
      final protection = harness.container.read(
        protectionControllerProvider.notifier,
      );
      final protected = await protection.protectNew(
        ProtectRequest(
          path: folder.path,
          method: ProtectionMethod.blockAccess,
          hide: false,
          passwordMode: PasswordMode.master,
        ),
      );
      item = (await protection.unlock(protected)).item;
    });

    await tester.pumpWidget(harness.app);
    await settleReal(tester);

    final tray = harness.tray;
    expect(tray.last.attention, isTrue);
    expect(tray.last.tooltip, contains('1 item unlocked'));
    expect(
      tray.last.menu.firstWhere((entry) => entry.id == 'lockAll').enabled,
      isTrue,
    );

    tray.select('lockAll');
    await settleReal(tester);
    expect(
      harness.container
          .read(itemsControllerProvider.notifier)
          .byId(item.id)!
          .isProtected,
      isTrue,
    );
    expect(tray.last.attention, isFalse);
    expect(tray.last.tooltip, contains('everything is locked'));

    tray.select('lockApp');
    await settleReal(tester);
    expect(
      harness.container.read(sessionControllerProvider).isUnlocked,
      isFalse,
    );
    expect(
      tray.last.menu.firstWhere((entry) => entry.id == 'lockApp').enabled,
      isFalse,
    );

    await harness.shutdown(tester);
  });
}
