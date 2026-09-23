import 'dart:async';

import 'package:desktop_folder_locker/platform/system_tray.dart';

/// Records what the app shows in the notification area, and lets tests
/// click the icon or its menu.
class FakeSystemTray implements SystemTray {
  final List<({String tooltip, bool attention, List<TrayMenuItem> menu})>
  shown = [];
  final List<({String title, String body})> notifications = [];
  final StreamController<TrayEvent> _events =
      StreamController<TrayEvent>.broadcast();
  bool visible = false;

  ({String tooltip, bool attention, List<TrayMenuItem> menu}) get last =>
      shown.last;

  /// Simulates a click on a menu entry.
  void select(String id) => _events.add(TrayMenuSelected(id));

  @override
  bool get isAvailable => true;

  @override
  Stream<TrayEvent> get events => _events.stream;

  @override
  Future<void> show({
    required String tooltip,
    required bool attention,
    required List<TrayMenuItem> menu,
  }) async {
    shown.add((tooltip: tooltip, attention: attention, menu: menu));
    visible = true;
  }

  @override
  Future<void> hide() async => visible = false;

  @override
  Future<bool> notify({required String title, required String body}) async {
    notifications.add((title: title, body: body));
    return visible;
  }
}
