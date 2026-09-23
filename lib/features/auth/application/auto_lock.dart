import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../items/application/protection_controller.dart';
import '../../settings/application/settings_controller.dart';
import 'app_locker.dart';
import 'session_controller.dart';

final autoLockProvider = Provider<AutoLock>((ref) {
  final autoLock = AutoLock(ref);
  ref.onDispose(autoLock.dispose);
  return autoLock;
});

/// Locks the app after a period without mouse or keyboard activity
/// (configurable in Settings). Never interrupts a running operation.
class AutoLock {
  AutoLock(this._ref) {
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _check());
  }

  final Ref _ref;
  late final Timer _timer;
  DateTime _lastActivity = DateTime.now();

  /// Call on user input.
  void touch() => _lastActivity = DateTime.now();

  void _check() {
    final minutes = _ref.read(settingsControllerProvider).autoLockMinutes;
    if (minutes <= 0) return;
    final session = _ref.read(sessionControllerProvider);
    final busy = _ref.read(protectionControllerProvider) != null;
    if (!session.isUnlocked || busy) return;
    if (DateTime.now().difference(_lastActivity) >=
        Duration(minutes: minutes)) {
      unawaited(_ref.read(appLockerProvider).lockApp());
    }
  }

  void dispose() => _timer.cancel();
}
