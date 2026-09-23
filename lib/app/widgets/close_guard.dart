import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/theme/app_palette.dart';
import '../../core/widgets/app_keys.dart';
import '../../core/widgets/feedback.dart';
import '../../features/items/application/items_controller.dart';
import '../../features/items/application/protection_controller.dart';
import '../../features/items/domain/protected_item.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/shell/presentation/exit_dialog.dart';

/// Intercepts the window's close button: waits for running operations and
/// offers to lock unlocked items first.
class CloseGuard extends ConsumerStatefulWidget {
  const CloseGuard({required this.enabled, required this.child, super.key});

  /// `false` when there is no native window to guard (tests).
  final bool enabled;
  final Widget child;

  @override
  ConsumerState<CloseGuard> createState() => _CloseGuardState();
}

class _CloseGuardState extends ConsumerState<CloseGuard> with WindowListener {
  bool _closing = false;

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
    if (_closing) return;
    _closing = true;
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
          if (await _lockAll(unlocked)) await windowManager.destroy();
      }
    } finally {
      _closing = false;
    }
  }

  /// Returns `true` when every item was locked.
  Future<bool> _lockAll(List<ProtectedItem> unlocked) async {
    final controller = ref.read(protectionControllerProvider.notifier);
    var notLocked = 0;
    for (final item in unlocked) {
      if (controller.lockRequirement(item) != LockRequirement.none) {
        notLocked++;
        continue;
      }
      try {
        await controller.lockAgain(item);
      } on Object {
        notLocked++;
      }
    }
    if (notLocked > 0) {
      showToast(
        '$notLocked item(s) could not be locked automatically (they need '
        'their own password, or a file is in use). Lock them from the list, '
        'then close again.',
        tone: Tone.warning,
      );
    }
    return notLocked == 0;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
