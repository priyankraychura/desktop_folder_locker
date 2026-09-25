import 'dart:async';
import 'dart:ui';

import 'package:desktop_folder_locker/platform/explorer_folders.dart';

/// Stands in for Explorer: the folders its windows show.
class FakeExplorerFolders implements ExplorerFolders {
  /// `null` while Explorer doesn't answer.
  List<String>? folders = [];

  /// Whether it tells each change (see [change]). Otherwise the app asks
  /// with [shown]. Set before the app starts watching.
  bool watches = false;

  final StreamController<ShownFolders> _changes =
      StreamController<ShownFolders>.broadcast();

  @override
  Future<List<String>?> shown() async => folders?.toList();

  @override
  Stream<ShownFolders>? watch() => watches ? _changes.stream : null;

  /// Explorer shows [shown] now, after a change in [window].
  void change(List<String> shown, {Rect? window}) {
    folders = shown;
    _changes.add(ShownFolders(shown.toList(), window: window));
  }

  /// Watching stopped working.
  Future<void> stopWatching() => _changes.close();
}
