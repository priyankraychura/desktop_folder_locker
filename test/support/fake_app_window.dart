import 'dart:ui';

import 'package:desktop_folder_locker/app/app_window.dart';

/// Stands in for the app's window: records how it shows.
class FakeAppWindow implements AppWindow {
  FakeAppWindow({this.visible = true});

  bool visible;

  /// `app` or `compact`: its look, once it was set.
  String? look;

  /// Whether the app was closed.
  bool ended = false;

  /// The area it last showed over.
  Rect? shownOver;

  @override
  Future<void> show({required bool compact, Rect? over}) async {
    visible = true;
    shownOver = over;
    await restyle(compact: compact);
  }

  @override
  Future<void> restyle({required bool compact}) async {
    look = compact ? 'compact' : 'app';
  }

  @override
  Future<void> fitHeight(double height) async {}

  @override
  Future<void> colorTitleBar({
    required Color background,
    required Color text,
    required bool dark,
  }) async {}

  @override
  Future<void> hide() async => visible = false;

  @override
  Future<bool> isVisible() async => visible;

  @override
  Future<void> quit() async {
    visible = false;
    ended = true;
  }
}
