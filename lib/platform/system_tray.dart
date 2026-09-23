import 'dart:async';

import 'package:flutter/services.dart';

/// One entry of the tray icon's menu.
class TrayMenuItem {
  const TrayMenuItem(this.id, this.label, {this.enabled = true})
    : separator = false;

  const TrayMenuItem.separator()
    : id = '',
      label = '',
      enabled = false,
      separator = true;

  final String id;
  final String label;
  final bool enabled;
  final bool separator;

  Map<String, Object?> toMap() => separator
      ? {'separator': true}
      : {'id': id, 'label': label, 'enabled': enabled};
}

sealed class TrayEvent {
  const TrayEvent();
}

/// The icon (or one of its notifications) was clicked.
final class TrayActivated extends TrayEvent {
  const TrayActivated();
}

/// A menu entry was chosen.
final class TrayMenuSelected extends TrayEvent {
  const TrayMenuSelected(this.id);

  final String id;
}

/// The app's icon in the notification area.
abstract interface class SystemTray {
  /// Whether this platform has a tray icon.
  bool get isAvailable;

  Stream<TrayEvent> get events;

  /// Shows the icon (or updates it). [attention] switches to the icon that
  /// signals unlocked items.
  Future<void> show({
    required String tooltip,
    required bool attention,
    required List<TrayMenuItem> menu,
  });

  Future<void> hide();

  /// Shows a Windows notification from the tray icon. Returns `false` when
  /// the icon is not shown.
  Future<bool> notify({required String title, required String body});
}

/// The tray icon implemented by the Windows runner
/// (`windows/runner/tray_icon.cpp`).
class NativeSystemTray implements SystemTray {
  NativeSystemTray() {
    _channel.setMethodCallHandler(_onCall);
  }

  static const MethodChannel _channel = MethodChannel('folder_locker/tray');

  final StreamController<TrayEvent> _events =
      StreamController<TrayEvent>.broadcast();

  @override
  bool get isAvailable => true;

  @override
  Stream<TrayEvent> get events => _events.stream;

  Future<void> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'activate':
        _events.add(const TrayActivated());
      case 'menuItem':
        if (call.arguments case final String id) {
          _events.add(TrayMenuSelected(id));
        }
    }
  }

  @override
  Future<void> show({
    required String tooltip,
    required bool attention,
    required List<TrayMenuItem> menu,
  }) => _channel.invokeMethod<bool>('show', {
    'tooltip': tooltip,
    'attention': attention,
    'menu': [for (final item in menu) item.toMap()],
  });

  @override
  Future<void> hide() => _channel.invokeMethod<void>('hide');

  @override
  Future<bool> notify({required String title, required String body}) async =>
      await _channel.invokeMethod<bool>('notify', {
        'title': title,
        'body': body,
      }) ??
      false;
}

/// Used where there is no tray icon (other platforms, tests).
class NoSystemTray implements SystemTray {
  const NoSystemTray();

  @override
  bool get isAvailable => false;

  @override
  Stream<TrayEvent> get events => const Stream.empty();

  @override
  Future<void> show({
    required String tooltip,
    required bool attention,
    required List<TrayMenuItem> menu,
  }) async {}

  @override
  Future<void> hide() async {}

  @override
  Future<bool> notify({required String title, required String body}) async =>
      false;
}
