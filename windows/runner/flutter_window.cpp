#include "flutter_window.h"

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
    const int x = std::clamp((area.left + area.right - width) / 2,
                             static_cast<int>(work.left),
                             std::max(static_cast<int>(work.left),
                                      static_cast<int>(work.right) - width));
    const int y = std::clamp((area.top + area.bottom - height) / 2,
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

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
