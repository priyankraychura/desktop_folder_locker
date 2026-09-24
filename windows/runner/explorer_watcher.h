#ifndef RUNNER_EXPLORER_WATCHER_H_
#define RUNNER_EXPLORER_WATCHER_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Tells Dart which folders Explorer's windows and tabs show, as soon as
// that changes: a window opens, goes to another folder, or closes. Dart
// uses it to ask right away whether to lock an unlocked folder again once
// no window shows it any more.
//
// Explorer says so itself, through events: ShellWindows' (a window was
// registered or revoked) and each window's own (it navigated, or quit).
// Those arrive on a thread of its own, which also asks Explorer for each
// window's folder: Explorer answers from its process, and a busy Explorer
// must not hold up the app's window. A timer looks again every few
// seconds, in case an event went missing, and reconnects after Explorer
// restarted.
//
// Dart controls it through the "cloak/explorer" method channel:
//   watch   starts watching (again: sends what's shown now)
// and is told about "changed" {folders: [path…], window: [left, top,
// right, bottom] or null}: the folders shown now, and where the Explorer
// window whose change it was is on the screen (physical pixels), to show
// the question over it.
class ExplorerWatcher {
 public:
  explicit ExplorerWatcher(flutter::BinaryMessenger* messenger);
  ~ExplorerWatcher();

  ExplorerWatcher(const ExplorerWatcher&) = delete;
  ExplorerWatcher& operator=(const ExplorerWatcher&) = delete;

  // The watching thread's side. Defined in the .cpp file.
  class Worker;

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Starts the thread, or asks it to send what's shown now.
  bool Watch();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  // Receives the thread's changes, on the app's thread.
  HWND window_ = nullptr;
  HANDLE thread_ = nullptr;
  // The thread's window, which takes its requests.
  HWND worker_window_ = nullptr;
};

#endif  // RUNNER_EXPLORER_WATCHER_H_
