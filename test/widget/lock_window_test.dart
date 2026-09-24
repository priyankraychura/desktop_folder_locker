import 'package:desktop_folder_locker/app/app_window.dart';
import 'package:desktop_folder_locker/core/widgets/window_title_bar.dart';
import 'package:desktop_folder_locker/features/auth/application/session_controller.dart';
import 'package:desktop_folder_locker/features/auth/presentation/lock_screen.dart';
import 'package:desktop_folder_locker/features/shell/presentation/home_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';
import '../support/explorer_scenario.dart';

// The lock screen is compact, the size of a dialog: unlocking grows the
// window to the app, and locking shrinks it again.
void main() {
  bool compact(AppHarness app) => app.container.read(compactWindowProvider);

  Future<void> unlockApp(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField), masterPassword);
    await tester.tap(find.text('Unlock'));
    await settleReal(tester);
  }

  testWidgets('unlocking grows the window; locking shrinks it', (tester) async {
    final app = await desktopHarness(tester);
    await lockedFolder(tester, app);
    await tester.pumpWidget(app.app);
    await settleReal(tester);
    expect(find.byType(LockScreen), findsOneWidget);
    expect(compact(app), isTrue);
    expect(
      find.byType(WindowTitleBar),
      findsNothing,
      reason: 'Windows draws the title bar of a compact window',
    );

    await unlockApp(tester);
    expect(find.byType(HomeShell), findsOneWidget);
    expect(compact(app), isFalse);
    expect(app.window.look, 'app');
    expect(app.window.visible, isTrue);

    app.container.read(sessionControllerProvider.notifier).lock();
    await settleReal(tester);
    expect(find.byType(LockScreen), findsOneWidget);
    expect(app.window.look, 'compact');

    await app.shutdown(tester);
  });

  testWidgets('hidden, the window changes when it shows again', (tester) async {
    final app = await desktopHarness(tester);
    await lockedFolder(tester, app, unlocked: ['Photos']);
    await tester.pumpWidget(app.app);
    await settleReal(tester);
    await unlockApp(tester);
    final window = app.container.read(windowStateProvider.notifier);
    await tester.runAsync(window.toBackground);

    // It locks itself in the background, for example after a while.
    app.container.read(sessionControllerProvider.notifier).lock();
    await settleReal(tester);
    expect(app.window.look, 'app', reason: 'hidden, it stays as it was');
    expect(app.window.ended, isFalse, reason: '“Photos” is unlocked');

    app.tray.select('open');
    await settleReal(tester);
    expect(app.window.visible, isTrue);
    expect(app.window.look, 'compact');
    expect(find.byType(LockScreen), findsOneWidget);

    await app.shutdown(tester);
  });
}
