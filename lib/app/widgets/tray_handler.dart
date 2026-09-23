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
import '../../features/shell/presentation/lock_app_action.dart';
import '../../platform/system_tray.dart';
import '../window_actions.dart';
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

  int get _unlockedCount {
    final items = ref.read(itemsControllerProvider.notifier);
    return items.items
        .where((item) => !item.isProtected && items.existsOnDisk(item))
        .length;
  }

  /// Shows, updates or removes the icon to match the current state.
  void _sync() {
    if (!mounted || !_tray.isAvailable) return;
    if (!ref.read(settingsControllerProvider).keepRunningInTray) {
      if (_shown != null) unawaited(_tray.hide());
      _shown = null;
      return;
    }
    final appUnlocked = ref.read(sessionControllerProvider).isUnlocked;
    final unlocked = _unlockedCount;
    final key = '$unlocked/$appUnlocked';
    if (key == _shown) return;
    _shown = key;
    unawaited(
      _tray.show(
        tooltip: unlocked == 0
            ? '${AppInfo.name} · everything is locked'
            : '${AppInfo.name} · ${Format.count(unlocked, 'item')} unlocked',
        attention: unlocked > 0,
        menu: [
          const TrayMenuItem('open', 'Open ${AppInfo.name}'),
          const TrayMenuItem.separator(),
          TrayMenuItem(
            'lockAll',
            unlocked == 0 ? 'Everything is locked' : 'Lock all items',
            enabled: unlocked > 0 && appUnlocked,
          ),
          TrayMenuItem('lockApp', 'Lock ${AppInfo.name}', enabled: appUnlocked),
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

  Future<void> _showWindow() async {
    if (widget.nativeWindow) await showMainWindow();
  }

  Future<void> _lockAll() async {
    final left = await ref
        .read(protectionControllerProvider.notifier)
        .lockAllUnlocked();
    if (left.isEmpty) {
      showToast('Every item is locked.', tone: Tone.success);
      return;
    }
    await _showWindow();
    showToast(
      '${Format.count(left.length, 'item')} could not be locked here (they '
      'need their own password, or a file is in use).',
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
      ..listen(settingsControllerProvider, (_, _) => _sync());
    return widget.child;
  }
}
