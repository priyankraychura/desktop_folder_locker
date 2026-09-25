import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/constants/app_info.dart';
import '../../core/di/core_providers.dart';
import '../../core/theme/app_palette.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/feedback.dart';
import '../../features/auth/application/session_controller.dart';
import '../../features/items/application/items_controller.dart';
import '../../features/items/application/protection_controller.dart';
import '../../features/items/application/unlocked_items_watcher.dart';
import '../../features/items/domain/protected_item.dart';
import '../../features/settings/application/settings_controller.dart';
import '../../features/shell/application/launch_intents.dart';
import '../../features/shell/presentation/lock_app_action.dart';
import '../../platform/system_tray.dart';
import '../app_window.dart';
import 'close_guard.dart';

/// Keeps the notification-area icon in sync with the app (tooltip, menu,
/// "items unlocked" icon), handles its menu, and shows reminders about
/// items left unlocked.
class TrayHandler extends ConsumerStatefulWidget {
  const TrayHandler({
    required this.nativeWindow,
    required this.child,
    super.key,
  });

  /// `false` when there is no native window to show (tests).
  final bool nativeWindow;
  final Widget child;

  @override
  ConsumerState<TrayHandler> createState() => _TrayHandlerState();
}

class _TrayHandlerState extends ConsumerState<TrayHandler> {
  StreamSubscription<TrayEvent>? _events;
  StreamSubscription<List<ProtectedItem>>? _reminders;
  String? _shown;

  SystemTray get _tray => ref.read(systemTrayProvider);

  @override
  void initState() {
    super.initState();
    _events = _tray.events.listen((event) => unawaited(_onEvent(event)));
    _reminders = ref
        .read(unlockedItemsWatcherProvider)
        .reminders
        .listen((due) => unawaited(_remind(due)));
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    unawaited(_reminders?.cancel());
    super.dispose();
  }

  List<ProtectedItem> get _unlocked {
    final items = ref.read(itemsControllerProvider.notifier);
    return [
      for (final item in items.items)
        if (!item.isProtected && items.existsOnDisk(item)) item,
    ];
  }

  /// Shows, updates or removes the icon to match the current state. While
  /// Explorer's request is all the app was started for, there's none: the
  /// app may quit right after it.
  void _sync() {
    if (!mounted || !_tray.isAvailable) return;
    final window = ref.read(windowStateProvider);
    final justForRequest =
        window.startedForRequest && window.mode == WindowMode.request;
    if (!ref.read(settingsControllerProvider).keepRunningInTray ||
        justForRequest) {
      if (_shown != null) unawaited(_tray.hide());
      _shown = null;
      return;
    }
    final appUnlocked = ref.read(sessionControllerProvider).isUnlocked;
    final unlocked = _unlocked;
    // Items unlocked from Explorer lock without the app: their key is kept
    // while they're open. The others ask for their password.
    final lockLabel = switch (unlocked) {
      [] => 'Everything is locked',
      [final item] => 'Lock “${item.name}”',
      _ => 'Lock all ${unlocked.length} items',
    };
    final key = '$lockLabel/$appUnlocked';
    if (key == _shown) return;
    _shown = key;
    unawaited(
      _tray.show(
        tooltip: unlocked.isEmpty
            ? '${AppInfo.name} · everything is locked'
            : '${AppInfo.name} · '
                  '${Format.count(unlocked.length, 'item')} unlocked',
        attention: unlocked.isNotEmpty,
        menu: [
          const TrayMenuItem('open', 'Open ${AppInfo.name}'),
          const TrayMenuItem.separator(),
          TrayMenuItem('lockAll', lockLabel, enabled: unlocked.isNotEmpty),
          TrayMenuItem(
            'lockApp',
            appUnlocked ? 'Lock ${AppInfo.name}' : '${AppInfo.name} is locked',
            enabled: appUnlocked,
          ),
          const TrayMenuItem.separator(),
          const TrayMenuItem('quit', 'Quit'),
        ],
      ),
    );
  }

  Future<void> _onEvent(TrayEvent event) async {
    switch (event) {
      case TrayActivated() || TrayMenuSelected(id: 'open'):
        await _showWindow();
      case TrayMenuSelected(id: 'lockAll'):
        await _lockAll();
      case TrayMenuSelected(id: 'lockApp'):
        await lockAppWithFeedback(ref);
      case TrayMenuSelected(id: 'quit'):
        await _showWindow();
        await exitApp(ref);
      case TrayMenuSelected():
        break;
    }
  }

  Future<void> _showWindow() =>
      ref.read(windowStateProvider.notifier).showMain();

  /// Locks what it can right away; items that need a password ask for it,
  /// one after the other.
  Future<void> _lockAll() async {
    final protection = ref.read(protectionControllerProvider.notifier);
    final left = await protection.lockAllUnlocked();
    if (!mounted) return;
    final needPassword = [
      for (final item in left)
        if (protection.lockRequirement(item) != LockRequirement.none) item,
    ];
    final intents = ref.read(launchIntentsProvider.notifier);
    for (final item in needPassword) {
      intents.add(
        LockAgainIntent(item.itemPath, itemId: item.id, closed: false),
      );
    }
    final failed = left.length - needPassword.length;
    if (failed == 0) {
      if (left.isEmpty) showToast('Every item is locked.', tone: Tone.success);
      return;
    }
    await _showWindow();
    showToast(
      '${Format.count(failed, 'item')} could not be locked. A file in it '
      'may still be open: close it and try again.',
      tone: Tone.warning,
    );
  }

  Future<void> _remind(List<ProtectedItem> due) async {
    final title = due.length == 1
        ? '“${due.single.name}” is still unlocked'
        : '${Format.count(due.length, 'item')} are still unlocked';
    final inFront =
        !widget.nativeWindow ||
        (await windowManager.isVisible() && await windowManager.isFocused());
    if (!inFront &&
        ref.read(settingsControllerProvider).keepRunningInTray &&
        await _tray.notify(
          title: title,
          body:
              'Lock it again when you are done, from ${AppInfo.name} or '
              'its icon in the notification area.',
        )) {
      return;
    }
    showToast(
      '$title. Lock it again when you are done.',
      tone: Tone.warning,
      icon: Icons.lock_clock_rounded,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Update the icon whenever something it shows changes.
    ref
      ..listen(itemsControllerProvider, (_, _) => _sync())
      ..listen(sessionControllerProvider, (_, _) => _sync())
      ..listen(settingsControllerProvider, (_, _) => _sync())
      ..listen(windowStateProvider, (_, _) => _sync());
    return widget.child;
  }
}
