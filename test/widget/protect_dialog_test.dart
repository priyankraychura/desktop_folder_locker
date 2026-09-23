import 'package:desktop_folder_locker/core/theme/app_theme.dart';
import 'package:desktop_folder_locker/engine/drive/drive_service.dart';
import 'package:desktop_folder_locker/features/items/domain/protected_item.dart';
import 'package:desktop_folder_locker/features/items/presentation/dialogs/protect_dialog.dart';
import 'package:desktop_folder_locker/platform/access_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';

void main() {
  Future<Future<ProtectChoice?>> open(
    WidgetTester tester, {
    AccessProblem? accessProblem,
    ItemKind kind = ItemKind.folder,
    Future<DokanyStatus>? driveStatus,
  }) async {
    tester.view
      ..physicalSize = const Size(1280, 1100)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await loadTestFonts();
    late Future<ProtectChoice?> result;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = showProtectDialog(
              context,
              path: r'C:\Users\me\Documents\Taxes',
              kind: kind,
              accessProblem: accessProblem,
              driveStatus: driveStatus,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('choosing Block access and hiding', (tester) async {
    final result = await open(tester);
    expect(find.text('Encrypt  ·  recommended'), findsOneWidget);
    expect(find.text('Master password'), findsOneWidget);

    await tester.tap(find.text('Block access'));
    await tester.pumpAndSettle();
    // No password is needed for the quick methods.
    expect(find.text('Master password'), findsNothing);

    await tester.tap(find.text('Also hide it from Explorer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Block and hide'));
    await tester.pumpAndSettle();

    final choice = await result;
    expect(choice?.method, ProtectionMethod.blockAccess);
    expect(choice?.hide, isTrue);
  });

  testWidgets('Hide only always hides', (tester) async {
    final result = await open(tester);
    await tester.tap(find.text('Hide only'));
    await tester.pumpAndSettle();
    expect(find.text('Also hide it from Explorer'), findsNothing);
    await tester.tap(find.widgetWithText(FilledButton, 'Hide'));
    await tester.pumpAndSettle();

    final choice = await result;
    expect(choice?.method, ProtectionMethod.none);
    expect(choice?.hide, isTrue);
  });

  testWidgets('explains why the quick methods are unavailable', (tester) async {
    final result = await open(tester, accessProblem: AccessProblem.notOwner);
    expect(
      find.text('Not available: you don\'t own this item.'),
      findsNWidgets(2),
    );

    // Tapping a disabled option changes nothing.
    await tester.tap(find.text('Read-only'));
    await tester.pumpAndSettle();
    expect(find.text('Master password'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Lock'));
    await tester.pumpAndSettle();
    expect((await result)?.method, ProtectionMethod.encrypt);
  });
  testWidgets('an encrypted folder can open as a drive', (tester) async {
    final result = await open(
      tester,
      driveStatus: Future.value(const DokanyStatus(installed: true)),
    );
    expect(find.text('Open it as'), findsOneWidget);
    await tester.tap(find.text('A drive'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Taxes.flkd'), findsOneWidget);
    expect(find.text('Get Dokany'), findsNothing);

    // Another method and back: the choice is kept.
    await tester.tap(find.text('Block access'));
    await tester.pumpAndSettle();
    expect(find.text('Open it as'), findsNothing);
    await tester.tap(find.text('Encrypt  ·  recommended'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Lock'));
    await tester.pumpAndSettle();
    expect((await result)?.method, ProtectionMethod.drive);
  });

  testWidgets('drives explain what they need', (tester) async {
    await open(
      tester,
      driveStatus: Future.value(
        const DokanyStatus(installed: false, reason: 'Dokany is not installed'),
      ),
    );
    await tester.tap(find.text('A drive'));
    await tester.pumpAndSettle();
    expect(find.text('Get Dokany'), findsOneWidget);
  });

  testWidgets('files and missing helpers get no drive', (tester) async {
    await open(
      tester,
      kind: ItemKind.file,
      driveStatus: Future.value(const DokanyStatus(installed: true)),
    );
    expect(find.text('Open it as'), findsNothing);
  });

  testWidgets('without the helper, drives are off', (tester) async {
    final result = await open(
      tester,
      driveStatus: Future<DokanyStatus>.error(
        const DriveException(DriveErrorCode.helperMissing, 'missing'),
      )..ignore(),
    );
    await tester.tap(find.text('A drive'));
    await tester.pumpAndSettle();
    expect(find.textContaining('the drive helper is missing'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Lock'));
    await tester.pumpAndSettle();
    expect((await result)?.method, ProtectionMethod.encrypt);
  });
}
