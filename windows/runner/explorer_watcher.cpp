#include "explorer_watcher.h"

#include <exdisp.h>
#include <exdispid.h>
#include <flutter/standard_method_codec.h>
#include <ocidl.h>
#include <shlguid.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <algorithm>
#include <atomic>
#include <deque>
#include <functional>
#include <map>
#include <string>
#include <utility>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

constexpr char kChannelName[] = "cloak/explorer";
constexpr wchar_t kResultsWindowClass[] = L"CloakExplorerResults";
constexpr wchar_t kWorkerWindowClass[] = L"CloakExplorerWatcher";

// On the app's thread: the thread's news.
constexpr UINT kChanged = WM_APP + 1;

// On the watching thread: work to do, and Dart asking again.
constexpr UINT kWork = WM_APP + 1;
constexpr UINT kRepublish = WM_APP + 2;

// Looks again in case an event went missing, and reconnects after
// Explorer restarted.
constexpr UINT_PTR kPollTimer = 1;
constexpr UINT kPollInterval = 5000;
// A window that just opened may show its folder only after the events
// that would say so (they can come before the window is watched): looks
// again a few times, soon.
constexpr UINT_PTR kSettleTimer = 2;
constexpr UINT kSettleInterval = 300;
constexpr int kSettleTicks = 5;

// What Explorer shows now, and the window whose change it was.
struct Change {
  std::vector<std::wstring> folders;
  bool has_window = false;
  RECT window = {};
};

std::string Utf8FromUtf16(const std::wstring& text) {
  if (text.empty()) {
    return std::string();
  }
  const int length = ::WideCharToMultiByte(
      CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0,
      nullptr, nullptr);
  if (length <= 0) {
    return std::string();
  }
  std::string result(length, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, text.data(),
                        static_cast<int>(text.size()), result.data(), length,
                        nullptr, nullptr);
  return result;
}

// Receives one kind of events (a dispinterface) and hands their ids to
// |handler|, on the watching thread. Explorer may hold on to it after the
// watcher let go: Detach() makes it ignore everything from then on.
class EventSink : public IDispatch {
 public:
  EventSink(REFIID events, std::function<void(DISPID)> handler)
      : events_(events), handler_(std::move(handler)) {}

  void Detach() { handler_ = nullptr; }

  // IUnknown
  IFACEMETHODIMP QueryInterface(REFIID iid, void** object) override {
    if (object == nullptr) {
      return E_POINTER;
    }
    if (iid == IID_IUnknown || iid == IID_IDispatch || iid == events_) {
      *object = static_cast<IDispatch*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }

  IFACEMETHODIMP_(ULONG) AddRef() override { return ++references_; }

  IFACEMETHODIMP_(ULONG) Release() override {
    const ULONG left = --references_;
    if (left == 0) {
      delete this;
    }
    return left;
  }

  // IDispatch: only Invoke is used, by id.
  IFACEMETHODIMP GetTypeInfoCount(UINT* count) override {
    if (count == nullptr) {
      return E_POINTER;
    }
    *count = 0;
    return S_OK;
  }

  IFACEMETHODIMP GetTypeInfo(UINT, LCID, ITypeInfo**) override {
    return E_NOTIMPL;
  }

  IFACEMETHODIMP GetIDsOfNames(REFIID, LPOLESTR*, UINT, LCID,
                               DISPID*) override {
    return E_NOTIMPL;
  }

  IFACEMETHODIMP Invoke(DISPID id, REFIID, LCID, WORD, DISPPARAMS*, VARIANT*,
                        EXCEPINFO*, UINT*) override {
    if (handler_) {
      handler_(id);
    }
    return S_OK;
  }

 private:
  ~EventSink() = default;

  const IID events_;
  std::function<void(DISPID)> handler_;
  std::atomic<ULONG> references_{1};
};

// Connects |sink| to |source|'s events |events|. Returns the connection
// point and fills |cookie|, or returns null.
ComPtr<IConnectionPoint> Advise(IUnknown* source, REFIID events,
                                EventSink* sink, DWORD* cookie) {
  ComPtr<IConnectionPointContainer> container;
  ComPtr<IConnectionPoint> point;
  if (FAILED(source->QueryInterface(IID_PPV_ARGS(&container))) ||
      FAILED(container->FindConnectionPoint(events, &point)) ||
      FAILED(point->Advise(sink, cookie))) {
    return nullptr;
  }
  return point;
}

// The folder that one shell window shows, if it's on a disk (like
// `folder_of` in native/shell/src/shown.rs).
std::wstring FolderOf(IDispatch* window) {
  ComPtr<IServiceProvider> services;
  ComPtr<IShellBrowser> browser;
  ComPtr<IShellView> view;
  ComPtr<IFolderView> folder_view;
  ComPtr<IPersistFolder2> folder;
  PIDLIST_ABSOLUTE id = nullptr;
  if (FAILED(window->QueryInterface(IID_PPV_ARGS(&services))) ||
      FAILED(services->QueryService(SID_STopLevelBrowser,
                                    IID_PPV_ARGS(&browser))) ||
      FAILED(browser->QueryActiveShellView(&view)) ||
      FAILED(view.As(&folder_view)) ||
      FAILED(folder_view->GetFolder(IID_PPV_ARGS(&folder))) ||
      FAILED(folder->GetCurFolder(&id))) {
    return std::wstring();
  }
  PWSTR name = nullptr;
  const HRESULT named = ::SHGetNameFromIDList(id, SIGDN_FILESYSPATH, &name);
  ::CoTaskMemFree(id);
  if (FAILED(named)) {
    return std::wstring();
  }
  std::wstring path(name);
  ::CoTaskMemFree(name);
  return path;
}

}  // namespace

// Lives on the watching thread, a single-threaded COM apartment: Explorer's
// events arrive there, through its message loop.
//
// An event only notes what to do; the work runs after the event returned,
// one piece at a time. Asking Explorer from inside its own call could fail
// (it may be in the middle of closing the window), and asking Explorer
// lets COM deliver other events and messages meanwhile.
class ExplorerWatcher::Worker {
 public:
  explicit Worker(HWND results) : results_(results) {}

  // The thread: runs until its window gets WM_CLOSE.
  struct Start {
    HWND results = nullptr;
    HANDLE ready = nullptr;
    HWND window = nullptr;
  };

  static DWORD WINAPI Run(void* parameter) {
    auto* start = static_cast<Start*>(parameter);
    const HRESULT com = ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    auto* worker = new Worker(start->results);
    worker->window_ = ::CreateWindowExW(
        0, kWorkerWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
        ::GetModuleHandleW(nullptr), worker);
    start->window = worker->window_;
    ::SetEvent(start->ready);
    // |start| belongs to the app's thread from here on.

    if (worker->window_ != nullptr) {
      ::SetTimer(worker->window_, kPollTimer, kPollInterval, nullptr);
      worker->Queue({Work::kConnect, 0});
      ::MSG message;
      while (::GetMessageW(&message, nullptr, 0, 0) > 0) {
        ::TranslateMessage(&message);
        ::DispatchMessageW(&message);
      }
    }
    delete worker;
    if (SUCCEEDED(com)) {
      ::CoUninitialize();
    }
    return 0;
  }

  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam) {
    if (message == WM_NCCREATE) {
      const auto* create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
      ::SetWindowLongPtrW(window, GWLP_USERDATA,
                          reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    } else if (auto* worker = reinterpret_cast<Worker*>(
                   ::GetWindowLongPtrW(window, GWLP_USERDATA))) {
      if (worker->HandleMessage(message, wparam)) {
        return 0;
      }
    }
    return ::DefWindowProcW(window, message, wparam, lparam);
  }

 private:
  struct Work {
    enum Kind { kConnect, kSync, kRefresh, kQuit, kRepublish } kind;
    // The window, for kRefresh and kQuit.
    int id;
  };

  // One Explorer window or tab.
  struct Browser {
    ComPtr<IUnknown> identity;
    ComPtr<IDispatch> window;
    ComPtr<IConnectionPoint> point;
    DWORD cookie = 0;
    EventSink* sink = nullptr;
    HWND frame = nullptr;
    // Where it was last seen: a window that's gone can't be asked.
    RECT bounds = {};
    bool has_bounds = false;
    std::wstring folder;
  };

  ~Worker() {
    Disconnect();
    if (window_ != nullptr) {
      ::SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
    }
  }

  bool HandleMessage(UINT message, WPARAM wparam) {
    switch (message) {
      case kWork:
        Drain();
        return true;
      case kRepublish:
        Queue({Work::kRepublish, 0});
        return true;
      case WM_TIMER:
        if (wparam == kSettleTimer && --settle_ticks_ <= 0) {
          ::KillTimer(window_, kSettleTimer);
        }
        Queue({connected_ ? Work::kSync : Work::kConnect, 0});
        return true;
      case WM_CLOSE:
        // Not in the middle of the work: it may be going through the
        // windows.
        closing_ = true;
        if (!busy_) {
          Close();
        }
        return true;
      default:
        return false;
    }
  }

  void Close() {
    ::KillTimer(window_, kPollTimer);
    ::KillTimer(window_, kSettleTimer);
    Disconnect();
    ::DestroyWindow(window_);
    window_ = nullptr;
    ::PostQuitMessage(0);
  }

  void Queue(Work work) {
    pending_.push_back(work);
    if (window_ != nullptr) {
      ::PostMessageW(window_, kWork, 0, 0);
    }
  }

  // Does the pending work, unless it's being done already: asking
  // Explorer can bring in the next message before the answer.
  void Drain() {
    if (busy_) {
      return;
    }
    busy_ = true;
    while (!pending_.empty() && !closing_) {
      const Work work = pending_.front();
      pending_.pop_front();
      switch (work.kind) {
        case Work::kConnect:
          if (!connected_) {
            Connect();
          }
          break;
        case Work::kSync:
          if (connected_) {
            Sync();
          }
          break;
        case Work::kRefresh:
          Refresh(work.id);
          break;
        case Work::kQuit:
          Quit(work.id);
          break;
        case Work::kRepublish:
          if (connected_) {
            Publish(nullptr, /*always=*/true);
          }
          break;
      }
    }
    busy_ = false;
    if (closing_ && window_ != nullptr) {
      Close();
    }
  }

  void Connect() {
    if (FAILED(::CoCreateInstance(CLSID_ShellWindows, nullptr, CLSCTX_ALL,
                                  IID_PPV_ARGS(&shell_windows_)))) {
      shell_windows_ = nullptr;
      return;
    }
    shell_sink_ = new EventSink(DIID_DShellWindowsEvents, [this](DISPID id) {
      if (id == DISPID_WINDOWREGISTERED || id == DISPID_WINDOWREVOKED) {
        Queue({Work::kSync, 0});
      }
    });
    shell_point_ = Advise(shell_windows_.Get(), DIID_DShellWindowsEvents,
                          shell_sink_, &shell_cookie_);
    connected_ = true;
    Sync();
    // What's shown now, even if it's what Dart last heard (after Explorer
    // restarted, the windows it reopened).
    if (connected_) {
      Publish(nullptr, /*always=*/true);
    }
  }

  // Lets go of Explorer: it restarted, or the watcher stops.
  void Disconnect() {
    for (auto& [id, browser] : browsers_) {
      Release(browser);
    }
    browsers_.clear();
    if (shell_sink_ != nullptr) {
      shell_sink_->Detach();
      if (shell_point_) {
        shell_point_->Unadvise(shell_cookie_);
      }
      shell_sink_->Release();
      shell_sink_ = nullptr;
    }
    shell_point_ = nullptr;
    shell_windows_ = nullptr;
    connected_ = false;
  }

  // Watches the windows that opened and forgets the ones that closed.
  // Also looks again at every window's folder.
  void Sync() {
    long count = 0;
    if (FAILED(shell_windows_->get_Count(&count))) {
      // Explorer is gone. What Dart heard last stays until it's back: an
      // Explorer that restarts closes no folder.
      Disconnect();
      return;
    }
    std::map<IUnknown*, int> known;
    for (const auto& [id, browser] : browsers_) {
      known[browser.identity.Get()] = id;
    }
    std::vector<int> present;
    bool added = false;
    for (long index = 0; index < count; ++index) {
      VARIANT item;
      ::VariantInit(&item);
      item.vt = VT_I4;
      item.lVal = index;
      ComPtr<IDispatch> window;
      ComPtr<IUnknown> identity;
      // A window that closed meanwhile is simply missing.
      if (FAILED(shell_windows_->Item(item, &window)) || !window ||
          FAILED(window.As(&identity))) {
        continue;
      }
      const auto it = known.find(identity.Get());
      if (it != known.end()) {
        present.push_back(it->second);
      } else {
        present.push_back(Add(window, identity));
        added = true;
      }
    }

    const RECT* changed = nullptr;
    for (auto it = browsers_.begin(); it != browsers_.end();) {
      Browser& browser = it->second;
      if (std::find(present.begin(), present.end(), it->first) ==
          present.end()) {
        if (!browser.folder.empty() && browser.has_bounds) {
          last_changed_ = browser.bounds;
          changed = &last_changed_;
        }
        Release(browser);
        it = browsers_.erase(it);
        continue;
      }
      UpdateBounds(browser);
      std::wstring folder = FolderOf(browser.window.Get());
      if (folder != browser.folder) {
        browser.folder = std::move(folder);
        if (browser.has_bounds) {
          last_changed_ = browser.bounds;
          changed = &last_changed_;
        }
      }
      ++it;
    }
    if (added) {
      settle_ticks_ = kSettleTicks;
      ::SetTimer(window_, kSettleTimer, kSettleInterval, nullptr);
    }
    Publish(changed, /*always=*/false);
  }

  int Add(const ComPtr<IDispatch>& window, const ComPtr<IUnknown>& identity) {
    const int id = next_id_++;
    Browser browser;
    browser.identity = identity;
    browser.window = window;
    browser.sink = new EventSink(DIID_DWebBrowserEvents2, [this, id](DISPID d) {
      OnBrowserEvent(id, d);
    });
    browser.point = Advise(window.Get(), DIID_DWebBrowserEvents2, browser.sink,
                           &browser.cookie);
    ComPtr<IWebBrowser2> web;
    SHANDLE_PTR frame = 0;
    if (SUCCEEDED(window.As(&web)) && SUCCEEDED(web->get_HWND(&frame))) {
      browser.frame = reinterpret_cast<HWND>(frame);
    }
    browsers_.emplace(id, std::move(browser));
    return id;
  }

  void Release(Browser& browser) {
    if (browser.sink == nullptr) {
      return;
    }
    browser.sink->Detach();
    if (browser.point) {
      browser.point->Unadvise(browser.cookie);
    }
    browser.sink->Release();
    browser.sink = nullptr;
    browser.point = nullptr;
  }

  void UpdateBounds(Browser& browser) {
    RECT bounds;
    if (browser.frame != nullptr && ::IsWindow(browser.frame) &&
        ::GetWindowRect(browser.frame, &bounds)) {
      browser.bounds = bounds;
      browser.has_bounds = true;
    }
  }

  // Inside Explorer's call: only notes what to do.
  void OnBrowserEvent(int id, DISPID event) {
    switch (event) {
      case DISPID_ONQUIT: {
        // The window still exists now: where it is, to ask over it.
        const auto it = browsers_.find(id);
        if (it != browsers_.end()) {
          UpdateBounds(it->second);
        }
        Queue({Work::kQuit, id});
        break;
      }
      case DISPID_NAVIGATECOMPLETE2:
      case DISPID_DOCUMENTCOMPLETE:
        Queue({Work::kRefresh, id});
        break;
      default:
        break;
    }
  }

  // A window went to another folder.
  void Refresh(int id) {
    const auto it = browsers_.find(id);
    if (it == browsers_.end()) {
      return;
    }
    Browser& browser = it->second;
    UpdateBounds(browser);
    std::wstring folder = FolderOf(browser.window.Get());
    if (folder == browser.folder) {
      return;
    }
    browser.folder = std::move(folder);
    last_changed_ = browser.bounds;
    Publish(browser.has_bounds ? &last_changed_ : nullptr, /*always=*/false);
  }

  // A window or tab closed: it's gone from the list right away, without
  // waiting for Explorer to revoke it.
  void Quit(int id) {
    const auto it = browsers_.find(id);
    if (it == browsers_.end()) {
      return;
    }
    const bool has_bounds = it->second.has_bounds;
    last_changed_ = it->second.bounds;
    Release(it->second);
    browsers_.erase(it);
    Publish(has_bounds ? &last_changed_ : nullptr, /*always=*/false);
  }

  // Sends the folders shown now to the app's thread, if they changed.
  void Publish(const RECT* window, bool always) {
    std::vector<std::wstring> folders;
    for (const auto& [id, browser] : browsers_) {
      if (!browser.folder.empty()) {
        folders.push_back(browser.folder);
      }
    }
    std::vector<std::wstring> sorted = folders;
    std::sort(sorted.begin(), sorted.end());
    if (!always && sorted == published_) {
      return;
    }
    published_ = std::move(sorted);
    auto* change = new Change();
    change->folders = std::move(folders);
    if (window != nullptr) {
      change->has_window = true;
      change->window = *window;
    }
    if (!::PostMessageW(results_, kChanged, 0,
                        reinterpret_cast<LPARAM>(change))) {
      delete change;
    }
  }

  const HWND results_;
  HWND window_ = nullptr;
  ComPtr<IShellWindows> shell_windows_;
  ComPtr<IConnectionPoint> shell_point_;
  DWORD shell_cookie_ = 0;
  EventSink* shell_sink_ = nullptr;
  bool connected_ = false;
  std::map<int, Browser> browsers_;
  int next_id_ = 1;
  std::deque<Work> pending_;
  bool busy_ = false;
  bool closing_ = false;
  int settle_ticks_ = 0;
  RECT last_changed_ = {};
  // What Dart heard last, sorted.
  std::vector<std::wstring> published_;
};

ExplorerWatcher::ExplorerWatcher(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName,
          &flutter::StandardMethodCodec::GetInstance())) {
  const HINSTANCE instance = ::GetModuleHandleW(nullptr);
  WNDCLASSEXW window_class = {};
  window_class.cbSize = sizeof(window_class);
  window_class.hInstance = instance;
  window_class.lpfnWndProc = ExplorerWatcher::WindowProc;
  window_class.lpszClassName = kResultsWindowClass;
  ::RegisterClassExW(&window_class);
  window_class.lpfnWndProc = Worker::WindowProc;
  window_class.lpszClassName = kWorkerWindowClass;
  ::RegisterClassExW(&window_class);
  window_ = ::CreateWindowExW(0, kResultsWindowClass, L"", 0, 0, 0, 0, 0,
                              HWND_MESSAGE, nullptr, instance, this);
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

ExplorerWatcher::~ExplorerWatcher() {
  channel_->SetMethodCallHandler(nullptr);
  // Changes still on their way are dropped (and freed) from here on.
  if (window_ != nullptr) {
    ::SetWindowLongPtrW(window_, GWLP_USERDATA, 0);
    ::DestroyWindow(window_);
    window_ = nullptr;
  }
  if (thread_ != nullptr) {
    if (worker_window_ != nullptr) {
      ::PostMessageW(worker_window_, WM_CLOSE, 0, 0);
    }
    // Letting go of Explorer asks Explorer: a hung one mustn't keep the
    // app from closing. The thread ends with the process then.
    ::WaitForSingleObject(thread_, 2000);
    ::CloseHandle(thread_);
  }
}

LRESULT CALLBACK ExplorerWatcher::WindowProc(HWND window, UINT message,
                                             WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<const CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  } else if (message == kChanged) {
    std::unique_ptr<Change> change(reinterpret_cast<Change*>(lparam));
    auto* watcher = reinterpret_cast<ExplorerWatcher*>(
        ::GetWindowLongPtrW(window, GWLP_USERDATA));
    if (watcher != nullptr) {
      flutter::EncodableList folders;
      for (const auto& folder : change->folders) {
        folders.emplace_back(Utf8FromUtf16(folder));
      }
      flutter::EncodableValue bounds;
      if (change->has_window) {
        const RECT& r = change->window;
        bounds = flutter::EncodableValue(flutter::EncodableList{
            flutter::EncodableValue(static_cast<int32_t>(r.left)),
            flutter::EncodableValue(static_cast<int32_t>(r.top)),
            flutter::EncodableValue(static_cast<int32_t>(r.right)),
            flutter::EncodableValue(static_cast<int32_t>(r.bottom))});
      }
      watcher->channel_->InvokeMethod(
          "changed", std::make_unique<flutter::EncodableValue>(
                         flutter::EncodableMap{
                             {flutter::EncodableValue("folders"),
                              flutter::EncodableValue(std::move(folders))},
                             {flutter::EncodableValue("window"), bounds},
                         }));
    }
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

void ExplorerWatcher::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "watch") {
    result->Success(flutter::EncodableValue(Watch()));
  } else {
    result->NotImplemented();
  }
}

bool ExplorerWatcher::Watch() {
  if (window_ == nullptr) {
    return false;
  }
  if (thread_ != nullptr) {
    return worker_window_ != nullptr &&
           ::PostMessageW(worker_window_, kRepublish, 0, 0) != FALSE;
  }
  Worker::Start start;
  start.results = window_;
  start.ready = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (start.ready == nullptr) {
    return false;
  }
  thread_ = ::CreateThread(nullptr, 0, Worker::Run, &start, 0, nullptr);
  if (thread_ != nullptr) {
    ::WaitForSingleObject(start.ready, INFINITE);
    worker_window_ = start.window;
  }
  ::CloseHandle(start.ready);
  return worker_window_ != nullptr;
}
