import 'package:desktop_folder_locker/engine/drive/drive_service.dart';
import 'package:desktop_folder_locker/features/auth/application/session_controller.dart';
import 'package:desktop_folder_locker/features/items/application/items_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';

void main() {
  testWidgets('settings tell whether drives can open, and check again', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await loadTestFonts();
    final harness = (await tester.runAsync(AppHarness.create))!;
    addTearDown(() => tester.runAsync(harness.dispose));
    harness.drives.dokany = const DokanyStatus(
      installed: false,
      reason: 'Dokany is not installed',
    );
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
    });

    await tester.pumpWidget(harness.app);
    await settleReal(tester);
    await tester.tap(find.text('Settings'));
    await settleReal(tester);
    await tester.scrollUntilVisible(
      find.text('Encrypted drives'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Get Dokany'), findsOneWidget);

    // Installed meanwhile.
    harness.drives.dokany = const DokanyStatus(installed: true);
    await tester.tap(find.text('Check again'));
    await settleReal(tester);
    expect(find.text('Get Dokany'), findsNothing);
    expect(find.text('Ready'), findsOneWidget);

    await harness.shutdown(tester);
  });
}
