import 'package:window_manager/window_manager.dart';

/// Brings the main window to the front (from the notification area, the
/// taskbar, or behind other windows).
Future<void> showMainWindow() async {
  if (await windowManager.isMinimized()) await windowManager.restore();
  await windowManager.show();
  await windowManager.focus();
}
