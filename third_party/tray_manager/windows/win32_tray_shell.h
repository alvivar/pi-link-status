// Local addition to the vendored tray_manager copy (see ../../PATCHES.md).
//
// The Win32 half of the tray icon: NOTIFYICONDATA assembly, the recovery timer
// and the mapping from a failure to a method-channel answer. The plugin uses
// exactly this code; the Win32 entry points are injectable so the failure paths
// can be tested without a notification area, a window or a Flutter engine.

#ifndef TRAY_MANAGER_WINDOWS_WIN32_TRAY_SHELL_H_
#define TRAY_MANAGER_WINDOWS_WIN32_TRAY_SHELL_H_

// windows.h first: shellapi.h and strsafe.h are not self-contained.
#include <windows.h>

#include <shellapi.h>
#include <strsafe.h>

#include <functional>
#include <string>

#include "tray_icon.h"

namespace tray_manager {

// The message the notification area sends back for mouse input on the icon.
#ifndef WM_MYMESSAGE
#define WM_MYMESSAGE (WM_USER + 1)
#endif

// The Win32 calls the adapter makes. Function pointers rather than another
// virtual layer: production binds them to the real API once, tests bind them to
// recorded fakes, and nothing in between can accidentally reach the shell.
struct Win32Api {
  HICON (*load_image)(const wchar_t* path, int width, int height);
  BOOL (*notify_icon)(DWORD message, NOTIFYICONDATA* data);
  UINT_PTR (*set_timer)(HWND window, UINT_PTR id, UINT delay_ms);
  BOOL (*kill_timer)(HWND window, UINT_PTR id);
  BOOL (*destroy_icon)(HICON icon);
  DWORD (*last_error)();
};

namespace internal {

inline HICON RealLoadImage(const wchar_t* path, int width, int height) {
  return static_cast<HICON>(::LoadImage(nullptr, path, IMAGE_ICON, width,
                                        height, LR_LOADFROMFILE));
}

inline BOOL RealNotifyIcon(DWORD message, NOTIFYICONDATA* data) {
  return ::Shell_NotifyIcon(message, data);
}

inline UINT_PTR RealSetTimer(HWND window, UINT_PTR id, UINT delay_ms) {
  return ::SetTimer(window, id, delay_ms, nullptr);
}

inline BOOL RealKillTimer(HWND window, UINT_PTR id) {
  return ::KillTimer(window, id);
}

inline BOOL RealDestroyIcon(HICON icon) { return ::DestroyIcon(icon); }

inline DWORD RealLastError() { return ::GetLastError(); }

}  // namespace internal

// What the plugin runs with.
inline const Win32Api& RealWin32Api() {
  static const Win32Api api = {
      &internal::RealLoadImage,  &internal::RealNotifyIcon,
      &internal::RealSetTimer,   &internal::RealKillTimer,
      &internal::RealDestroyIcon, &internal::RealLastError,
  };
  return api;
}

// What the method channel answers. A failure never maps to success: the Dart
// API returns Future<void>, so a false payload would be dropped silently.
enum class ChannelDisposition {
  kSuccess,
  kIconLoadFailed,
  kShellRejected,
};

inline ChannelDisposition DispositionFor(TrayResult result) {
  switch (result) {
    case TrayResult::kOk:
      return ChannelDisposition::kSuccess;
    case TrayResult::kIconMissing:
      return ChannelDisposition::kIconLoadFailed;
    case TrayResult::kShellRejected:
      return ChannelDisposition::kShellRejected;
  }
  return ChannelDisposition::kShellRejected;
}

// The method-channel error code, or nullptr when there is nothing to report.
inline const char* ErrorCodeFor(ChannelDisposition disposition) {
  switch (disposition) {
    case ChannelDisposition::kSuccess:
      return nullptr;
    case ChannelDisposition::kIconLoadFailed:
      return "icon_load_failed";
    case ChannelDisposition::kShellRejected:
      return "shell_rejected";
  }
  return "shell_rejected";
}

class Win32TrayShell : public TrayShell {
 public:
  explicit Win32TrayShell(std::function<HWND()> main_window,
                          const Win32Api* api = &RealWin32Api())
      : main_window_(std::move(main_window)), api_(api) {}

  HICON LoadIconFile(const std::wstring& path) override {
    HICON icon = api_->load_image(path.c_str(), GetSystemMetrics(SM_CXSMICON),
                                 GetSystemMetrics(SM_CYSMICON));
    if (icon == nullptr) {
      last_error_ = api_->last_error();
    }
    return icon;
  }

  void DestroyIconHandle(HICON icon) override { api_->destroy_icon(icon); }

  bool Add(HICON icon, const std::wstring& tooltip) override {
    Fill(icon, tooltip);
    if (!api_->notify_icon(NIM_ADD, &nid_)) {
      last_error_ = api_->last_error();
      return false;
    }
    // Only a registration that exists can be identified.
    niif_.cbSize = sizeof(NOTIFYICONIDENTIFIER);
    niif_.hWnd = nid_.hWnd;
    niif_.uID = nid_.uID;
    niif_.guidItem = GUID_NULL;
    return true;
  }

  bool Modify(HICON icon, const std::wstring& tooltip) override {
    Fill(icon, tooltip);
    if (!api_->notify_icon(NIM_MODIFY, &nid_)) {
      last_error_ = api_->last_error();
      return false;
    }
    return true;
  }

  void Delete() override { api_->notify_icon(NIM_DELETE, &nid_); }

  bool ScheduleRetry(int delay_ms) override {
    // Retire the shot we already own before resolving the new one. Otherwise a
    // replacement that fails below would leave the old timer armed while the
    // state machine has given up on recovery, and a replacement on a new
    // window would orphan the old window's timer.
    CancelRetry();
    HWND window = main_window_();
    if (window == nullptr) {
      return false;
    }
    if (api_->set_timer(window, timer_id(), static_cast<UINT>(delay_ms)) == 0) {
      last_error_ = api_->last_error();
      return false;
    }
    // Remembered so cancellation can prove the shot is ours before killing it.
    timer_window_ = window;
    pending_ = true;
    return true;
  }

  void CancelRetry() override {
    if (!pending_) {
      return;  // Nothing of ours is scheduled; never kill someone else's timer.
    }
    api_->kill_timer(timer_window_, timer_id());
    pending_ = false;
    timer_window_ = nullptr;
  }

  // Takes the fired shot if it is ours, which also makes it one-shot. Returns
  // false for anything belonging to the engine or another plugin on this
  // shared window, and for a stale shot already cancelled or consumed.
  bool ConsumeTimer(HWND window, UINT_PTR id) {
    if (!pending_ || id != timer_id() || window != timer_window_) {
      return false;
    }
    api_->kill_timer(timer_window_, timer_id());
    pending_ = false;
    timer_window_ = nullptr;
    return true;
  }

  // The main window is shared with the engine and every other plugin, so a
  // literal id would collide with theirs. The adapter's own address is unique
  // among the objects alive on that window.
  UINT_PTR timer_id() const { return reinterpret_cast<UINT_PTR>(this); }

  bool timer_pending() const { return pending_; }

  const NOTIFYICONIDENTIFIER& identifier() const { return niif_; }

  // Best effort: Shell_NotifyIcon is not documented to set it, so it is a hint
  // in the error message, never a substitute for the failure itself.
  DWORD last_error() const { return last_error_; }

 private:
  void Fill(HICON icon, const std::wstring& tooltip) {
    ZeroMemory(&nid_, sizeof(NOTIFYICONDATA));
    nid_.cbSize = sizeof(NOTIFYICONDATA);
    nid_.hWnd = main_window_();
    nid_.uID = 1;
    nid_.hIcon = icon;
    nid_.uCallbackMessage = WM_MYMESSAGE;
    nid_.uFlags = NIF_MESSAGE | NIF_ICON;
    if (!tooltip.empty()) {
      StringCchCopy(nid_.szTip, _countof(nid_.szTip), tooltip.c_str());
      nid_.uFlags |= NIF_TIP;
    }
  }

  std::function<HWND()> main_window_;
  const Win32Api* api_;
  NOTIFYICONDATA nid_ = {};
  NOTIFYICONIDENTIFIER niif_ = {};
  DWORD last_error_ = 0;
  HWND timer_window_ = nullptr;
  bool pending_ = false;
};

}  // namespace tray_manager

#endif  // TRAY_MANAGER_WINDOWS_WIN32_TRAY_SHELL_H_
