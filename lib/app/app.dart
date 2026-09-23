import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_info.dart';
import '../core/di/core_providers.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/app_keys.dart';
import '../features/items/presentation/widgets/operation_overlay.dart';
import '../features/settings/application/settings_controller.dart';
import 'app_gate.dart';
import 'widgets/activity_detector.dart';
import 'widgets/close_guard.dart';
import 'widgets/launch_intent_handler.dart';

/// The root widget.
class FolderLockerApp extends ConsumerWidget {
  const FolderLockerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(
      settingsControllerProvider.select((settings) => settings.themeMode),
    );
    final nativeWindow = ref.watch(nativeWindowProvider);

    return MaterialApp(
      title: AppInfo.name,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      navigatorKey: rootNavigatorKey,
      scaffoldMessengerKey: rootMessengerKey,
      // App-wide behavior lives above the navigator so it also covers
      // dialogs: activity tracking, close confirmation, Explorer requests
      // and the progress overlay.
      builder: (context, child) => ActivityDetector(
        child: CloseGuard(
          enabled: nativeWindow,
          child: LaunchIntentHandler(
            child: OperationOverlay(child: child ?? const SizedBox.shrink()),
          ),
        ),
      ),
      home: const AppGate(),
    );
  }
}
