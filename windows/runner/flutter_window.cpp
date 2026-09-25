#include "flutter_window.h"

#include <dwmapi.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <optional>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Centers |window| over |area|, inside the work area of the screen that
// shows most of |area|.
void PlaceOver(HWND window, const RECT& area) {
  const HMONITOR monitor = ::MonitorFromRect(&area, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  if (!::GetMonitorInfoW(monitor, &info)) {
    return;
  }
  const RECT& work = info.rcWork;
  // Twice: moving to a screen with another scale resizes the window.
  for (int pass = 0; pass < 2; ++pass) {
    RECT bounds;
    if (!::GetWindowRect(window, &bounds)) {
      return;
    }
    const int width = bounds.right - bounds.left;
    const int height = bounds.bottom - bounds.top;
    // All three of the same type: RECT's members are LONG.
    const int x = std::clamp(
        static_cast<int>((area.left + area.right - width) / 2),
        static_cast<int>(work.left),
        std::max(static_cast<int>(work.left),
                 static_cast<int>(work.right) - width));
    const int y = std::clamp(
        static_cast<int>((area.top + area.bottom - height) / 2),
        static_cast<int>(work.top),
        std::max(static_cast<int>(work.top),
                 static_cast<int>(work.bottom) - height));
    if (x == bounds.left && y == bounds.top) {
      return;
    }
    ::SetWindowPos(window, nullptr, x, y, 0, 0,
                   SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  }
}

// Brings |window| to the front and gives it the focus. Windows lets only
// the app the user works with do that, so this borrows its input for a
// moment: the user just closed a folder there, and the question is the
// answer to that.
void ToFront(HWND window) {
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  }
  const HWND foreground = ::GetForegroundWindow();
  if (foreground == window) {
    return;
  }
  const DWORD own_thread = ::GetCurrentThreadId();
  const DWORD foreground_thread =
      foreground != nullptr
          ? ::GetWindowThreadProcessId(foreground, nullptr)
          : 0;
  const bool attached = foreground_thread != 0 &&
                        foreground_thread != own_thread &&
                        ::AttachThreadInput(own_thread, foreground_thread,
                                            TRUE);
  ::BringWindowToTop(window);
  // Activating it gives the Flutter view the keyboard (Win32Window).
  ::SetForegroundWindow(window);
  if (attached) {
    ::AttachThreadInput(own_thread, foreground_thread, FALSE);
  }
  if (::GetForegroundWindow() != window) {
    // Windows didn't allow it: above the other windows at least, where
    // it's seen, and flashing in the taskbar.
    ::SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    ::SetWindowPos(window, HWND_NOTOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    ::FlashWindow(window, TRUE);
  }
}

// Windows 11's title bar colors; Windows 10 ignores them.
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
#ifndef DWMWA_CAPTION_COLOR
#define DWMWA_CAPTION_COLOR 35
#endif
#ifndef DWMWA_TEXT_COLOR
#define DWMWA_TEXT_COLOR 36
#endif

// Gives the content of |window| |height| logical pixels, keeping the
// window centered where it is, inside the work area of its screen.
void FitHeight(HWND window, double height) {
  RECT bounds;
  RECT client;
  if (!::GetWindowRect(window, &bounds) || !::GetClientRect(window, &client)) {
    return;
  }
  const double scale = ::GetDpiForWindow(window) / 96.0;
  const int frame =
      (bounds.bottom - bounds.top) - (client.bottom - client.top);
  int outer = static_cast<int>(height * scale + 0.5) + frame;
  const int width = bounds.right - bounds.left;
  int y = (bounds.top + bounds.bottom - outer) / 2;
  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  if (::GetMonitorInfoW(::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                        &info)) {
    const RECT& work = info.rcWork;
    outer = std::min(outer, static_cast<int>(work.bottom - work.top));
    y = std::clamp(y, static_cast<int>(work.top),
                   static_cast<int>(work.bottom) - outer);
  }
  if (outer == bounds.bottom - bounds.top && y == bounds.top) {
    return;
  }
  ::SetWindowPos(window, nullptr, bounds.left, y, width, outer,
                 SWP_NOZORDER | SWP_NOACTIVATE);
}

// ARGB, as Dart's Color, to a COLORREF.
COLORREF ToColorRef(int64_t argb) {
  return RGB((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);
}

// An int from Dart, which sends large ones as int64.
std::optional<int64_t> GetInt(const flutter::EncodableValue& value) {
  if (const auto* small = std::get_if<int32_t>(&value)) {
    return *small;
  }
  if (const auto* large = std::get_if<int64_t>(&value)) {
    return *large;
  }
  return std::nullopt;
}

// [left, top, right, bottom], or false.
bool GetRect(const flutter::EncodableValue* value, RECT* rect) {
  const auto* list =
      value != nullptr ? std::get_if<flutter::EncodableList>(value) : nullptr;
  if (list == nullptr || list->size() != 4) {
    return false;
  }
  LONG parts[4];
  for (size_t i = 0; i < 4; ++i) {
    const auto* part = std::get_if<int32_t>(&(*list)[i]);
    if (part == nullptr) {
      return false;
    }
    parts[i] = *part;
  }
  *rect = RECT{parts[0], parts[1], parts[2], parts[3]};
  return true;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  flutter::BinaryMessenger* messenger =
      flutter_controller_->engine()->messenger();
  tray_icon_ = std::make_unique<TrayIcon>(messenger);
  explorer_watcher_ = std::make_unique<ExplorerWatcher>(messenger);
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "cloak/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const HWND window = GetHandle();
        if (call.method_name() == "placeOver") {
          RECT area;
          if (!GetRect(call.arguments(), &area)) {
            result->Error("bad-arguments", "Expected [left, top, right, bottom]");
            return;
          }
          PlaceOver(window, area);
          result->Success();
        } else if (call.method_name() == "toFront") {
          ToFront(window);
          result->Success(
              flutter::EncodableValue(::GetForegroundWindow() == window));
        } else if (call.method_name() == "fitHeight") {
          const auto* height =
              call.arguments() != nullptr
                  ? std::get_if<double>(call.arguments())
                  : nullptr;
          if (height == nullptr || *height <= 0) {
            result->Error("bad-arguments", "Expected a height");
            return;
          }
          FitHeight(window, *height);
          result->Success();
        } else if (call.method_name() == "titleBarColors") {
          const auto* list =
              call.arguments() != nullptr
                  ? std::get_if<flutter::EncodableList>(call.arguments())
                  : nullptr;
          const auto background =
              list != nullptr && list->size() == 3 ? GetInt((*list)[0])
                                                   : std::nullopt;
          const auto text =
              list != nullptr && list->size() == 3 ? GetInt((*list)[1])
                                                   : std::nullopt;
          const auto* dark =
              list != nullptr && list->size() == 3
                  ? std::get_if<bool>(&(*list)[2])
                  : nullptr;
          if (!background || !text || dark == nullptr) {
            result->Error("bad-arguments", "Expected [background, text, dark]");
            return;
          }
          title_bar_ = TitleBarColors{ToColorRef(*background),
                                      ToColorRef(*text), *dark ? TRUE : FALSE};
          ApplyTitleBar();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // The window stays hidden until Dart shows it (window_manager), after the
  // custom title bar is configured. A second copy of the app started by
  // Explorer forwards its arguments and exits without ever showing a window.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::ApplyTitleBar() {
  if (!title_bar_) {
    return;
  }
  const HWND window = GetHandle();
  ::DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &title_bar_->dark, sizeof(title_bar_->dark));
  ::DwmSetWindowAttribute(window, DWMWA_CAPTION_COLOR,
                          &title_bar_->background,
                          sizeof(title_bar_->background));
  ::DwmSetWindowAttribute(window, DWMWA_TEXT_COLOR, &title_bar_->text,
                          sizeof(title_bar_->text));
}

void FlutterWindow::OnDestroy() {
  if (window_channel_) {
    window_channel_->SetMethodCallHandler(nullptr);
    window_channel_ = nullptr;
  }
  explorer_watcher_ = nullptr;
  tray_icon_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Windows signs out or shuts down, or an installer updating the app asks
  // it to close (Restart Manager). Closing the window only hides the app in
  // the notification area, so quit instead: its files can then be replaced.
  // Unlocked items stay as they are, the drive helper stops once the app is
  // gone, and the journal finishes an interrupted operation next time.
  switch (message) {
    case WM_QUERYENDSESSION:
      return TRUE;
    case WM_ENDSESSION:
      if (wparam) {
        ::DestroyWindow(hwnd);
      }
      return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  const LRESULT result =
      Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  // Win32Window puts Windows' light or dark title bar back; the app's
  // colors stay.
  if (message == WM_DWMCOLORIZATIONCOLORCHANGED) {
    ApplyTitleBar();
  }
  return result;
}
