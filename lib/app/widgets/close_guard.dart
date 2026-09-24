import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/constants/app_info.dart';
import '../../core/di/core_providers.dart';
import '../../core/theme/app_palette.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_keys.dart';
import '../../core/widgets/feedback.dart';
import '../../features/items/application/items_controller.dart';
import '../../features/items/application/protection_controller.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/shell/presentation/exit_dialog.dart';
import '../app_window.dart';

/// Intercepts the window's close button. With "Keep running in the
/// notification area" on, the window only hides; otherwise the app exits
/// through [exitApp]. In the small window of an Explorer request, it
/// works like the dialog's Cancel.
class CloseGuard extends ConsumerStatefulWidget {
  const CloseGuard({required this.enabled, required this.child, super.key});

  /// `false` when there is no native window to guard (tests).
  final bool enabled;
  final Widget child;

  @override
  ConsumerState<CloseGuard> createState() => _CloseGuardState();
}

class _CloseGuardState extends ConsumerState<CloseGuard> with WindowListener {
  @override
  void initState() {
    super.initState();
    if (widget.enabled) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
  }

  @override
  void dispose() {
    if (widget.enabled) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() => unawaited(_handleClose());

  Future<void> _handleClose() async {
    if (ref.read(windowStateProvider).mode == WindowMode.request) {
      return _closeRequest();
    }
    final settings = ref.read(settingsControllerProvider);
    final tray = ref.read(systemTrayProvider);
    if (!settings.keepRunningInTray || !tray.isAvailable) {
      return exitApp(ref);
    }
    await windowManager.hide();
    if (!settings.trayHintShown) {
      await tray.notify(
        title: '${AppInfo.name} is still running',
        body:
            'It keeps looking after your unlocked items. Click its icon to '
            'open it, or right-click it and choose Quit.',
      );
      await ref.read(settingsControllerProvider.notifier).markTrayHintShown();
    }
  }

  /// Closes the dialog, which ends the request, unless it's busy. Without
  /// a dialog, the request is over.
  Future<void> _closeRequest() async {
    if (ref.read(protectionControllerProvider) != null) return;
    final navigator = rootNavigatorKey.currentState;
    if (navigator != null && await navigator.maybePop()) return;
    await ref.read(windowStateProvider.notifier).finishRequest();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

bool _exiting = false;

/// Quits the app: waits for running operations and offers to lock
/// unlocked items first (if enabled in Settings).
Future<void> exitApp(WidgetRef ref) async {
  if (_exiting) return;
  _exiting = true;
  try {
    if (ref.read(protectionControllerProvider) != null) {
      showToast(
        'Please wait until the current operation has finished.',
        tone: Tone.warning,
      );
      return;
    }
    final items = ref.read(itemsControllerProvider.notifier);
    final unlocked = [
      for (final item in items.items)
        if (!item.isProtected && items.existsOnDisk(item)) item,
    ];
    final ask = ref.read(settingsControllerProvider).askToLockOnExit;
    final context = rootNavigatorKey.currentContext;
    if (unlocked.isEmpty || !ask || context == null) {
      await windowManager.destroy();
      return;
    }

    final choice = await showExitDialog(context, unlocked: unlocked);
    switch (choice) {
      case null:
        return;
      case ExitChoice.closeAnyway:
        await windowManager.destroy();
      case ExitChoice.lockAllAndClose:
        final left = await ref
            .read(protectionControllerProvider.notifier)
            .lockAllUnlocked();
        if (left.isEmpty) {
          await windowManager.destroy();
          return;
        }
        showToast(
          '${Format.count(left.length, 'item')} could not be locked '
          'automatically (they need their own password, or a file is in '
          'use). Lock them from the list, then close again.',
          tone: Tone.warning,
        );
    }
  } finally {
    _exiting = false;
  }
}
