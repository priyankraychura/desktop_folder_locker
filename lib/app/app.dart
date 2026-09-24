import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_info.dart';
import '../core/di/core_providers.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/app_keys.dart';
import '../features/items/presentation/widgets/operation_overlay.dart';
import '../features/settings/application/settings_controller.dart';
import 'app_gate.dart';
import 'app_window.dart';
import 'widgets/activity_detector.dart';
import 'widgets/close_guard.dart';
import 'widgets/launch_intent_handler.dart';
import 'widgets/tray_handler.dart';

/// The root widget.
class CloakApp extends ConsumerWidget {
  const CloakApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(
      settingsControllerProvider.select((settings) => settings.themeMode),
    );
    final nativeWindow = ref.watch(nativeWindowProvider);
    final requestWindow = ref.watch(
      windowStateProvider.select((state) => state.mode == WindowMode.request),
    );

    return MaterialApp(
      title: AppInfo.name,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      navigatorKey: rootNavigatorKey,
      scaffoldMessengerKey: rootMessengerKey,
      // App-wide behavior lives above the navigator so it also covers
      // dialogs: activity tracking, close confirmation, the tray icon,
      // Explorer requests and the progress overlay.
      builder: (context, child) => ActivityDetector(
        child: CloseGuard(
          enabled: nativeWindow,
          child: TrayHandler(
            nativeWindow: nativeWindow,
            child: LaunchIntentHandler(
              child: OperationOverlay(
                child: _DialogLook(
                  alone: requestWindow,
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      ),
      home: const AppGate(),
    );
  }
}

/// In the small window, a dialog is all there is: no dimming or shadow
/// around it, on a background of its own color (see `AppGate`).
class _DialogLook extends StatelessWidget {
  const _DialogLook({required this.alone, required this.child});

  final bool alone;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!alone) return child;
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        dialogTheme: theme.dialogTheme.copyWith(
          barrierColor: Colors.transparent,
          elevation: 0,
          shadowColor: Colors.transparent,
        ),
      ),
      child: child,
    );
  }
}
