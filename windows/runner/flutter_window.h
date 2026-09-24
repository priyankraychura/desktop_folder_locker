#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <flutter/method_channel.h>

#include <memory>

#include "explorer_watcher.h"
#include "tray_icon.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // The notification-area icon, controlled from Dart.
  std::unique_ptr<TrayIcon> tray_icon_;

  // The folders Explorer shows, told to Dart as they change.
  std::unique_ptr<ExplorerWatcher> explorer_watcher_;

  // What window_manager can't do, for Dart ("cloak/window"):
  //   placeOver [left, top, right, bottom]  centers the window over that
  //       area (physical pixels, as ExplorerWatcher tells it), inside the
  //       work area of its screen
  //   toFront  brings the window to the front even though another app has
  //       the focus, as a question the user expects right now should
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
