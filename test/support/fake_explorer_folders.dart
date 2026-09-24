import 'package:desktop_folder_locker/platform/explorer_folders.dart';

/// Stands in for Explorer: the folders its windows show.
class FakeExplorerFolders implements ExplorerFolders {
  /// `null` while Explorer doesn't answer.
  List<String>? folders = [];

  @override
  Future<List<String>?> shown() async => folders?.toList();
}
