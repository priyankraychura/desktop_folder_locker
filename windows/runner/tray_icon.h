#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>

// The app's icon in the Windows notification area ("system tray").
//
// Dart controls it through the "folder_locker/tray" method channel:
//   show   {tooltip, attention, menu: [{id, label, enabled} | {separator}]}
//   hide
//   notify {title, body}
// and is told about "activate" (click on the icon or on a notification)
// and "menuItem" (the id of the chosen menu entry).
//
// The icon has a hidden window of its own, which gets its messages and
// owns its menu: the menu needs its owner in the foreground, and that
// mustn't bring the app's window forward.
class TrayIcon {
 public:
  explicit TrayIcon(flutter::BinaryMessenger* messenger);
  ~TrayIcon();

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);

  // Handles a message of the icon's window. Returns true when the message
  // was consumed.
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

  struct MenuItem {
    std::string id;
    std::wstring label;
    bool enabled = true;
    bool separator = false;
  };

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool Show(const std::wstring& tooltip, bool attention);
  void Hide();
  bool Notify(const std::wstring& title, const std::wstring& body);
  void ShowMenu(int x, int y);
  NOTIFYICONDATAW BaseData() const;

  HWND window_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::vector<MenuItem> menu_;
  std::wstring tooltip_;
  bool attention_ = false;
  bool visible_ = false;
  HICON normal_icon_ = nullptr;
  HICON attention_icon_ = nullptr;
  HICON large_icon_ = nullptr;
  UINT taskbar_created_message_ = 0;
};

#endif  // RUNNER_TRAY_ICON_H_
