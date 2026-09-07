// Headless tests for the notification-area state machine (../tray_icon.h).
//
// Nothing here calls Win32: the fake shell only records what it was asked to
// do and answers with whatever the case under test scripted, so the real
// notification area is never touched. HICON values are fabricated numbers.
//
// Build and run (from a Developer Command Prompt, output outside the repo):
//   cl /nologo /EHsc /std:c++17 /W3 tray_icon_test.cpp /Fe:%TEMP%\tray_icon_test.exe
//   %TEMP%\tray_icon_test.exe

#include "../tray_icon.h"

#include <cstdio>
#include <string>
#include <vector>

namespace {

using tray_manager::TrayIcon;
using tray_manager::TrayResult;

int failures = 0;

void Check(bool condition, const char* what) {
  if (!condition) {
    ++failures;
    std::printf("FAIL: %s\n", what);
  }
}

// A handle the tests can tell apart, never a real icon.
HICON Handle(int n) {
  return reinterpret_cast<HICON>(static_cast<INT_PTR>(0x1000 + n));
}

class FakeShell : public tray_manager::TrayShell {
 public:
  // Scripted outcomes.
  bool load_fails = false;
  bool add_fails = false;
  bool modify_fails = false;
  bool schedule_fails = false;

  // What happened.
  std::vector<std::string> calls;
  std::vector<HICON> destroyed;
  std::vector<HICON> loaded;
  std::wstring last_tooltip;
  int scheduled = 0;
  int cancelled = 0;
  bool retry_pending = false;

  HICON LoadIconFile(const std::wstring&) override {
    calls.push_back("load");
    if (load_fails) {
      return nullptr;
    }
    HICON icon = Handle(next_handle_++);
    loaded.push_back(icon);
    return icon;
  }

  void DestroyIconHandle(HICON icon) override {
    calls.push_back("destroy");
    destroyed.push_back(icon);
  }

  bool Add(HICON icon, const std::wstring& tooltip) override {
    calls.push_back("add");
    last_icon = icon;
    last_tooltip = tooltip;
    return !add_fails;
  }

  bool Modify(HICON icon, const std::wstring& tooltip) override {
    calls.push_back("modify");
    last_icon = icon;
    last_tooltip = tooltip;
    return !modify_fails;
  }

  void Delete() override { calls.push_back("delete"); }

  bool ScheduleRetry(int) override {
    calls.push_back("schedule");
    if (schedule_fails) {
      return false;
    }
    ++scheduled;
    retry_pending = true;
    return true;
  }

  void CancelRetry() override {
    ++cancelled;
    retry_pending = false;
  }

  // How many times a handle was released: the ownership assertions.
  int DestroyCount(HICON icon) const {
    int count = 0;
    for (HICON seen : destroyed) {
      if (seen == icon) {
        ++count;
      }
    }
    return count;
  }

  int CountOf(const char* name) const {
    int count = 0;
    for (const std::string& call : calls) {
      if (call == name) {
        ++count;
      }
    }
    return count;
  }

  HICON last_icon = nullptr;

 private:
  int next_handle_ = 1;
};

// Delivers one timer shot the way the window procedure does.
void FireRetry(FakeShell& shell, TrayIcon& tray) {
  shell.retry_pending = false;
  tray.RetryNow();
}

void FailedLoadKeepsTheCurrentIcon() {
  FakeShell shell;
  TrayIcon tray(&shell);
  Check(tray.SetIcon(L"good.ico") == TrayResult::kOk, "load: first icon shown");
  HICON first = shell.last_icon;

  shell.load_fails = true;
  Check(tray.SetIcon(L"missing.ico") == TrayResult::kIconMissing,
        "load: a missing file is reported, not swallowed");
  Check(tray.icon() == first, "load: the working icon is kept");
  Check(shell.DestroyCount(first) == 0,
        "load: the working icon is not released for a replacement that failed");
  Check(tray.registered(), "load: the registration survives a failed load");
  Check(shell.CountOf("add") == 1, "load: no second add");
}

void FailedAddStaysAddEligibleThenRecovers() {
  FakeShell shell;
  shell.add_fails = true;
  TrayIcon tray(&shell);

  Check(tray.SetIcon(L"icon.ico") == TrayResult::kShellRejected,
        "add: a refused add is an error");
  Check(!tray.registered(), "add: a refused add is not remembered as added");
  Check(shell.retry_pending, "add: recovery is armed");
  Check(tray.attempts_left() == TrayIcon::kRetryBudget - 1,
        "add: the attempt is charged to the budget");

  // No new sample from Dart: only the timer runs, which is the offline-startup
  // case the recovery exists for.
  FireRetry(shell, tray);
  Check(shell.CountOf("add") == 2, "add: the retry adds again, never modifies");
  Check(shell.CountOf("modify") == 0, "add: a missing icon is never modified");

  shell.add_fails = false;
  FireRetry(shell, tray);
  Check(tray.registered(), "add: a later success registers");
  Check(tray.attempts_left() == TrayIcon::kRetryBudget,
        "add: success restores the budget");
  Check(!shell.retry_pending, "add: success cancels the pending shot");
}

void FailedModifyKeepsTheRegistration() {
  FakeShell shell;
  TrayIcon tray(&shell);
  Check(tray.SetIcon(L"icon.ico") == TrayResult::kOk, "modify: registered");
  const int adds = shell.CountOf("add");

  shell.modify_fails = true;
  Check(tray.SetIcon(L"other.ico") == TrayResult::kShellRejected,
        "modify: a refused modify is an error");
  Check(tray.registered(), "modify: the registration is kept");
  Check(shell.CountOf("add") == adds,
        "modify: a refused modify never turns into a duplicate add");
  Check(!shell.retry_pending,
        "modify: a remembered accepted registration does not start "
        "missing-registration recovery");
}

void FailedTooltipIsReported() {
  FakeShell shell;
  TrayIcon tray(&shell);
  tray.SetIcon(L"icon.ico");

  shell.modify_fails = true;
  Check(tray.SetToolTip(L"pi-link") == TrayResult::kShellRejected,
        "tooltip: a refused tooltip is an error");
  Check(tray.registered(), "tooltip: the icon stays registered");

  shell.modify_fails = false;
  Check(tray.SetToolTip(L"pi-link") == TrayResult::kOk, "tooltip: retried");
  Check(shell.last_tooltip == L"pi-link", "tooltip: the text is applied");

  FakeShell bare;
  TrayIcon without_icon(&bare);
  Check(without_icon.SetToolTip(L"pi-link") == TrayResult::kIconMissing,
        "tooltip: no icon means no empty registration");
  Check(bare.CountOf("add") == 0, "tooltip: nothing is registered");
}

void RecoveryIsFinite() {
  FakeShell shell;
  shell.add_fails = true;
  TrayIcon tray(&shell);

  tray.SetIcon(L"icon.ico");
  for (int i = 0; i < TrayIcon::kRetryBudget + 3; ++i) {
    FireRetry(shell, tray);
  }
  Check(tray.attempts_left() == 0, "finite: the budget is spent");
  Check(shell.scheduled == TrayIcon::kRetryBudget,
        "finite: exactly the budget is scheduled, then no more timers");
  Check(!shell.retry_pending, "finite: nothing is left pending");

  // A routine sync after exhaustion attempts once and reports, but must not
  // buy a new budget: that is how a 2 s poll loop would retry forever.
  const int before = shell.scheduled;
  Check(tray.SetIcon(L"icon.ico") == TrayResult::kShellRejected,
        "finite: a later sample still reports the failure");
  Check(shell.scheduled == before, "finite: a routine sync renews nothing");
}

void ExplorerRestartRecoversFinitely() {
  FakeShell shell;
  TrayIcon tray(&shell);
  tray.SetIcon(L"icon.ico");
  Check(tray.registered(), "taskbar: registered before the restart");

  shell.add_fails = true;
  tray.Restore();  // TaskbarCreated
  Check(!tray.registered(), "taskbar: a failed restore is not a registration");
  Check(shell.retry_pending, "taskbar: a failed restore is recoverable");

  shell.add_fails = false;
  FireRetry(shell, tray);
  Check(tray.registered(), "taskbar: the icon comes back");

  // A second restart gets its own budget: it is a real shell event, not a loop.
  shell.add_fails = true;
  const int before = shell.scheduled;
  tray.Restore();
  Check(tray.attempts_left() == TrayIcon::kRetryBudget - 1,
        "taskbar: a restart starts a fresh budget");
  Check(shell.scheduled == before + 1, "taskbar: one shot per failure");
}

void ReplacementReleasesEachHandleOnce() {
  FakeShell shell;
  TrayIcon tray(&shell);
  tray.SetIcon(L"one.ico");
  HICON first = shell.last_icon;
  tray.SetIcon(L"two.ico");
  HICON second = shell.last_icon;

  Check(first != second, "ownership: a replacement is a different handle");
  Check(shell.DestroyCount(first) == 1, "ownership: the old icon is released");
  Check(shell.DestroyCount(second) == 0,
        "ownership: the live icon is not released");

  tray.Destroy();
  Check(shell.DestroyCount(second) == 1,
        "ownership: shutdown releases the live icon");
  tray.Destroy();
  Check(shell.DestroyCount(second) == 1,
        "ownership: a second destroy releases nothing twice");
  Check(shell.CountOf("delete") == 1,
        "ownership: the registration is removed exactly once");

  for (HICON icon : shell.loaded) {
    Check(shell.DestroyCount(icon) == 1,
          "ownership: every loaded icon is released exactly once");
  }
}

void DestroyCancelsAPendingRetry() {
  FakeShell shell;
  shell.add_fails = true;
  TrayIcon tray(&shell);
  tray.SetIcon(L"icon.ico");
  Check(shell.retry_pending, "destroy: a retry is pending");

  tray.Destroy();
  Check(!shell.retry_pending, "destroy: the pending shot is cancelled");

  // A shot already in the message queue when Destroy ran must do nothing.
  const int adds = shell.CountOf("add");
  tray.RetryNow();
  Check(shell.CountOf("add") == adds, "destroy: a late timer adds nothing");
  Check(tray.icon() == nullptr, "destroy: nothing is owned afterwards");

  // Restore after shutdown is inert too: there is no icon to bring back.
  tray.Restore();
  Check(shell.CountOf("add") == adds, "destroy: a late restore adds nothing");
}

// Correction 1: a rejected modify must not commit the replacement.
void RejectedModifyRollsBackIconAndTooltip() {
  FakeShell shell;
  TrayIcon tray(&shell);
  tray.SetIcon(L"accepted.ico");
  HICON accepted = shell.last_icon;
  tray.SetToolTip(L"accepted tip");

  shell.modify_fails = true;
  Check(tray.SetIcon(L"rejected.ico") == TrayResult::kShellRejected,
        "rollback: a rejected replacement is an error");
  HICON rejected = shell.loaded.back();
  Check(rejected != accepted, "rollback: the candidate is a new handle");
  Check(tray.icon() == accepted,
        "rollback: the last accepted icon is the one still owned");
  Check(shell.DestroyCount(rejected) == 1,
        "rollback: the rejected candidate is released exactly once");
  Check(shell.DestroyCount(accepted) == 0,
        "rollback: the accepted icon is not released");

  Check(tray.SetToolTip(L"rejected tip") == TrayResult::kShellRejected,
        "rollback: a rejected tooltip is an error");
  Check(tray.tooltip() == L"accepted tip",
        "rollback: the accepted tooltip is kept");

  // The next accepted call must carry the preserved values. This is the
  // user-visible half: Dart keeps its own accepted cache, so it may never
  // resend the old icon, and a stale native value would be applied here.
  shell.modify_fails = false;
  Check(tray.SetToolTip(L"next tip") == TrayResult::kOk,
        "rollback: a later modify is accepted");
  Check(shell.last_icon == accepted,
        "rollback: it applies the accepted icon, not the rejected one");
  Check(shell.last_tooltip == L"next tip", "rollback: with the new tooltip");

  tray.Destroy();
  for (HICON icon : shell.loaded) {
    Check(shell.DestroyCount(icon) == 1,
          "rollback: every handle is released exactly once");
  }
}

// Correction 1: with nothing registered there is no accepted state to protect,
// and the retries need the candidate.
void RejectedAddKeepsTheCandidateForRetries() {
  FakeShell shell;
  shell.add_fails = true;
  TrayIcon tray(&shell);

  tray.SetIcon(L"icon.ico");
  HICON candidate = shell.loaded.back();
  Check(tray.icon() == candidate, "candidate: the loaded icon is kept");
  Check(shell.DestroyCount(candidate) == 0,
        "candidate: it is not released, the retries need it");

  shell.add_fails = false;
  FireRetry(shell, tray);
  Check(tray.registered(), "candidate: the retry registers");
  Check(shell.last_icon == candidate, "candidate: it adds that same icon");
}

// Correction 4: a timer that could not be scheduled is not a recovery.
void FailedSchedulingStopsClaimingRecovery() {
  FakeShell shell;
  shell.add_fails = true;
  shell.schedule_fails = true;
  TrayIcon tray(&shell);

  Check(tray.SetIcon(L"icon.ico") == TrayResult::kShellRejected,
        "schedule: the failure is still reported");
  Check(!shell.retry_pending, "schedule: nothing is pending");
  Check(tray.attempts_left() == 0,
        "schedule: the budget is not spent one hopeless attempt at a time");
  Check(shell.CountOf("schedule") == 1,
        "schedule: scheduling is not retried in a loop");
}

// Correction 3: quitting must stop recovery immediately, long before the
// app's queued destroy runs.
void DeactivationMakesRecoveryInertBeforeDestroy() {
  FakeShell shell;
  shell.add_fails = true;
  TrayIcon tray(&shell);
  tray.SetIcon(L"icon.ico");
  Check(shell.retry_pending, "deactivate: a retry is pending");

  tray.Deactivate();
  Check(!tray.active(), "deactivate: recovery is off");
  Check(!shell.retry_pending, "deactivate: the owned timer is cancelled");

  const int adds = shell.CountOf("add");
  const int schedules = shell.CountOf("schedule");
  tray.RetryNow();  // A shot already in the message queue when we deactivated.
  tray.Restore();   // Explorer restarting while the app is quitting.
  Check(shell.CountOf("add") == adds,
        "deactivate: a queued shot and a shell event are both inert");
  Check(shell.CountOf("schedule") == schedules,
        "deactivate: nothing re-arms");

  // Deactivation is not destruction: the handle is still owned. (Here the add
  // was refused throughout, so this candidate was never registered.)
  Check(tray.icon() != nullptr, "deactivate: the icon is still owned");
  tray.Destroy();
  Check(shell.destroyed.size() == 1,
        "deactivate: the eventual destroy still releases exactly once");
}

void DestructorReleasesWhatTheWindowDidNot() {
  FakeShell shell;
  {
    TrayIcon tray(&shell);
    tray.SetIcon(L"icon.ico");
  }
  Check(shell.CountOf("delete") == 1, "destructor: the registration is removed");
  Check(shell.destroyed.size() == 1, "destructor: the icon is released once");
}

}  // namespace

int main() {
  FailedLoadKeepsTheCurrentIcon();
  FailedAddStaysAddEligibleThenRecovers();
  FailedModifyKeepsTheRegistration();
  FailedTooltipIsReported();
  RecoveryIsFinite();
  ExplorerRestartRecoversFinitely();
  ReplacementReleasesEachHandleOnce();
  DestroyCancelsAPendingRetry();
  RejectedModifyRollsBackIconAndTooltip();
  RejectedAddKeepsTheCandidateForRetries();
  FailedSchedulingStopsClaimingRecovery();
  DeactivationMakesRecoveryInertBeforeDestroy();
  DestructorReleasesWhatTheWindowDidNot();

  if (failures != 0) {
    std::printf("%d check(s) failed\n", failures);
    return 1;
  }
  std::printf("all tray_icon checks passed\n");
  return 0;
}
