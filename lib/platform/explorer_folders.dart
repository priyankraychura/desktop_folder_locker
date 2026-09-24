import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// The folders that Explorer shows, in each window and tab: once none
/// shows an unlocked folder any more, the user is done with it.
abstract interface class ExplorerFolders {
  /// The folders shown now, or `null` when that can't be told.
  Future<List<String>?> shown();
}

/// Where that can't be told: not Windows, or tests of other parts.
class NoExplorerFolders implements ExplorerFolders {
  const NoExplorerFolders();

  @override
  Future<List<String>?> shown() async => null;
}

/// Asks Explorer through the Explorer plug-in next to the app
/// (`FolderLockerShownFolders` in `folder_locker_shell.dll`), in another
/// isolate: each question goes to Explorer's process, which can be slow
/// to answer.
class NativeExplorerFolders implements ExplorerFolders {
  NativeExplorerFolders(this.pluginPath);

  final String pluginPath;

  /// An Explorer that takes longer than this to answer is busy.
  static const Duration timeout = Duration(seconds: 10);

  /// The question Explorer hasn't answered yet: no new one until it does.
  Future<List<String>?>? _asking;

  @override
  Future<List<String>?> shown() async {
    if (_asking != null || !File(pluginPath).existsSync()) return null;
    final path = pluginPath;
    final asking = _asking = Isolate.run(() => _shown(path))
      ..whenComplete(() => _asking = null).ignore();
    try {
      return await asking.timeout(timeout);
    } on Object {
      return null;
    }
  }

  static List<String>? _shown(String pluginPath) {
    final shownFolders = DynamicLibrary.open(pluginPath)
        .lookupFunction<
          Int32 Function(Pointer<Uint16>, Uint32),
          int Function(Pointer<Uint16>, int)
        >('FolderLockerShownFolders');
    var capacity = 4096;
    while (true) {
      final buffer = calloc<Uint16>(capacity);
      try {
        final size = shownFolders(buffer, capacity);
        if (size < 0) return null;
        if (size <= capacity) {
          // Each path ends with a NUL.
          return String.fromCharCodes(buffer.asTypedList(size)).split('\u0000')
            ..removeLast();
        }
        // More windows opened meanwhile: a larger buffer.
        capacity = size;
      } finally {
        calloc.free(buffer);
      }
    }
  }
}
