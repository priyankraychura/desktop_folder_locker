import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The folders that Explorer shows, in each window and tab: once none
/// shows an unlocked folder any more, the user is done with it.
abstract interface class ExplorerFolders {
  /// The folders shown now, or `null` when that can't be told.
  Future<List<String>?> shown();

  /// The folders shown, each time that changes, as Explorer tells it:
  /// first what's shown now. `null` where Explorer can't be watched; then
  /// [shown] is asked every now and then. Ends if watching stops working.
  Stream<ShownFolders>? watch();
}

/// What Explorer shows, after a window opened, went to another folder, or
/// closed.
@immutable
class ShownFolders {
  const ShownFolders(this.folders, {this.window});

  final List<String> folders;

  /// Where the Explorer window whose change it was is (or was) on the
  /// screen, in physical pixels: a question about it shows over it (see
  /// `AppWindow.show`). `null` when that isn't known.
  final Rect? window;
}

/// Where that can't be told: not Windows, or tests of other parts.
class NoExplorerFolders implements ExplorerFolders {
  const NoExplorerFolders();

  @override
  Future<List<String>?> shown() async => null;

  @override
  Stream<ShownFolders>? watch() => null;
}

/// Asks Explorer through the Explorer plug-in next to the app
/// (`CloakShownFolders` in `cloak_shell.dll`), in another
/// isolate: each question goes to Explorer's process, which can be slow
/// to answer.
///
/// Watches it through the Windows runner (`windows/runner/
/// explorer_watcher.cpp`), which hears Explorer's own events: a closed
/// window is known right away.
class NativeExplorerFolders implements ExplorerFolders {
  NativeExplorerFolders(this.pluginPath);

  final String pluginPath;

  static const MethodChannel _channel = MethodChannel('cloak/explorer');

  /// Lives as long as the app; closed only if watching doesn't work.
  StreamController<ShownFolders>? _changes;

  @override
  Stream<ShownFolders>? watch() =>
      (_changes ??= StreamController<ShownFolders>.broadcast(
        onListen: () => unawaited(_startWatching()),
      )).stream;

  Future<void> _startWatching() async {
    _channel.setMethodCallHandler(_onCall);
    bool watching;
    try {
      watching = await _channel.invokeMethod<bool>('watch') ?? false;
    } on Object {
      watching = false;
    }
    if (!watching) {
      _channel.setMethodCallHandler(null);
      await _changes?.close();
    }
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'changed') return;
    final arguments = call.arguments as Map<Object?, Object?>;
    final folders = (arguments['folders'] as List<Object?>).cast<String>();
    final window = switch (arguments['window']) {
      [final int left, final int top, final int right, final int bottom] =>
        Rect.fromLTRB(
          left.toDouble(),
          top.toDouble(),
          right.toDouble(),
          bottom.toDouble(),
        ),
      _ => null,
    };
    _changes?.add(ShownFolders(folders, window: window));
  }

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
        >('CloakShownFolders');
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
