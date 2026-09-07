// Local addition to the vendored tray_manager copy (see ../../PATCHES.md).
//
// The notification-area state machine, deliberately free of Flutter and of
// direct Win32 calls: the plugin injects the real shell, tests inject a fake
// one, so the failure paths can be exercised without touching the desktop.

#ifndef TRAY_MANAGER_WINDOWS_TRAY_ICON_H_
#define TRAY_MANAGER_WINDOWS_TRAY_ICON_H_

#include <windows.h>

#include <string>

namespace tray_manager {

// Why an operation did not reach the notification area. The plugin turns these
// into method-channel errors, so Dart never sees a failure as success.
enum class TrayResult {
  kOk,
  // No icon to show: the file could not be loaded, or none has been loaded yet.
  kIconMissing,
  // The shell refused the NIM_ADD/NIM_MODIFY call.
  kShellRejected,
};

// Everything the state machine needs from the system. The plugin implements it
// with LoadImage/Shell_NotifyIcon/SetTimer; the tests implement it with fakes.
class TrayShell {
 public:
  virtual ~TrayShell() = default;

  // Returns nullptr when the file cannot be loaded.
  virtual HICON LoadIconFile(const std::wstring& path) = 0;
  virtual void DestroyIconHandle(HICON icon) = 0;

  // NIM_ADD / NIM_MODIFY / NIM_DELETE. Add and Modify report whether the shell
  // accepted the call; a rejected call must not change anything visible.
  virtual bool Add(HICON icon, const std::wstring& tooltip) = 0;
  virtual bool Modify(HICON icon, const std::wstring& tooltip) = 0;
  virtual void Delete() = 0;

  // One-shot recovery timer. Scheduling again replaces a pending shot.
  // Returns false when the timer could not be scheduled at all.
  virtual bool ScheduleRetry(int delay_ms) = 0;
  virtual void CancelRetry() = 0;
};

// Owns the icon handle and the registration, and knows the one thing the
// vendored plugin got wrong: only a call the shell accepted may advance state.
class TrayIcon {
 public:
  // Recovery budget for a *missing* registration, the only failure the user
  // cannot work around: without the icon there is no menu and no Quit.
  //
  // Five attempts two seconds apart cover the case this exists for — the app
  // launching before the notification area is ready, or Explorer restarting —
  // within ten seconds, without leaving a timer running on a machine where the
  // shell is simply refusing. The budget is spent by failures and restored
  // only by success, so a sync loop cannot renew it indefinitely.
  static constexpr int kRetryBudget = 5;
  static constexpr int kRetryDelayMs = 2000;

  explicit TrayIcon(TrayShell* shell) : shell_(shell) {}

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  // Releases the icon and the registration if the window never did.
  ~TrayIcon() { Destroy(); }

  bool registered() const { return registered_; }
  HICON icon() const { return icon_; }
  const std::wstring& tooltip() const { return tooltip_; }
  int attempts_left() const { return attempts_left_; }
  bool active() const { return active_; }

  // Loads [path] and shows it. The replacement is only adopted once the shell
  // accepted it, so a failed load or a rejected modify leaves the last
  // accepted icon owned and unchanged.
  TrayResult SetIcon(const std::wstring& path) {
    HICON candidate = shell_->LoadIconFile(path);
    if (candidate == nullptr) {
      return TrayResult::kIconMissing;
    }
    return ApplyCandidate(candidate, tooltip_);
  }

  TrayResult SetToolTip(const std::wstring& tooltip) {
    return ApplyCandidate(icon_, tooltip);
  }

  // The shell dropped every icon: Explorer restarted, or the machine resumed.
  // A real shell event, so the budget starts over.
  void Restore() {
    if (!active_ || icon_ == nullptr) {
      return;
    }
    registered_ = false;
    attempts_left_ = kRetryBudget;
    ApplyCandidate(icon_, tooltip_);
  }

  // The recovery timer fired.
  void RetryNow() {
    if (!active_ || registered_) {
      return;
    }
    ApplyCandidate(icon_, tooltip_);
  }

  // Stops recovery immediately, without giving up the icon: the app is quitting
  // and its final [Destroy] may be queued behind arbitrarily long work. A timer
  // shot already in the message queue, and any shell event that arrives in the
  // meantime, must find the machine inert.
  void Deactivate() {
    active_ = false;
    shell_->CancelRetry();
  }

  // Idempotent: safe from the method channel, from WM_DESTROY and from the
  // destructor, in any order.
  void Destroy() {
    shell_->CancelRetry();
    if (registered_) {
      shell_->Delete();
      registered_ = false;
    }
    if (icon_ != nullptr) {
      shell_->DestroyIconHandle(icon_);
      icon_ = nullptr;
    }
    attempts_left_ = kRetryBudget;
  }

 private:
  // Adds when the shell has no registration, modifies when it has one, and
  // adopts [candidate] and [tooltip] only if the shell accepted the call.
  TrayResult ApplyCandidate(HICON candidate, const std::wstring& tooltip) {
    // Registering without an icon would give the user a nameless empty slot
    // instead of an honest error.
    if (candidate == nullptr) {
      return TrayResult::kIconMissing;
    }
    const bool modifying = registered_;
    const bool accepted = modifying ? shell_->Modify(candidate, tooltip)
                                    : shell_->Add(candidate, tooltip);
    if (accepted) {
      Adopt(candidate, tooltip);
      registered_ = true;
      attempts_left_ = kRetryBudget;
      shell_->CancelRetry();
      return TrayResult::kOk;
    }
    if (modifying) {
      // A refusal says nothing about what is on screen. What we keep is the
      // last state the shell accepted; whether it is visible is not knowable
      // from here. Dropping the rejected candidate is the only chance to
      // release it: nothing else knows about it.
      if (candidate != icon_) {
        shell_->DestroyIconHandle(candidate);
      }
      // Our own record of a prior accepted registration stands, and no
      // authoritative Restore event has said otherwise, so adding again could
      // duplicate it. Only a missing registration gets a timer.
      return TrayResult::kShellRejected;
    }
    // Nothing is registered, so there is no accepted state to protect and the
    // candidate is exactly what the retries must keep trying to add.
    Adopt(candidate, tooltip);
    ArmRetry();
    return TrayResult::kShellRejected;
  }

  void Adopt(HICON icon, const std::wstring& tooltip) {
    if (icon != icon_) {
      if (icon_ != nullptr) {
        shell_->DestroyIconHandle(icon_);
      }
      icon_ = icon;
    }
    tooltip_ = tooltip;
  }

  void ArmRetry() {
    if (!active_ || attempts_left_ <= 0) {
      return;  // Exhausted or quitting: inert until a success or shell event.
    }
    if (!shell_->ScheduleRetry(kRetryDelayMs)) {
      // No timer, no recovery. Spending the whole budget is how the state
      // machine stops claiming an attempt is coming that never will.
      attempts_left_ = 0;
      return;
    }
    --attempts_left_;
  }

  TrayShell* const shell_;
  HICON icon_ = nullptr;
  std::wstring tooltip_;
  bool registered_ = false;
  bool active_ = true;
  int attempts_left_ = kRetryBudget;
};

}  // namespace tray_manager

#endif  // TRAY_MANAGER_WINDOWS_TRAY_ICON_H_
