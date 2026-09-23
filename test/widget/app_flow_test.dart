import 'package:desktop_folder_locker/features/auth/application/session_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';

void main() {
  setUp(() {
    // A roomy desktop-sized window.
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first
      ..physicalSize = const Size(1280, 800)
      ..devicePixelRatio = 1;
  });

  testWidgets(
    'first run: create password, save recovery key, lock and unlock',
    (tester) async {
      addTearDown(tester.view.reset);
      await loadTestFonts();
      final harness = (await tester.runAsync(AppHarness.create))!;
      addTearDown(() => tester.runAsync(harness.dispose));

      await tester.pumpWidget(harness.app);
      await settleReal(tester);
      expect(find.text('Create your master password'), findsOneWidget);

      // Validation.
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(find.text('Use at least 8 characters.'), findsOneWidget);

      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Harbor-Sunflower-42');
      await tester.enterText(fields.at(1), 'Harbor-Sunflower-41');
      await tester.tap(find.text('Continue'));
      await tester.pump();
      expect(find.text('The passwords don\'t match.'), findsOneWidget);

      await tester.enterText(fields.at(1), 'Harbor-Sunflower-42');
      await tester.enterText(fields.at(2), 'garden');
      await tester.tap(find.text('Continue'));
      await settleReal(tester, rounds: 25);

      // Recovery key step.
      expect(find.text('Save your recovery key'), findsOneWidget);
      expect(
        harness.container.read(sessionControllerProvider).status,
        SessionStatus.onboarding,
      );
      final finish = find.widgetWithText(FilledButton, 'Finish setup');
      expect(tester.widget<FilledButton>(finish).onPressed, isNull);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(finish);
      await settleReal(tester);

      // Main window, empty list.
      expect(find.text('Nothing protected yet'), findsOneWidget);

      // Lock and unlock the app.
      await tester.tap(find.text('Lock app'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);

      await tester.tap(find.text('Show hint'));
      await tester.pumpAndSettle();
      expect(find.text('garden'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'wrong-password');
      await tester.tap(find.text('Unlock'));
      await settleReal(tester, rounds: 20);
      expect(find.text('That password is not correct.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Harbor-Sunflower-42');
      await tester.tap(find.text('Unlock'));
      await settleReal(tester, rounds: 20);
      expect(find.text('Protected items'), findsWidgets);

      await harness.shutdown(tester);
    },
  );
}
