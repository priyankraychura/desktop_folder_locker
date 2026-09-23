// Renders the main screens to PNG files, for reviewing the design and for
// the README. Skipped unless SCREENSHOTS_DIR is set:
//
//   SCREENSHOTS_DIR=docs/screenshots SCREENSHOTS_SCALE=1 \
//     flutter test test/visual
//
// SCREENSHOTS_SCALE is the device pixel ratio (default 1.5).
import 'dart:io';
import 'dart:ui' as ui;

import 'package:desktop_folder_locker/engine/drive/drive_service.dart';
import 'package:desktop_folder_locker/features/items/application/items_controller.dart';
import 'package:desktop_folder_locker/features/items/application/protection_controller.dart';
import 'package:desktop_folder_locker/features/items/domain/protected_item.dart';
import 'package:desktop_folder_locker/features/items/presentation/dialogs/protect_dialog.dart';
import 'package:desktop_folder_locker/features/items/presentation/dialogs/unlock_dialog.dart';
import 'package:desktop_folder_locker/features/settings/application/settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/app_harness.dart';

final String? _outputDir = Platform.environment['SCREENSHOTS_DIR'];
final double _scale =
    double.tryParse(Platform.environment['SCREENSHOTS_SCALE'] ?? '') ?? 1.5;

void main() {
  testWidgets('capture screens', (tester) async {
    await loadTestFonts();
    tester.view.physicalSize = const Size(1280, 800) * _scale;
    tester.view.devicePixelRatio = _scale;
    addTearDown(tester.view.reset);

    final harness = (await tester.runAsync(AppHarness.create))!;
    addTearDown(() => tester.runAsync(harness.dispose));
    final boundaryKey = GlobalKey();

    Future<void> capture(String name) async {
      await tester.pump(const Duration(milliseconds: 600));
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: _scale);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(p.join(_outputDir!, '$name.png'));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
      });
    }

    await tester.pumpWidget(
      RepaintBoundary(key: boundaryKey, child: harness.app),
    );
    await settleReal(tester);

    // Onboarding.
    await capture('01_setup');
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Sunflower-Harbor-42');
    await tester.enterText(fields.at(1), 'Sunflower-Harbor-42');
    await tester.enterText(fields.at(2), 'The garden and the boat');
    await tester.pump();
    await capture('02_setup_password');
    await tester.tap(find.text('Continue'));
    await settleReal(tester, rounds: 30);
    await capture('03_recovery_key');
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('Finish setup'));
    await settleReal(tester);
    await capture('04_empty');

    // Some items in different states.
    final protection = harness.container.read(
      protectionControllerProvider.notifier,
    );
    await tester.runAsync(() async {
      Directory createFolder(String name, int files) {
        final dir = Directory(harness.userPath(name))
          ..createSync(recursive: true);
        for (var i = 0; i < files; i++) {
          File(p.join(dir.path, 'file_$i.txt'))
              .writeAsStringSync('x' * (i * 3000));
        }
        return dir;
      }

      await protection.protectNew(
        ProtectRequest(
          path: createFolder('Tax documents 2025', 24).path,
          method: ProtectionMethod.encrypt,
          hide: false,
          passwordMode: PasswordMode.master,
        ),
      );
      await protection.protectNew(
        ProtectRequest(
          path: createFolder('Family photos', 120).path,
          method: ProtectionMethod.encrypt,
          hide: true,
          passwordMode: PasswordMode.custom,
          customPassword: 'another-strong-password',
        ),
      );
      await protection.protectNew(
        ProtectRequest(
          path: createFolder('Game saves', 8).path,
          method: ProtectionMethod.none,
          hide: true,
          passwordMode: PasswordMode.master,
        ),
      );
      await protection.protectNew(
        ProtectRequest(
          path: createFolder('Music library', 60).path,
          method: ProtectionMethod.blockAccess,
          hide: false,
          passwordMode: PasswordMode.master,
        ),
      );
      final project = await protection.protectNew(
        ProtectRequest(
          path: createFolder('Client project', 40).path,
          method: ProtectionMethod.encrypt,
          hide: false,
          passwordMode: PasswordMode.master,
        ),
      );
      await protection.unlock(project);
      final contracts = await protection.protectNew(
        ProtectRequest(
          path: createFolder('Contracts', 30).path,
          method: ProtectionMethod.drive,
          hide: false,
          passwordMode: PasswordMode.master,
        ),
      );
      await protection.unlock(contracts);
    });
    await settleReal(tester);
    await capture('05_items');

    // Protect dialog.
    final context = tester.element(find.text('Protected items').first);
    final newFolder = Directory(harness.userPath('Invoices'))
      ..createSync(recursive: true);
    showProtectDialog(
      context,
      path: newFolder.path,
      kind: ItemKind.folder,
      driveStatus: Future.value(const DokanyStatus(installed: true)),
    ).ignore();
    await tester.pumpAndSettle();
    await capture('06_protect_dialog');
    await tester.tap(find.text('Block access'));
    await tester.pumpAndSettle();
    await capture('07_protect_dialog_block');
    await tester.tap(find.text('Encrypt  ·  recommended'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Its own password'));
    await tester.tap(find.text('Its own password'));
    await tester.pumpAndSettle();
    await capture('07_protect_dialog_custom');
    await tester.tap(find.text('Master password'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('A drive'));
    await tester.tap(find.text('A drive'));
    await tester.pumpAndSettle();
    await capture('07_protect_dialog_drive');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Unlock dialog.
    final locked = harness.container
        .read(itemsControllerProvider.notifier)
        .items
        .firstWhere((item) => item.name == 'Family photos');
    showUnlockDialog(
      context,
      vaultPath: locked.vaultPath!,
      item: locked,
    ).ignore();
    await tester.pumpAndSettle();
    await capture('08_unlock_dialog');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Settings.
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await capture('09_settings');

    // Dark mode.
    await tester.runAsync(
      () => harness.container
          .read(settingsControllerProvider.notifier)
          .setThemeMode(ThemeMode.dark),
    );
    await tester.pumpAndSettle();
    await capture('10_settings_dark');
    await tester.tap(find.text('Protected items'));
    await tester.pumpAndSettle();
    await capture('11_items_dark');

    // Lock screen.
    await tester.tap(find.text('Lock app'));
    await tester.pumpAndSettle();
    await capture('12_lock_dark');
    await tester.runAsync(
      () => harness.container
          .read(settingsControllerProvider.notifier)
          .setThemeMode(ThemeMode.light),
    );
    await tester.pumpAndSettle();
    await capture('13_lock');
    await harness.shutdown(tester);
  }, skip: _outputDir == null);
}
