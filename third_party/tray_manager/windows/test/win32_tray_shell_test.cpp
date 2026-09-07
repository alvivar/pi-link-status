// Headless tests for the production Win32 adapter (../win32_tray_shell.h).
//
// These exercise the very code the plugin runs — NOTIFYICONDATA assembly, the
// NIM_* mapping, timer ownership, and the failure-to-channel-answer mapping —
// with the Win32 entry points bound to fakes. No Shell_NotifyIcon, no
// LoadImage, no SetTimer, no window and no Explorer interaction.
//
// The one real Win32 call reached here is GetSystemMetrics(SM_CXSMICON) inside
// LoadIconFile: a read-only metric query that mutates nothing. It is disclosed
// rather than hidden behind another injection layer.
//
// Build and run (Developer Command Prompt; UNICODE matches the Flutter build):
//   cl /nologo /EHsc /std:c++17 /W3 /DUNICODE /D_UNICODE win32_tray_shell_test.cpp ^
//      /Fe:%TEMP%\win32_tray_shell_test.exe user32.lib shell32.lib
//   %TEMP%\win32_tray_shell_test.exe

#include "../win32_tray_shell.h"

#include <cstdio>
#include <string>
#include <vector>

namespace {

using tray_manager::ChannelDisposition;
using tray_manager::DispositionFor;
using tray_manager::ErrorCodeFor;
using tray_manager::TrayIcon;
using tray_manager::TrayResult;
using tray_manager::Win32Api;
using tray_manager::Win32TrayShell;

int failures = 0;

void Check(bool condition, const char* what) {
  if (!condition) {
    ++failures;
    std::printf("FAIL: %s\n", what);
  }
}

HWND FakeWindow() { return reinterpret_cast<HWND>(0x2000); }
HICON FakeIcon() { return reinterpret_cast<HICON>(0x3000); }

// Bindings are plain function pointers, so the recorded state is file-local.
struct ApiLog {
  bool load_fails = false;
  bool notify_fails = false;
  UINT_PTR set_timer_result = 0x55;
  DWORD error = 1234;

  int loads = 0;
  int destroys = 0;
  std::vector<DWORD> notified;
  NOTIFYICONDATA last_nid = {};
  std::vector<std::pair<HWND, UINT_PTR>> set_timers;
  std::vector<std::pair<HWND, UINT_PTR>> killed_timers;
};

ApiLog log;

// The window the adapter under test resolves. A real app's main window can
// change (the engine recreates it), so tests can move it.
HWND current_window = FakeWindow();

HICON FakeLoadImage(const wchar_t*, int width, int height) {
  ++log.loads;
  // The adapter must ask for the small-icon size, not an arbitrary one.
  Check(width > 0 && height > 0, "adapter: a real icon size is requested");
  return log.load_fails ? nullptr : FakeIcon();
}

BOOL FakeNotifyIcon(DWORD message, NOTIFYICONDATA* data) {
  log.notified.push_back(message);
  log.last_nid = *data;
  return log.notify_fails ? FALSE : TRUE;
}

UINT_PTR FakeSetTimer(HWND window, UINT_PTR id, UINT) {
  log.set_timers.push_back({window, id});
  return log.set_timer_result;
}

BOOL FakeKillTimer(HWND window, UINT_PTR id) {
  log.killed_timers.push_back({window, id});
  return TRUE;
}

BOOL FakeDestroyIcon(HICON) {
  ++log.destroys;
  return TRUE;
}

DWORD FakeLastError() { return log.error; }

const Win32Api kFakeApi = {&FakeLoadImage, &FakeNotifyIcon,  &FakeSetTimer,
                           &FakeKillTimer, &FakeDestroyIcon, &FakeLastError};

// A shell bound to the fakes, on a window that does not exist.
Win32TrayShell MakeShell() {
  return Win32TrayShell([]() { return current_window; }, &kFakeApi);
}

void Reset() {
  log = ApiLog();
  current_window = FakeWindow();
}

void LoadFailureIsReportedWithItsError() {
  Reset();
  log.load_fails = true;
  Win32TrayShell shell = MakeShell();

  Check(shell.LoadIconFile(L"missing.ico") == nullptr,
        "adapter: a failed load returns no handle");
  Check(log.loads == 1, "adapter: LoadImage was called once");
  Check(shell.last_error() == 1234, "adapter: the OS error is captured");

  log.load_fails = false;
  Check(shell.LoadIconFile(L"good.ico") == FakeIcon(),
        "adapter: a successful load returns the handle");
}

void NotifyMappingAndFailures() {
  Reset();
  Win32TrayShell shell = MakeShell();

  Check(shell.Add(FakeIcon(), L"pi-link"), "adapter: an accepted add succeeds");
  Check(log.notified.size() == 1 && log.notified[0] == NIM_ADD,
        "adapter: add issues NIM_ADD");
  Check(log.last_nid.hIcon == FakeIcon(), "adapter: the icon is passed");
  Check(log.last_nid.hWnd == FakeWindow(), "adapter: on the main window");
  Check((log.last_nid.uFlags & NIF_TIP) != 0,
        "adapter: a tooltip sets NIF_TIP");
  Check(std::wstring(log.last_nid.szTip) == L"pi-link",
        "adapter: the tooltip text is copied");
  Check(shell.identifier().hWnd == FakeWindow(),
        "adapter: an accepted add records the identifier for GetBounds");

  Check(shell.Modify(FakeIcon(), L""), "adapter: an accepted modify succeeds");
  Check(log.notified.back() == NIM_MODIFY, "adapter: modify issues NIM_MODIFY");
  Check((log.last_nid.uFlags & NIF_TIP) == 0,
        "adapter: an empty tooltip clears NIF_TIP");

  shell.Delete();
  Check(log.notified.back() == NIM_DELETE, "adapter: delete issues NIM_DELETE");

  log.notify_fails = true;
  Check(!shell.Add(FakeIcon(), L""), "adapter: a refused add returns false");
  Check(!shell.Modify(FakeIcon(), L""),
        "adapter: a refused modify returns false");
  Check(shell.last_error() == 1234, "adapter: the OS error is captured");

  shell.DestroyIconHandle(FakeIcon());
  Check(log.destroys == 1, "adapter: releasing goes through DestroyIcon");
}

void TimerIsOwnedAndFailureIsVisible() {
  Reset();
  Win32TrayShell shell = MakeShell();
  Win32TrayShell other = MakeShell();

  Check(shell.timer_id() != other.timer_id(),
        "timer: each adapter owns a distinct id");
  Check(shell.timer_id() != 1,
        "timer: the id is not the literal 1 the engine may also use");

  log.set_timer_result = 0;
  Check(!shell.ScheduleRetry(2000),
        "timer: a refused SetTimer is reported, not assumed armed");
  Check(!shell.timer_pending(), "timer: nothing is pending after a failure");
  Check(shell.last_error() == 1234, "timer: the OS error is captured");

  log.set_timer_result = 0x55;
  Check(shell.ScheduleRetry(2000), "timer: scheduling succeeds");
  Check(shell.timer_pending(), "timer: the shot is pending");
  Check(log.set_timers.back().first == FakeWindow() &&
            log.set_timers.back().second == shell.timer_id(),
        "timer: it is set on our window with our id");

  // A foreign shot must pass through untouched: the window is shared with the
  // engine and every other plugin.
  Check(!shell.ConsumeTimer(FakeWindow(), 1),
        "timer: a foreign id is not consumed");
  Check(!shell.ConsumeTimer(reinterpret_cast<HWND>(0x9999), shell.timer_id()),
        "timer: our id on another window is not consumed");
  Check(!shell.ConsumeTimer(FakeWindow(), other.timer_id()),
        "timer: another adapter's shot is not consumed");
  Check(log.killed_timers.empty(), "timer: no foreign timer was killed");
  Check(shell.timer_pending(), "timer: ours is still pending");

  Check(shell.ConsumeTimer(FakeWindow(), shell.timer_id()),
        "timer: our own shot is consumed");
  Check(log.killed_timers.size() == 1 &&
            log.killed_timers.back().second == shell.timer_id(),
        "timer: consuming kills exactly our timer, making it one-shot");
  Check(!shell.timer_pending(), "timer: it is no longer pending");
  Check(!shell.ConsumeTimer(FakeWindow(), shell.timer_id()),
        "timer: a stale second delivery is inert");

  // Cancelling without a pending shot must not kill anything.
  const size_t killed = log.killed_timers.size();
  shell.CancelRetry();
  Check(log.killed_timers.size() == killed,
        "timer: cancelling nothing kills nothing");

  shell.ScheduleRetry(2000);
  shell.CancelRetry();
  Check(log.killed_timers.size() == killed + 1 && !shell.timer_pending(),
        "timer: cancelling a pending shot kills ours");
}

// Scheduling while a shot of ours is already pending: a caller-driven failed
// add can arrive before the previous shot fires.
void ReplacingAPendingShotRetiresTheOldOne() {
  // (a) A replacement that cannot be scheduled must leave nothing armed.
  Reset();
  Win32TrayShell shell = MakeShell();
  Check(shell.ScheduleRetry(2000), "replace: the first shot is armed");
  const UINT_PTR id = shell.timer_id();

  log.set_timer_result = 0;
  Check(!shell.ScheduleRetry(2000), "replace: the replacement is refused");
  Check(!shell.timer_pending(),
        "replace: a refused replacement leaves no pending timer, so the state "
        "machine's exhaustion is not contradicted");
  Check(log.killed_timers.size() == 1 &&
            log.killed_timers.back().first == FakeWindow() &&
            log.killed_timers.back().second == id,
        "replace: the old shot is killed on its exact window and id");

  // (b) A successful replacement on a new window must retire the old window's
  // timer rather than forget it.
  Reset();
  Win32TrayShell moved = MakeShell();
  Check(moved.ScheduleRetry(2000), "replace: armed on the first window");
  HWND second = reinterpret_cast<HWND>(0x2100);
  current_window = second;
  Check(moved.ScheduleRetry(2000), "replace: armed again after the move");
  Check(log.killed_timers.size() == 1 &&
            log.killed_timers.back().first == FakeWindow() &&
            log.killed_timers.back().second == moved.timer_id(),
        "replace: the old window's timer is killed first, not orphaned");
  Check(log.set_timers.back().first == second,
        "replace: the new shot is on the new window");
  Check(!moved.ConsumeTimer(FakeWindow(), moved.timer_id()),
        "replace: a shot on the abandoned window is no longer ours");
  Check(moved.ConsumeTimer(second, moved.timer_id()),
        "replace: only the new window's shot is ours");
}

void NoWindowMeansNoRecovery() {
  Reset();
  Win32TrayShell shell([]() { return static_cast<HWND>(nullptr); }, &kFakeApi);

  Check(!shell.ScheduleRetry(2000),
        "timer: without a window there is nothing to schedule on");
  Check(log.set_timers.empty(), "timer: SetTimer is not called with no window");
  shell.CancelRetry();
  Check(log.killed_timers.empty(), "timer: nor is KillTimer");
}

void FailuresNeverMapToSuccess() {
  Check(DispositionFor(TrayResult::kOk) == ChannelDisposition::kSuccess,
        "channel: success maps to success");
  Check(DispositionFor(TrayResult::kIconMissing) ==
            ChannelDisposition::kIconLoadFailed,
        "channel: a missing icon maps to icon_load_failed");
  Check(DispositionFor(TrayResult::kShellRejected) ==
            ChannelDisposition::kShellRejected,
        "channel: a refusal maps to shell_rejected");
  Check(ErrorCodeFor(ChannelDisposition::kSuccess) == nullptr,
        "channel: success carries no error code");
  Check(std::string(ErrorCodeFor(ChannelDisposition::kIconLoadFailed)) ==
            "icon_load_failed",
        "channel: the load error code is stable");
  Check(std::string(ErrorCodeFor(ChannelDisposition::kShellRejected)) ==
            "shell_rejected",
        "channel: the refusal error code is stable");
}

// The whole production path bar the final MethodResult call: state machine,
// real adapter, real mapping, with the shell refusing.
void RefusedShellReachesTheChannelAsAnError() {
  Reset();
  Win32TrayShell shell = MakeShell();
  TrayIcon tray(&shell);

  log.notify_fails = true;
  Check(DispositionFor(tray.SetIcon(L"icon.ico")) ==
            ChannelDisposition::kShellRejected,
        "end to end: a refused add is an error, never Success(false)");
  Check(log.notified.back() == NIM_ADD, "end to end: it really tried NIM_ADD");
  Check(!tray.registered(), "end to end: nothing is remembered as registered");
  Check(log.set_timers.size() == 1, "end to end: recovery was armed once");

  log.load_fails = true;
  Check(DispositionFor(tray.SetIcon(L"missing.ico")) ==
            ChannelDisposition::kIconLoadFailed,
        "end to end: a failed load is an error");

  log.load_fails = false;
  log.notify_fails = false;
  Check(DispositionFor(tray.SetIcon(L"icon.ico")) ==
            ChannelDisposition::kSuccess,
        "end to end: an accepted add is a success");
  Check(tray.registered(), "end to end: only then is it registered");

  log.notify_fails = true;
  Check(DispositionFor(tray.SetToolTip(L"pi-link")) ==
            ChannelDisposition::kShellRejected,
        "end to end: a refused tooltip is an error");
}

}  // namespace

int main() {
  LoadFailureIsReportedWithItsError();
  NotifyMappingAndFailures();
  TimerIsOwnedAndFailureIsVisible();
  ReplacingAPendingShotRetiresTheOldOne();
  NoWindowMeansNoRecovery();
  FailuresNeverMapToSuccess();
  RefusedShellReachesTheChannelAsAnError();

  if (failures != 0) {
    std::printf("%d check(s) failed\n", failures);
    return 1;
  }
  std::printf("all win32_tray_shell checks passed\n");
  return 0;
}
