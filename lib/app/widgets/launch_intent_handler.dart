import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../core/theme/app_palette.dart';
import '../../core/widgets/app_keys.dart';
import '../../core/widgets/feedback.dart';
import '../../features/auth/application/session_controller.dart';
import '../../features/items/application/folder_window_watcher.dart';
import '../../features/items/application/protection_controller.dart';
import '../../features/items/domain/protected_item.dart';
import '../../features/items/presentation/item_actions.dart';
import '../../features/shell/application/launch_intents.dart';
import '../app_window.dart';

/// Handles requests from Explorer ("unlock this vault", "lock this
/// folder", "unlock this folder") one at a time, as soon as the app is
/// ready for them. Asking whether to lock a folder again once its last
/// Explorer window closed (see [FolderWindowWatcher]) is one too.
///
/// Opening a vault and that question work even while the app is locked,
/// and show just their dialog when the app isn't open (see
/// [WindowController]); locking and unlocking items need the app to be
/// unlocked first.
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
  StreamSubscription<ProtectedItem>? _closed;

  @override
  void initState() {
    super.initState();
    _closed = ref.read(folderWindowWatcherProvider).closed.listen(_askToLock);
    WidgetsBinding.instance.addPostFrameCallback((_) => _schedule());
  }

  @override
  void dispose() {
    unawaited(_closed?.cancel());
    super.dispose();
  }

  /// Once per closed folder: it may have closed again while the question
  /// waited.
  void _askToLock(ProtectedItem item) {
    final intents = ref.read(launchIntentsProvider.notifier);
    final waiting = ref
        .read(launchIntentsProvider)
        .any((intent) => intent is LockAgainIntent && intent.itemId == item.id);
    if (!waiting) intents.add(LockAgainIntent(item.itemPath, itemId: item.id));
  }

  void _schedule() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_pump()));

  Future<void> _pump() async {
    if (_handling || !mounted) return;
    final session = ref.read(sessionControllerProvider);
    final window = ref.read(windowStateProvider.notifier);
    final setUp =
        session.status != SessionStatus.needsSetup &&
        session.status != SessionStatus.onboarding;
    if (!setUp && ref.read(windowStateProvider).mode == WindowMode.request) {
      // Nothing opens before the app is set up: that needs the app.
      await window.showMain();
      return;
    }
    final ready =
        session.status == SessionStatus.locked ||
        session.status == SessionStatus.unlocked;
    if (!ready || ref.read(protectionControllerProvider) != null) return;

    final intents = ref.read(launchIntentsProvider.notifier);
    final intent = intents.take(
      (intent) => intent.dialogOnly || session.isUnlocked,
    );
    if (intent == null) {
      _notifyWaiting();
      return;
    }

    _handling = true;
    try {
      await window.present(intent);
      final context = rootNavigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      final actions = ItemActions(context, ref);
      switch (intent) {
        case OpenVaultIntent(:final path):
          await actions.openVault(path);
        case LockPathIntent(:final path):
          await actions.lockPath(path);
        case UnlockPathIntent(:final path):
          await actions.unlockPath(path);
        case LockAgainIntent(:final itemId, :final closed):
          await actions.askToLockAgain(itemId, closed: closed);
      }
    } finally {
      _handling = false;
    }
    await window.finishRequest();
    _schedule();
  }

  /// Tells the user once about each request that waits for the app to be
  /// unlocked (in one message: a new message replaces the last one).
  void _notifyWaiting() {
    final waiting = [
      for (final intent in ref.read(launchIntentsProvider))
        if (_verb(intent) case final verb?
            when _waitingNotified.add('$verb ${intent.path}'))
          (verb, p.basename(intent.path)),
    ];
    if (waiting.isEmpty) return;
    final (verb, name) = waiting.first;
    final more = waiting.length > 1 ? ' and ${waiting.length - 1} more' : '';
    showToast('Unlock the app to $verb “$name”$more.', tone: Tone.info);
  }

  static String? _verb(LaunchIntent intent) => switch (intent) {
    LockPathIntent() => 'lock',
    UnlockPathIntent() => 'unlock',
    OpenVaultIntent() || LockAgainIntent() => null,
  };

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
