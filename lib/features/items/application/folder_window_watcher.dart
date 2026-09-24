import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/di/core_providers.dart';
import '../../../engine/vault/fs_utils.dart';
import '../../settings/application/settings_controller.dart';
import '../domain/protected_item.dart';
import 'items_controller.dart';

final folderWindowWatcherProvider = Provider<FolderWindowWatcher>((ref) {
  final watcher = FolderWindowWatcher(ref);
  ref.onDispose(watcher.dispose);
  return watcher;
});

/// Notices when the user is done with an unlocked folder, or an open
/// drive: Explorer showed it (or something in it), and now no window
/// does. Reports it on [closed], so the app can ask whether to lock it
/// again (if set in Settings).
class FolderWindowWatcher {
  FolderWindowWatcher(
    this._ref, {
    Duration interval = const Duration(seconds: 2),
  }) {
    _timer = Timer.periodic(interval, (_) => unawaited(check()));
  }

  final Ref _ref;
  late final Timer _timer;
  final StreamController<ProtectedItem> _closed =
      StreamController<ProtectedItem>.broadcast();

  /// Items that a window showed since they were unlocked.
  final Set<String> _seen = {};
  bool _checking = false;

  /// Unlocked items whose last Explorer window closed.
  Stream<ProtectedItem> get closed => _closed.stream;

  /// Runs one round: asks Explorer only while there's something to watch.
  Future<void> check() async {
    if (_checking) return;
    final watched = _watched();
    _seen.retainWhere(watched.containsKey);
    if (watched.isEmpty) return;
    _checking = true;
    try {
      final shown = await _ref.read(explorerFoldersProvider).shown();
      if (shown == null) return;
      // The list may have changed while Explorer answered.
      for (final MapEntry(key: id, value: (item, place))
          in _watched().entries) {
        final isShown = shown.any(
          (folder) => p.equals(folder, place) || p.isWithin(place, folder),
        );
        if (isShown) {
          _seen.add(id);
        } else if (_seen.remove(id)) {
          _closed.add(item);
        }
      }
    } finally {
      _checking = false;
    }
  }

  /// Unlocked folders and open drives, with the folder Explorer shows for
  /// each.
  Map<String, (ProtectedItem, String)> _watched() {
    if (!_ref.read(settingsControllerProvider).askToLockWhenClosed) {
      return const {};
    }
    final items = _ref.read(itemsControllerProvider.notifier);
    final watched = <String, (ProtectedItem, String)>{};
    for (final item in items.items) {
      if (item.isProtected || !items.existsOnDisk(item)) continue;
      // An unlocked file has no window of its own.
      final place = item.isMounted ? item.mountPoint! : item.itemPath;
      if (item.isMounted || FsUtils.isDirectory(place)) {
        watched[item.id] = (item, place);
      }
    }
    return watched;
  }

  void dispose() {
    _timer.cancel();
    unawaited(_closed.close());
  }
}
