import 'dart:io';

import 'package:desktop_folder_locker/features/auth/application/session_controller.dart';
import 'package:desktop_folder_locker/features/items/application/items_controller.dart';
import 'package:desktop_folder_locker/features/items/application/protection_controller.dart';
import 'package:desktop_folder_locker/features/items/domain/protected_item.dart';
import 'package:desktop_folder_locker/features/settings/domain/app_settings.dart';
import 'package:desktop_folder_locker/features/shell/application/launch_intents.dart';
import 'package:desktop_folder_locker/platform/access_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';

// What Explorer's plug-in asks for: "Unlock with…" on a blocked folder,
// "Lock with…" on it once it's unlocked. The user chose the action in
// Explorer already, so the app doesn't ask again.
void main() {
  testWidgets('Explorer unlocks a listed item and locks it again', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final harness = (await tester.runAsync(
      () => AppHarness.create(
        // Don't open Explorer windows on the test machine.
        settings: const AppSettings(openAfterUnlock: false),
      ),
    ))!;
    addTearDown(() => tester.runAsync(harness.dispose));

    final music = Directory(harness.userPath('Music'))
      ..createSync(recursive: true);
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
      await harness.container
          .read(protectionControllerProvider.notifier)
          .protectNew(
            ProtectRequest(
              path: music.path,
              method: ProtectionMethod.blockAccess,
              hide: false,
              passwordMode: PasswordMode.master,
            ),
          );
    });
    ProtectedItem item() =>
        harness.container.read(itemsControllerProvider).requireValue.single;
    expect(item().isProtected, isTrue);

    await tester.pumpWidget(harness.app);
    await settleReal(tester);
    final intents = harness.container.read(launchIntentsProvider.notifier);

    intents.addArgs(['--unlock', music.path]);
    await settleReal(tester, rounds: 20);
    expect(find.byType(Dialog), findsNothing);
    expect(item().isProtected, isFalse);
    expect(harness.accessRules.ruleOn(music.path), isNull);

    intents.addArgs(['--lock', music.path]);
    await settleReal(tester, rounds: 20);
    expect(find.byType(Dialog), findsNothing);
    expect(item().isProtected, isTrue);
    expect(harness.accessRules.ruleOn(music.path), AccessRule.blockAll);

    intents.addArgs(['--unlock', harness.userPath('Photos')]);
    await settleUntil(
      tester,
      () => find.text('“Photos” is not in your list.').evaluate().isNotEmpty,
    );
    expect(find.text('“Photos” is not in your list.'), findsOneWidget);

    await harness.shutdown(tester);
  });

  testWidgets('Explorer requests wait until the app is unlocked', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final harness = (await tester.runAsync(AppHarness.create))!;
    addTearDown(() => tester.runAsync(harness.dispose));

    final music = Directory(harness.userPath('Music'))
      ..createSync(recursive: true);
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
      session
        ..finishOnboarding()
        ..lock();
    });

    await tester.pumpWidget(harness.app);
    await settleReal(tester);
    harness.container.read(launchIntentsProvider.notifier)
      ..addArgs(['--unlock', music.path])
      ..addArgs(['--lock', music.path]);
    await settleReal(tester);
    expect(
      find.text('Unlock the app to unlock “Music” and 1 more.'),
      findsOneWidget,
    );
    expect(harness.container.read(launchIntentsProvider), hasLength(2));

    await harness.shutdown(tester);
  });
}
