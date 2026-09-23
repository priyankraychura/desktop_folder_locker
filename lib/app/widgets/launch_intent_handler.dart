import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../../core/di/core_providers.dart';
import '../../core/theme/app_palette.dart';
import '../../core/widgets/app_keys.dart';
import '../../core/widgets/feedback.dart';
import '../../features/auth/application/session_controller.dart';
import '../../features/items/application/protection_controller.dart';
import '../../features/items/presentation/item_actions.dart';
import '../../features/shell/application/launch_intents.dart';

/// Handles requests from Explorer ("unlock this vault", "lock this
/// folder") one at a time, as soon as the app is ready for them.
///
/// Opening a vault works even while the app is locked (the vault's own
/// password is asked); locking needs the app to be unlocked first.
class LaunchIntentHandler extends ConsumerStatefulWidget {
  const LaunchIntentHandler({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<LaunchIntentHandler> createState() =>
      _LaunchIntentHandlerState();
}

class _LaunchIntentHandlerState extends ConsumerState<LaunchIntentHandler> {
  bool _handling = false;
  final Set<String> _waitingNotified = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _schedule());
  }

  void _schedule() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_pump()));

  Future<void> _pump() async {
    if (_handling || !mounted) return;
    final session = ref.read(sessionControllerProvider);
    final ready =
        session.status == SessionStatus.locked ||
        session.status == SessionStatus.unlocked;
    if (!ready || ref.read(protectionControllerProvider) != null) return;

    final intents = ref.read(launchIntentsProvider.notifier);
    final intent = intents.take(
      (intent) => intent is OpenVaultIntent || session.isUnlocked,
    );
    if (intent == null) {
      _notifyWaiting();
      return;
    }

    _handling = true;
    try {
      await _bringToFront();
      final context = rootNavigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      final actions = ItemActions(context, ref);
      switch (intent) {
        case OpenVaultIntent(:final path):
          await actions.openVault(path);
        case LockPathIntent(:final path):
          await actions.protectPath(path);
      }
    } finally {
      _handling = false;
    }
    _schedule();
  }

  /// Tells the user once that a "lock" request waits for the app unlock.
  void _notifyWaiting() {
    for (final intent in ref.read(launchIntentsProvider)) {
      if (intent is LockPathIntent && _waitingNotified.add(intent.path)) {
        showToast(
          'Unlock the app to lock “${p.basename(intent.path)}”.',
          tone: Tone.info,
        );
      }
    }
  }

  Future<void> _bringToFront() async {
    if (!ref.read(nativeWindowProvider)) return;
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    } on Object {
      // Not critical.
    }
  }

  @override
  Widget build(BuildContext context) {
    ref
      ..listen(launchIntentsProvider, (_, _) => _schedule())
      ..listen(sessionControllerProvider, (_, _) => _schedule())
      ..listen(protectionControllerProvider, (_, next) {
        if (next == null) _schedule();
      });
    return widget.child;
  }
}
