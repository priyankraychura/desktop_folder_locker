import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../items/application/protection_controller.dart';
import '../../items/domain/protected_item.dart';
import '../../settings/application/settings_controller.dart';
import 'session_controller.dart';

final appLockerProvider = Provider<AppLocker>(AppLocker.new);

/// Locks the app: from the sidebar, `Ctrl+L`, the tray menu or after
/// inactivity.
///
/// When "Lock items when the app locks" is on, unlocked items are locked
/// first, while the keys they need are still in memory.
class AppLocker {
  AppLocker(this._ref);

  final Ref _ref;
  bool _locking = false;

  /// Returns the items that stayed unlocked (they need their own password
  /// or a file in them is in use). Empty when items are not locked along.
  Future<List<ProtectedItem>> lockApp() async {
    if (_locking || !_ref.read(sessionControllerProvider).isUnlocked) {
      return const [];
    }
    _locking = true;
    try {
      var left = const <ProtectedItem>[];
      if (_ref.read(settingsControllerProvider).lockItemsWithApp) {
        left = await _ref
            .read(protectionControllerProvider.notifier)
            .lockAllUnlocked();
      }
      _ref.read(sessionControllerProvider.notifier).lock();
      return left;
    } finally {
      _locking = false;
    }
  }
}
