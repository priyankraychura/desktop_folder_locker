#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <flutter/method_channel.h>

#include <memory>
#include <optional>

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
  // Colors Windows' title bar as |title_bar_| says, if it says.
  void ApplyTitleBar();

  // Gives the window's content |height| logical pixels, keeping it
  // centered where it is, inside the work area of its screen. With
  // |glide|, a visible window glides there (|fit_|, a step each timer
  // tick), so what it shows stays still instead of jumping.
  void FitHeight(double height, bool glide);
  void StepFit();

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
  //   fitHeight [height, glide]  gives the window's content that height
  //       (logical pixels), keeping it centered where it is, inside the
  //       work area; gliding there if asked, while it shows
  //   titleBarColors [background, text, dark]  colors Windows' title bar
  //       (ARGB) like the page under it, with light or dark buttons
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // Windows' title bar, as Dart last asked for it.
  struct TitleBarColors {
    COLORREF background;
    COLORREF text;
    BOOL dark;
  };
  std::optional<TitleBarColors> title_bar_;

  // The glide FitHeight started: outer top and height, in physical pixels,
  // and when it started (0: at once).
  struct Fit {
    int from_top;
    int from_height;
    int to_top;
    int to_height;
    ULONGLONG start;
  };
  std::optional<Fit> fit_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
