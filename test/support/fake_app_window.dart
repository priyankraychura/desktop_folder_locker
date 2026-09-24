import 'package:desktop_folder_locker/app/app_window.dart';

/// Stands in for the app's window: records how it shows.
class FakeAppWindow implements AppWindow {
  FakeAppWindow({this.visible = true});

  bool visible;

  /// `main` or `request`: how it was shown last.
  String? look;

  /// Whether the app was closed.
  bool ended = false;

  @override
  Future<void> showMain() async {
    visible = true;
    look = 'main';
  }

  @override
  Future<void> showRequest() async {
    visible = true;
    look = 'request';
  }

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
