import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/di/core_providers.dart';
import '../../../engine/vault/fs_utils.dart';
import '../../../platform/explorer_folders.dart';
import '../../settings/application/settings_controller.dart';
import '../domain/protected_item.dart';
import 'items_controller.dart';

final folderWindowWatcherProvider = Provider<FolderWindowWatcher>((ref) {
  final watcher = FolderWindowWatcher(ref);
  ref.onDispose(watcher.dispose);
  return watcher;
});

/// An unlocked folder, or open drive, that no Explorer window shows any
/// more.
@immutable
class FolderClosed {
  const FolderClosed(this.item, {this.window});

  final ProtectedItem item;

  /// Where the Explorer window that closed (or went elsewhere) was on the
  /// screen, in physical pixels: the question shows over it, as if
  /// Explorer asked. `null` when that isn't known.
  final Rect? window;
}

/// Notices when the user is done with an unlocked folder, or an open
/// drive: Explorer showed it (or something in it), and now no window
/// does. Reports it on [closed], so the app can ask whether to lock it
/// again (if set in Settings).
///
/// Explorer tells each change as it happens (see [ExplorerFolders.watch]),
/// so the question comes as the window closes. Where it can't, the
/// watcher asks every [interval] instead; never both, or a late answer
/// could report a folder twice.
class FolderWindowWatcher {
  FolderWindowWatcher(this._ref, {this.interval = const Duration(seconds: 2)}) {
    final changes = _ref.read(explorerFoldersProvider).watch();
    if (changes == null) {
      _poll();
    } else {
      _changes = changes.listen(
        (shown) => _update(shown.folders, window: shown.window),
        onDone: () {
          _changes = null;
          _poll();
        },
      );
    }
    // A folder that shows already when it's unlocked (or when the app
    // starts, or the setting is turned on) counts as shown right away:
    // closing it asks too.
    _ref
      ..listen(itemsControllerProvider, (_, _) => _recheck())
      ..listen(
        settingsControllerProvider.select((s) => s.askToLockWhenClosed),
        (_, _) => _recheck(),
      );
  }

  final Ref _ref;

  /// How often Explorer is asked, where it can't be watched.
  final Duration interval;

  Timer? _timer;
  StreamSubscription<ShownFolders>? _changes;
  final StreamController<FolderClosed> _closed =
      StreamController<FolderClosed>.broadcast();

  /// Items that a window showed since they were unlocked.
  final Set<String> _seen = {};

  /// What Explorer showed last.
  List<String>? _shown;
  bool _checking = false;

  /// Unlocked items whose last Explorer window closed.
  Stream<FolderClosed> get closed => _closed.stream;

  void _poll() {
    if (_closed.isClosed) return;
    _timer ??= Timer.periodic(interval, (_) => unawaited(check()));
  }

  /// Asks Explorer once, where it can't be watched: only while there's
  /// something to look after.
  Future<void> check() async {
    if (_checking || _changes != null) return;
    final watched = _watched();
    _seen.retainWhere(watched.containsKey);
    if (watched.isEmpty) return;
    _checking = true;
    try {
      final shown = await _ref.read(explorerFoldersProvider).shown();
      // The watcher may have stopped meanwhile.
      if (shown == null || _closed.isClosed) return;
      _update(shown);
    } finally {
      _checking = false;
    }
  }

  void _recheck() {
    final shown = _shown;
    if (shown != null) _update(shown);
  }

  /// Explorer shows [shown] now. [window] is the one whose change it was.
  void _update(List<String> shown, {Rect? window}) {
    if (_closed.isClosed) return;
    _shown = shown;
    // The list may have changed while Explorer answered.
    final watched = _watched();
    _seen.retainWhere(watched.containsKey);
    for (final MapEntry(key: id, value: (item, place)) in watched.entries) {
      final isShown = shown.any(
        (folder) => p.equals(folder, place) || p.isWithin(place, folder),
      );
      if (isShown) {
        _seen.add(id);
      } else if (_seen.remove(id)) {
        _closed.add(FolderClosed(item, window: window));
      }
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
    _timer?.cancel();
    unawaited(_changes?.cancel());
    unawaited(_closed.close());
  }
}
