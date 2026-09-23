import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../core/constants/app_info.dart';
import '../core/di/core_providers.dart';
import '../core/storage/app_paths.dart';
import '../core/storage/json_file_store.dart';
import '../engine/crypto/crypto_service.dart';
import '../features/settings/application/settings_controller.dart';
import '../features/settings/data/settings_repository.dart';
import '../features/shell/application/launch_intents.dart';
import '../platform/single_instance.dart';
import '../platform/system_tray.dart';
import 'app.dart';
import 'window_actions.dart';

/// Starts the app.
///
/// 1. Only one copy may run: a second copy (started by Explorer) forwards
///    its arguments to the first one and exits before showing a window.
/// 2. Services are created and injected with Riverpod overrides.
/// 3. The window is configured (custom title bar) and shown.
Future<void> bootstrap(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final paths = AppPaths.resolve()..ensureExists();
  final instance = await SingleInstance.acquire(
    lockPath: paths.instanceLockFile,
    inboxDir: paths.inboxDir,
  );
  if (instance == null) {
    await SingleInstance.forward(inboxDir: paths.inboxDir, args: args);
    exit(0);
  }

  final crypto = await CryptoService.create();
  final settings = await SettingsRepository(JsonFileStore(paths.settingsFile))
      .load();
  final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  final container = ProviderContainer(
    overrides: [
      appPathsProvider.overrideWithValue(paths),
      cryptoProvider.overrideWithValue(crypto),
      executablePathProvider.overrideWithValue(Platform.resolvedExecutable),
      nativeWindowProvider.overrideWithValue(isDesktop),
      initialSettingsProvider.overrideWithValue(settings),
      if (Platform.isWindows)
        systemTrayProvider.overrideWithValue(NativeSystemTray()),
    ],
    // Errors are shown to the user right away instead of being retried.
    retry: (_, _) => null,
  );

  final intents = container.read(launchIntentsProvider.notifier)..addArgs(args);
  instance.messages.listen((forwarded) async {
    intents.addArgs(forwarded);
    if (isDesktop) await showMainWindow();
  });
  instance.deliverPending();

  try {
    container
        .read(settingsControllerProvider.notifier)
        .syncExplorerIntegration();
  } on Object {
    // Explorer integration is optional; the app works without it.
  }

  if (isDesktop) {
    await windowManager.ensureInitialized();
    unawaited(
      windowManager.waitUntilReadyToShow(
        const WindowOptions(
          title: AppInfo.name,
          size: Size(1180, 760),
          minimumSize: Size(940, 640),
          center: true,
          titleBarStyle: TitleBarStyle.hidden,
          windowButtonVisibility: false,
        ),
        () async {
          await windowManager.show();
          await windowManager.focus();
        },
      ),
    );
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const FolderLockerApp(),
    ),
  );
}
