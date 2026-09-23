import 'dart:io';

import 'package:desktop_folder_locker/app/app.dart';
import 'package:desktop_folder_locker/core/di/core_providers.dart';
import 'package:desktop_folder_locker/core/storage/app_paths.dart';
import 'package:desktop_folder_locker/engine/crypto/crypto_service.dart';
import 'package:desktop_folder_locker/engine/crypto/kdf_params.dart';
import 'package:desktop_folder_locker/features/settings/application/settings_controller.dart';
import 'package:desktop_folder_locker/features/settings/domain/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Runs the real app against a temporary data folder, with cheap password
/// hashing and no native window.
class AppHarness {
  AppHarness._(this.root, this.container);

  final Directory root;
  final ProviderContainer container;

  static Future<AppHarness> create({
    AppSettings settings = const AppSettings(),
  }) async {
    final root = await Directory.systemTemp.createTemp('flk_app_');
    final crypto = await CryptoService.create();
    final paths = AppPaths(p.join(root.path, 'appdata'))..ensureExists();
    final container = ProviderContainer(
      overrides: [
        appPathsProvider.overrideWithValue(paths),
        cryptoProvider.overrideWithValue(crypto),
        kdfPolicyProvider.overrideWithValue(KdfPolicy.fast),
        executablePathProvider.overrideWithValue(
          p.join(root.path, 'app', 'folder_locker.exe'),
        ),
        initialSettingsProvider.overrideWithValue(settings),
        // Temporary folders live under %LOCALAPPDATA% on Windows, which the
        // path guard refuses; tests don't need system folder protection.
        environmentProvider.overrideWithValue(const {}),
      ],
      retry: (_, _) => null,
    );
    return AppHarness._(root, container);
  }

  /// A folder for user files (outside the app data folder).
  String userPath(String name) => p.join(root.path, 'user', name);

  Widget get app => UncontrolledProviderScope(
    container: container,
    child: const FolderLockerApp(),
  );

  /// Removes the app from the tree and disposes providers (stops timers
  /// such as auto-lock). Call at the end of a widget test.
  Future<void> shutdown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump();
  }

  Future<void> dispose() async {
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

/// Lets real I/O and isolates finish, then settles the widget tree.
///
/// Widget tests run in a fake-time zone; work that needs the real event
/// loop (files, isolates) only progresses inside `runAsync`. A chain of such
/// steps needs several rounds.
Future<void> settleReal(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 600));
}

/// Loads real fonts so screenshots show text instead of boxes.
Future<void> loadTestFonts() async {
  final fonts = _materialFontsDir();

  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final file in files) {
      final bytes = File(p.join(fonts, file)).readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }

  const roboto = [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf',
  ];
  await load('Segoe UI', roboto);
  await load('Roboto', roboto);
  await load('Consolas', ['RobotoCondensed-Regular.ttf']);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

/// `<flutter>/bin/cache/artifacts/material_fonts`, found from the test
/// runner executable (which lives inside the Flutter cache).
String _materialFontsDir() {
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.parent.path != dir.path) {
    final candidate = p.join(dir.path, 'artifacts', 'material_fonts');
    if (Directory(candidate).existsSync()) return candidate;
    dir = dir.parent;
  }
  final root = Platform.environment['FLUTTER_ROOT'] ?? '';
  return p.join(root, 'bin', 'cache', 'artifacts', 'material_fonts');
}
