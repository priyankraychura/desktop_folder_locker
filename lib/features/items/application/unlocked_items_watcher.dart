import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/application/settings_controller.dart';
import '../domain/protected_item.dart';
import 'items_controller.dart';
import 'protection_controller.dart';

final unlockedItemsWatcherProvider = Provider<UnlockedItemsWatcher>((ref) {
  final watcher = UnlockedItemsWatcher(ref);
  ref.onDispose(watcher.dispose);
  return watcher;
});

/// Looks after items that stay unlocked, as set in Settings:
///
/// * locks them again automatically after a while (when that needs no typed
///   password), and
/// * reports the ones that were left unlocked too long on [reminders]
///   (once per unlock), so the UI can remind the user.
class UnlockedItemsWatcher {
  UnlockedItemsWatcher(
    this._ref, {
    Duration interval = const Duration(seconds: 30),
  }) {
    _timer = Timer.periodic(interval, (_) => unawaited(check()));
  }

  final Ref _ref;
  late final Timer _timer;
  final StreamController<List<ProtectedItem>> _reminders =
      StreamController<List<ProtectedItem>>.broadcast();

  /// Items already reminded about during their current unlock.
  final Set<String> _reminded = {};

  /// When locking an item again last failed (a file was in use), so it is
  /// not retried every few seconds.
  final Map<String, DateTime> _relockFailedAt = {};
  bool _checking = false;

  static const Duration retryAfter = Duration(minutes: 5);

  /// Items that have been unlocked longer than the reminder time.
  Stream<List<ProtectedItem>> get reminders => _reminders.stream;

  /// Runs one round. [now] is for tests.
  Future<void> check({DateTime? now}) async {
    if (_checking) return;
    _checking = true;
    try {
      final time = now ?? DateTime.now();
      final settings = _ref.read(settingsControllerProvider);
      final unlocked = _unlocked();
      final ids = {for (final item in unlocked) item.id};
      _reminded.retainWhere(ids.contains);
      _relockFailedAt.removeWhere((id, _) => !ids.contains(id));

      if (settings.relockAfterMinutes > 0) {
        await _relock(time, Duration(minutes: settings.relockAfterMinutes));
      }
      if (settings.remindAfterMinutes > 0) {
        _remind(time, Duration(minutes: settings.remindAfterMinutes));
      }
    } finally {
      _checking = false;
    }
  }

  List<ProtectedItem> _unlocked() {
    final items = _ref.read(itemsControllerProvider.notifier);
    return [
      for (final item in items.items)
        if (!item.isProtected &&
            item.unlockedAt != null &&
            items.existsOnDisk(item))
          item,
    ];
  }

  Future<void> _relock(DateTime now, Duration after) async {
    final protection = _ref.read(protectionControllerProvider.notifier);
    final due = _unlocked().where(
      (item) =>
          now.difference(item.unlockedAt!) >= after &&
          !_recentlyFailed(item, now) &&
          protection.lockRequirement(item) == LockRequirement.none,
    );
    for (final item in due.toList()) {
      // Never interrupt something the user started; try next round.
      if (_ref.read(protectionControllerProvider) != null) return;
      try {
        await protection.lockAgain(item);
      } on Object {
        _relockFailedAt[item.id] = now;
      }
    }
  }

  bool _recentlyFailed(ProtectedItem item, DateTime now) {
    final failedAt = _relockFailedAt[item.id];
    return failedAt != null && now.difference(failedAt) < retryAfter;
  }

  void _remind(DateTime now, Duration after) {
    final due = [
      for (final item in _unlocked())
        if (!_reminded.contains(item.id) &&
            now.difference(item.unlockedAt!) >= after)
          item,
    ];
    if (due.isEmpty) return;
    _reminded.addAll(due.map((item) => item.id));
    _reminders.add(due);
  }

  void dispose() {
    _timer.cancel();
    unawaited(_reminders.close());
  }
}
