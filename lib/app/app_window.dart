import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../core/constants/app_info.dart';
import '../core/di/core_providers.dart';
import '../features/items/application/items_controller.dart';
import '../features/items/application/protection_controller.dart';
import '../features/settings/application/settings_controller.dart';
import '../features/shell/application/launch_intents.dart';

/// How the app's window shows.
enum WindowMode {
  /// The app itself.
  main,

  /// Only a dialog, in a small window: when Explorer asks to open a locked
  /// item, or the app asks whether to lock a closed folder again, and the
  /// app isn't open, that's all there is to show.
  request,
}

@immutable
class WindowState {
  const WindowState({
    this.mode = WindowMode.main,
    this.startedForRequest = false,
  });

  final WindowMode mode;

  /// Explorer started the app for the request, the user didn't: it may
  /// quit right after it, so it shows no notification-area icon yet.
  final bool startedForRequest;
}

/// The window the app starts with. Overridden in `bootstrap()`.
final initialWindowStateProvider = Provider<WindowState>(
  (ref) => const WindowState(),
);

/// The native window. Overridden in `bootstrap()`; tests use a fake.
final appWindowProvider = Provider<AppWindow>((ref) => const NoAppWindow());

final windowStateProvider = NotifierProvider<WindowController, WindowState>(
  WindowController.new,
);

/// Decides how the window shows: the app, or just a dialog. Also decides
/// when the app runs in the background, in the notification area: only
/// while it has something to look after. Then it quits.
class WindowController extends Notifier<WindowState> {
  @override
  WindowState build() {
    ref
      ..listen(itemsControllerProvider, (_, _) => _quitIfDone())
      ..listen(protectionControllerProvider, (_, _) => _quitIfDone());
    return ref.read(initialWindowStateProvider);
  }

  AppWindow get _window => ref.read(appWindowProvider);

  /// The window is hidden and the app runs in the notification area.
  bool _inBackground = false;
  bool _quitting = false;

  /// Shows the app (from the notification area, the Start menu…). The user
  /// is using it now, so it stays when a request is done.
  Future<void> showMain() async {
    _inBackground = false;
    state = const WindowState();
    await _window.showMain();
  }

  /// Shows the window for [intent]. A dialog-only request gets the small
  /// window, unless the app is open anyway; everything else needs the app.
  Future<void> present(LaunchIntent? intent) async {
    final inApp = state.mode == WindowMode.main;
    if (intent == null ||
        !intent.dialogOnly ||
        (inApp && await _window.isVisible())) {
      return showMain();
    }
    _inBackground = false;
    if (inApp) state = const WindowState(mode: WindowMode.request);
    await _window.showRequest();
  }

  /// The small window's request is done. The next one uses the same
  /// window, and requests that need the app get it. Otherwise the app goes
  /// to the notification area, or quits if it has nothing to look after.
  Future<void> finishRequest() async {
    if (state.mode != WindowMode.request) return;
    final pending = ref.read(launchIntentsProvider);
    if (pending.any((intent) => intent.dialogOnly)) return;
    if (pending.isNotEmpty) return showMain();
    if (!_needed()) {
      await _window.hide();
      return _quit();
    }
    // Hidden without the icon, there'd be no way back to the app.
    if (!_inTray) return showMain();
    await _window.hide();
    _inBackground = true;
    state = const WindowState();
  }

  /// Whether the app can go on in the notification area when the user
  /// closes its window: with the icon, while it has something to look
  /// after. Otherwise it quits.
  bool get canRunInBackground => _inTray && _needed();

  /// Hides the window: the app goes on in the notification area.
  Future<void> toBackground() async {
    await _window.hide();
    _inBackground = true;
  }

  bool get _inTray =>
      ref.read(settingsControllerProvider).keepRunningInTray &&
      ref.read(systemTrayProvider).isAvailable;

  /// Open drives need the app, which serves them. Unlocked items need it
  /// when it runs in the notification area, to remind about them and ask
  /// to lock them again.
  bool _needed() {
    final items = ref.read(itemsControllerProvider.notifier);
    if (items.items.any((item) => item.isMounted)) return true;
    return _inTray &&
        items.items.any(
          (item) => !item.isProtected && items.existsOnDisk(item),
        );
  }

  /// In the background, the app quits once it has nothing left to look
  /// after: everything is locked again, and nothing is going on.
  void _quitIfDone() {
    if (!_inBackground ||
        ref.read(protectionControllerProvider) != null ||
        ref.read(launchIntentsProvider).isNotEmpty ||
        _needed()) {
      return;
    }
    unawaited(_quit());
  }

  Future<void> _quit() async {
    if (_quitting) return;
    _quitting = true;
    await _window.quit();
  }
}

/// The app's native window.
abstract interface class AppWindow {
  /// Shows the app: large and resizable, with the app's own title bar.
  Future<void> showMain();

  /// Shows a small window with Windows' title bar, for one dialog.
  Future<void> showRequest();

  Future<void> hide();

  Future<bool> isVisible();

  /// Closes the window, which ends the app.
  Future<void> quit();
}

/// Where there's no window to control (tests of other parts).
class NoAppWindow implements AppWindow {
  const NoAppWindow();

  @override
  Future<void> showMain() async {}

  @override
  Future<void> showRequest() async {}

  @override
  Future<void> hide() async {}

  @override
  Future<bool> isVisible() async => true;

  @override
  Future<void> quit() async {}
}

/// The real window, through window_manager. One window takes both looks.
class NativeAppWindow implements AppWindow {
  NativeAppWindow({required bool startWithRequest})
    : _request = startWithRequest;

  static const Size mainSize = Size(1180, 760);
  static const Size mainMinimumSize = Size(940, 640);

  /// The dialogs (480 wide, with their margins) and Windows' title bar.
  static const Size requestSize = Size(560, 540);

  bool _request;
  final Completer<void> _ready = Completer<void>();

  /// Where the app was and whether it was maximized, to put it back after
  /// a request.
  Rect? _mainBounds;
  bool _mainMaximized = false;

  /// Connects to the window. It's set up and shown once the first frame is
  /// ready.
  Future<void> start() async {
    await windowManager.ensureInitialized();
    final ready = windowManager.waitUntilReadyToShow(
      WindowOptions(
        title: AppInfo.name,
        size: _request ? requestSize : mainSize,
        minimumSize: _request ? requestSize : mainMinimumSize,
        center: true,
        titleBarStyle: _request ? TitleBarStyle.normal : TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
      () async {
        if (_request) await _fixed(true);
        await _front();
        _ready.complete();
      },
    );
    unawaited(ready);
  }

  @override
  Future<void> showMain() async {
    await _ready.future;
    if (_request) {
      await _fixed(false);
      await windowManager.setMinimumSize(mainMinimumSize);
      await windowManager.setTitleBarStyle(
        TitleBarStyle.hidden,
        windowButtonVisibility: false,
      );
      final bounds = _mainBounds;
      if (bounds == null) {
        await windowManager.setSize(mainSize);
        await windowManager.center();
      } else {
        await windowManager.setBounds(bounds);
      }
      if (_mainMaximized) await windowManager.maximize();
      _request = false;
    }
    await _front();
  }

  @override
  Future<void> showRequest() async {
    await _ready.future;
    if (!_request) {
      _mainMaximized = await windowManager.isMaximized();
      if (_mainMaximized) await windowManager.unmaximize();
      _mainBounds = await windowManager.getBounds();
      // The smaller minimum first, or Windows keeps the window large.
      await windowManager.setMinimumSize(requestSize);
      await _fixed(true);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.setSize(requestSize);
      await windowManager.center();
      _request = true;
    }
    await _front();
  }

  @override
  Future<void> hide() async {
    await _ready.future;
    await windowManager.hide();
  }

  /// Once the window was shown first.
  @override
  Future<bool> isVisible() async {
    await _ready.future;
    return windowManager.isVisible();
  }

  @override
  Future<void> quit() => windowManager.destroy();

  Future<void> _fixed(bool fixed) async {
    await windowManager.setResizable(!fixed);
    await windowManager.setMaximizable(!fixed);
  }

  Future<void> _front() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }
}
