#include "tray_icon.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <windowsx.h>

#include <variant>

#include "resource.h"

namespace {

constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kTrayIconId = 1;
constexpr char kChannelName[] = "folder_locker/tray";

std::wstring Utf16FromUtf8(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(
      CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring result(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.data(),
                        static_cast<int>(text.size()), result.data(), length);
  return result;
}

const flutter::EncodableValue* Find(const flutter::EncodableMap& map,
                                    const char* key) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  return it == map.end() ? nullptr : &it->second;
}

std::string GetString(const flutter::EncodableMap& map, const char* key) {
  const auto* value = Find(map, key);
  if (value == nullptr) {
    return std::string();
  }
  const auto* text = std::get_if<std::string>(value);
  return text != nullptr ? *text : std::string();
}

bool GetBool(const flutter::EncodableMap& map, const char* key,
             bool fallback) {
  const auto* value = Find(map, key);
  if (value == nullptr) {
    return fallback;
  }
  const auto* flag = std::get_if<bool>(value);
  return flag != nullptr ? *flag : fallback;
}

// Copies |text| into a fixed-size NOTIFYICONDATA field, cutting it if needed.
template <size_t N>
void CopyText(wchar_t (&buffer)[N], const std::wstring& text) {
  wcsncpy_s(buffer, N, text.c_str(), _TRUNCATE);
}

HICON LoadIconResource(int id, int size_metric_x, int size_metric_y) {
  return static_cast<HICON>(::LoadImageW(
      ::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(id), IMAGE_ICON,
      ::GetSystemMetrics(size_metric_x), ::GetSystemMetrics(size_metric_y),
      LR_DEFAULTCOLOR));
}

}  // namespace

TrayIcon::TrayIcon(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window),
      channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName,
          &flutter::StandardMethodCodec::GetInstance())) {
  taskbar_created_message_ = ::RegisterWindowMessageW(L"TaskbarCreated");
  normal_icon_ = LoadIconResource(IDI_APP_ICON, SM_CXSMICON, SM_CYSMICON);
  attention_icon_ =
      LoadIconResource(IDI_TRAY_ATTENTION, SM_CXSMICON, SM_CYSMICON);
  large_icon_ = LoadIconResource(IDI_APP_ICON, SM_CXICON, SM_CYICON);
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

TrayIcon::~TrayIcon() {
  channel_->SetMethodCallHandler(nullptr);
  Hide();
  for (HICON icon : {normal_icon_, attention_icon_, large_icon_}) {
    if (icon != nullptr) {
      ::DestroyIcon(icon);
    }
  }
}

bool TrayIcon::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    // Explorer restarted and forgot every icon: add ours again.
    if (visible_) {
      visible_ = false;
      Show(tooltip_, attention_);
    }
    return false;
  }
  if (message != kTrayMessage) {
    return false;
  }
  switch (LOWORD(lparam)) {
    case NIN_SELECT:
    case NIN_KEYSELECT:
    case NIN_BALLOONUSERCLICK:
      channel_->InvokeMethod("activate", nullptr);
      break;
    case WM_CONTEXTMENU:
      ShowMenu(GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam));
      break;
    default:
      break;
  }
  return true;
}

void TrayIcon::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
  const std::string& method = call.method_name();

  if (method == "show") {
    if (args == nullptr) {
      result->Error("bad-arguments", "Expected a map");
      return;
    }
    menu_.clear();
    if (const auto* value = Find(*args, "menu")) {
      if (const auto* list = std::get_if<flutter::EncodableList>(value)) {
        for (const auto& entry : *list) {
          const auto* map = std::get_if<flutter::EncodableMap>(&entry);
          if (map == nullptr) {
            continue;
          }
          MenuItem item;
          item.separator = GetBool(*map, "separator", false);
          item.id = GetString(*map, "id");
          item.label = Utf16FromUtf8(GetString(*map, "label"));
          item.enabled = GetBool(*map, "enabled", true);
          menu_.push_back(std::move(item));
        }
      }
    }
    const bool shown = Show(Utf16FromUtf8(GetString(*args, "tooltip")),
                            GetBool(*args, "attention", false));
    result->Success(flutter::EncodableValue(shown));
  } else if (method == "hide") {
    Hide();
    result->Success();
  } else if (method == "notify") {
    if (args == nullptr) {
      result->Error("bad-arguments", "Expected a map");
      return;
    }
    const bool shown = Notify(Utf16FromUtf8(GetString(*args, "title")),
                              Utf16FromUtf8(GetString(*args, "body")));
    result->Success(flutter::EncodableValue(shown));
  } else {
    result->NotImplemented();
  }
}

NOTIFYICONDATAW TrayIcon::BaseData() const {
  NOTIFYICONDATAW data = {};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kTrayIconId;
  return data;
}

bool TrayIcon::Show(const std::wstring& tooltip, bool attention) {
  tooltip_ = tooltip;
  attention_ = attention;
  NOTIFYICONDATAW data = BaseData();
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = attention && attention_icon_ != nullptr ? attention_icon_
                                                       : normal_icon_;
  CopyText(data.szTip, tooltip);

  if (visible_ && ::Shell_NotifyIconW(NIM_MODIFY, &data)) {
    return true;
  }
  if (!::Shell_NotifyIconW(NIM_ADD, &data)) {
    return false;
  }
  data.uVersion = NOTIFYICON_VERSION_4;
  ::Shell_NotifyIconW(NIM_SETVERSION, &data);
  visible_ = true;
  return true;
}

void TrayIcon::Hide() {
  if (!visible_) {
    return;
  }
  NOTIFYICONDATAW data = BaseData();
  ::Shell_NotifyIconW(NIM_DELETE, &data);
  visible_ = false;
}

bool TrayIcon::Notify(const std::wstring& title, const std::wstring& body) {
  if (!visible_) {
    return false;
  }
  // Windows 10 and 11 show this as a regular notification of the app.
  NOTIFYICONDATAW data = BaseData();
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_RESPECT_QUIET_TIME;
  if (large_icon_ != nullptr) {
    data.dwInfoFlags |= NIIF_USER | NIIF_LARGE_ICON;
    data.hBalloonIcon = large_icon_;
  } else {
    data.dwInfoFlags |= NIIF_INFO;
  }
  CopyText(data.szInfoTitle, title);
  CopyText(data.szInfo, body);
  return ::Shell_NotifyIconW(NIM_MODIFY, &data) != FALSE;
}

void TrayIcon::ShowMenu(int x, int y) {
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  for (size_t i = 0; i < menu_.size(); ++i) {
    const MenuItem& item = menu_[i];
    if (item.separator) {
      ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    } else {
      ::AppendMenuW(menu, MF_STRING | (item.enabled ? MF_ENABLED : MF_GRAYED),
                    static_cast<UINT_PTR>(i + 1), item.label.c_str());
    }
  }
  // Without this the menu would not close when clicking elsewhere.
  ::SetForegroundWindow(window_);
  UINT flags = TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON;
  flags |= ::GetSystemMetrics(SM_MENUDROPALIGNMENT) != 0 ? TPM_RIGHTALIGN
                                                         : TPM_LEFTALIGN;
  const int command =
      ::TrackPopupMenuEx(menu, flags, x, y, window_, nullptr);
  ::PostMessageW(window_, WM_NULL, 0, 0);
  ::DestroyMenu(menu);

  if (command > 0 && static_cast<size_t>(command) <= menu_.size()) {
    channel_->InvokeMethod(
        "menuItem",
        std::make_unique<flutter::EncodableValue>(menu_[command - 1].id));
  }
}
