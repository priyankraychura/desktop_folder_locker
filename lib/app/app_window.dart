import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../core/constants/app_info.dart';
import '../core/di/core_providers.dart';
import '../features/auth/application/session_controller.dart';
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

/// Whether the window is compact, the size of a dialog: for a request,
/// and for the lock screen, which is just its password form.
final compactWindowProvider = Provider<bool>(
  (ref) =>
      ref.watch(
        windowStateProvider.select((state) => state.mode == WindowMode.request),
      ) ||
      ref.watch(sessionControllerProvider.select(_isLocked)),
);

bool _isLocked(SessionState session) => session.status == SessionStatus.locked;

/// Decides how the window shows: the app, or just a dialog; compact while
/// the app is locked. Also decides when the app runs in the background, in
/// the notification area: only while it has something to look after. Then
/// it quits.
class WindowController extends Notifier<WindowState> {
  @override
  WindowState build() {
    ref
      ..listen(itemsControllerProvider, (_, _) => _quitIfDone())
      ..listen(protectionControllerProvider, (_, _) => _quitIfDone())
      ..listen(sessionControllerProvider.select(_isLocked), (_, _) {
        _restyle();
      });
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
    await _window.show(compact: _locked);
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
    await _window.show(compact: true);
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

  bool get _locked => _isLocked(ref.read(sessionControllerProvider));

  /// The app locked or unlocked: the lock screen is compact, the app large.
  /// A request's window stays as it is, and a hidden one changes when it
  /// shows.
  void _restyle() {
    if (state.mode != WindowMode.main || _inBackground) return;
    unawaited(_window.restyle(compact: _locked));
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

/// The app's native window, in one of two looks: the app (large and
/// resizable, with the app's own title bar), or compact (the size of a
/// dialog, with Windows' title bar).
abstract interface class AppWindow {
  /// Shows the window with that look, in front.
  Future<void> show({required bool compact});

  /// Changes the look, without bringing the window forward.
  Future<void> restyle({required bool compact});

  Future<void> hide();

  Future<bool> isVisible();

  /// Closes the window, which ends the app.
  Future<void> quit();
}

/// Where there's no window to control (tests of other parts).
class NoAppWindow implements AppWindow {
  const NoAppWindow();

  @override
  Future<void> show({required bool compact}) async {}

  @override
  Future<void> restyle({required bool compact}) async {}

  @override
  Future<void> hide() async {}

  @override
  Future<bool> isVisible() async => true;

  @override
  Future<void> quit() async {}
}

/// The real window, through window_manager. One window takes both looks.
class NativeAppWindow with WindowListener implements AppWindow {
  NativeAppWindow({required bool startCompact})
    : _compact = startCompact,
      _target = startCompact;

  static const Size appSize = Size(1180, 760);
  static const Size appMinimumSize = Size(940, 640);

  /// A dialog (480 wide, with its margins) or the lock screen's form, and
  /// Windows' title bar.
  static const Size compactSize = Size(560, 540);

  /// The look the window has, and the one it should have: a minimized
  /// window changes when it's restored.
  bool _compact;
  bool _target;
  final Completer<void> _ready = Completer<void>();
  Future<void> _changes = Future.value();

  /// Where the app was and whether it was maximized, to put it back after
  /// being compact.
  Rect? _appBounds;
  bool _appMaximized = false;

  /// Connects to the window. It's set up and shown once the first frame is
  /// ready.
  Future<void> start() async {
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    final ready = windowManager.waitUntilReadyToShow(
      WindowOptions(
        title: AppInfo.name,
        size: _compact ? compactSize : appSize,
        minimumSize: _compact ? compactSize : appMinimumSize,
        center: true,
        titleBarStyle: _compact ? TitleBarStyle.normal : TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
      () async {
        if (_compact) await _fixed(true);
        await _front();
        _ready.complete();
      },
    );
    unawaited(ready);
  }

  @override
  Future<void> show({required bool compact}) async {
    await _ready.future;
    if (await windowManager.isMinimized()) await windowManager.restore();
    await restyle(compact: compact);
    await _front();
  }

  @override
  Future<void> restyle({required bool compact}) {
    _target = compact;
    return _apply();
  }

  @override
  void onWindowRestore() => unawaited(_apply());

  /// Gives the window the look it should have, one change at a time.
  Future<void> _apply() {
    final change = _changes.then((_) async {
      await _ready.future;
      final compact = _target;
      if (compact == _compact || await windowManager.isMinimized()) return;
      if (compact) {
        _appMaximized = await windowManager.isMaximized();
        if (_appMaximized) await windowManager.unmaximize();
        _appBounds = await windowManager.getBounds();
        // The smaller minimum first, or Windows keeps the window large.
        await windowManager.setMinimumSize(compactSize);
        await _fixed(true);
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        await windowManager.setSize(compactSize);
        await windowManager.center();
      } else {
        await _fixed(false);
        await windowManager.setMinimumSize(appMinimumSize);
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: false,
        );
        final bounds = _appBounds;
        if (bounds == null) {
          await windowManager.setSize(appSize);
          await windowManager.center();
        } else {
          await windowManager.setBounds(bounds);
        }
        if (_appMaximized) await windowManager.maximize();
      }
      _compact = compact;
    });
    _changes = change.then((_) {}, onError: (_) {});
    return change;
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
