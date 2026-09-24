import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/di/core_providers.dart';
import '../core/storage/app_paths.dart';
import '../core/storage/json_file_store.dart';
import '../engine/crypto/crypto_service.dart';
import '../features/settings/application/settings_controller.dart';
import '../features/settings/data/settings_repository.dart';
import '../features/shell/application/launch_intents.dart';
import '../platform/explorer_folders.dart';
import '../platform/explorer_integration.dart';
import '../platform/single_instance.dart';
import '../platform/system_tray.dart';
import 'app.dart';
import 'app_window.dart';

/// Starts the app.
///
/// 1. Only one copy may run: a second copy (started by Explorer) forwards
///    its arguments to the first one and exits before showing a window.
/// 2. Services are created and injected with Riverpod overrides.
/// 3. The window is configured and shown: the app with its custom title
///    bar, or, when Explorer started it to open a locked item, just the
///    password dialog in a small window.
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

  final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
  final startWithRequest =
      isDesktop && (LaunchIntent.parse(args)?.dialogOnly ?? false);
  final window = isDesktop
      ? NativeAppWindow(startWithRequest: startWithRequest)
      : null;

  final crypto = await CryptoService.create();
  final settings = await SettingsRepository(JsonFileStore(paths.settingsFile))
      .load();
  final container = ProviderContainer(
    overrides: [
      appPathsProvider.overrideWithValue(paths),
      cryptoProvider.overrideWithValue(crypto),
      executablePathProvider.overrideWithValue(Platform.resolvedExecutable),
      nativeWindowProvider.overrideWithValue(isDesktop),
      initialSettingsProvider.overrideWithValue(settings),
      if (Platform.isWindows) ...[
        systemTrayProvider.overrideWithValue(NativeSystemTray()),
        explorerFoldersProvider.overrideWithValue(
          NativeExplorerFolders(
            p.join(
              p.dirname(Platform.resolvedExecutable),
              ExplorerIntegration.pluginFileName,
            ),
          ),
        ),
      ],
      initialWindowStateProvider.overrideWithValue(
        startWithRequest
            ? const WindowState(
                mode: WindowMode.request,
                startedForRequest: true,
              )
            : const WindowState(),
      ),
      if (window != null) appWindowProvider.overrideWithValue(window),
    ],
    // Errors are shown to the user right away instead of being retried.
    retry: (_, _) => null,
  );

  final intents = container.read(launchIntentsProvider.notifier)..addArgs(args);
  instance.messages.listen((forwarded) async {
    intents.addArgs(forwarded);
    await container
        .read(windowStateProvider.notifier)
        .present(LaunchIntent.parse(forwarded));
  });
  instance.deliverPending();

  try {
    container
        .read(settingsControllerProvider.notifier)
        .syncExplorerIntegration();
  } on Object {
    // Explorer integration is optional; the app works without it.
  }

  await window?.start();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const FolderLockerApp(),
    ),
  );
}
