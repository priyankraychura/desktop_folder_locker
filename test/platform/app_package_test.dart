import 'dart:io';

import 'package:desktop_folder_locker/core/di/core_providers.dart';
import 'package:desktop_folder_locker/core/storage/app_paths.dart';
import 'package:desktop_folder_locker/features/settings/application/settings_controller.dart';
import 'package:desktop_folder_locker/features/settings/data/settings_repository.dart';
import 'package:desktop_folder_locker/platform/app_package.dart';
import 'package:desktop_folder_locker/platform/explorer_integration.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records what the app asks of the registry, and writes none of it.
class _RecordingIntegration implements ExplorerIntegration {
  final List<String> calls = [];

  @override
  String get executablePath => r'C:\Cloak\cloak.exe';

  @override
  String get classesPath => ExplorerIntegration.defaultClassesPath;

  @override
  String get pluginPath => r'C:\Cloak\cloak_shell.dll';

  @override
  bool get hasPlugin => true;

  /// Out of date, so a start of the Setup version registers again.
  @override
  bool get isRegistered => false;

  @override
  void register() => calls.add('register');

  @override
  void unregister() => calls.add('unregister');
}

void main() {
  group('AppPackage', () {
    test('tells the Store package from the Windows 11 menu package', () {
      expect(
        AppPackage.isStorePackage(
          'PriyankRaychura.Cloak_1.2.0.0_x64__8wekyb3d8bbwe',
        ),
        isTrue,
      );
      expect(
        AppPackage.isStorePackage(
          'Cloak.ExplorerMenu_1.2.0.0_x64__8wekyb3d8bbwe',
        ),
        isFalse,
      );
    });

    test('is the Setup version outside a package', () {
      // The tests never run from a package.
      expect(AppPackage.isStoreApp, isFalse);
    });
  });

  group('Explorer integration setting', () {
    late Directory root;
    late _RecordingIntegration integration;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('flk_store_');
      integration = _RecordingIntegration();
    });

    tearDown(() => root.delete(recursive: true));

    ProviderContainer containerFor({required bool store}) {
      final container = ProviderContainer(
        overrides: [
          appPathsProvider.overrideWithValue(
            AppPaths(root.path)..ensureExists(),
          ),
          storeAppProvider.overrideWithValue(store),
          explorerIntegrationProvider.overrideWithValue(integration),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('the Setup version writes the entries', () async {
      final container = containerFor(store: false);
      final controller = container.read(settingsControllerProvider.notifier);

      await controller.setExplorerIntegration(false);
      await controller.setExplorerIntegration(true);

      expect(integration.calls, ['unregister', 'register']);
    });

    test('the Store version only saves the setting', () async {
      final container = containerFor(store: true);
      final controller = container.read(settingsControllerProvider.notifier);

      await controller.setExplorerIntegration(false);
      controller.syncExplorerIntegration();

      expect(integration.calls, isEmpty);
      expect(
        container.read(settingsControllerProvider).explorerIntegration,
        isFalse,
      );
      // The Explorer plug-in reads it from the file.
      final saved = await container.read(settingsRepositoryProvider).load();
      expect(saved.explorerIntegration, isFalse);

      await controller.setExplorerIntegration(true);
      controller.syncExplorerIntegration();
      expect(integration.calls, isEmpty);
    });
  });
}
