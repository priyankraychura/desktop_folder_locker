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
class TrayIcon {
 public:
  TrayIcon(HWND window, flutter::BinaryMessenger* messenger);
  ~TrayIcon();

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  // Handles tray messages sent to |window|. Returns true when the message
  // was consumed.
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
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

  HWND window_;
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
