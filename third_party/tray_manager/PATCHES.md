# tray_manager 0.5.3, patched

This is a local copy of the published `tray_manager` package with **two**
corrections to the Windows plugin: its two native members are value-initialized,
and notification-area failures are now reported instead of being reported as
success. The second correction also adds one method, `deactivateRecovery`, to
the Windows plugin and to this copy's Dart API. `pubspec.yaml` points at this copy through `dependency_overrides` while
keeping the `tray_manager: ^0.5.3` dependency, so removing the override is all
it takes to go back to the published package — at the cost of both fixes.

## Provenance

- Source: <https://pub.dev/api/archives/tray_manager-0.5.3.tar.gz>, the official
  archive of version 0.5.3 (published 2026-06-09).
- SHA-256 of that archive:
  `1a659b08baa6e9b91ef8ce16eda37740de398be1c4cf322b8a1ddfef25c68c5a`, the same
  hash `pubspec.lock` recorded when the dependency was still hosted.
- License: MIT, `LICENSE` kept verbatim (Copyright (c) 2022-present LiJianying).
- Selection: every file of the archive except `example/` (69 files that pub does
  not need to resolve or build the package). The remaining 21 files are byte for
  byte the published ones, apart from the delta below.

## Delta 1 — uninitialized members

`windows/tray_manager_plugin.cpp`, lines 49-50 of the published file:

```diff
-  NOTIFYICONDATA nid;
-  NOTIFYICONIDENTIFIER niif;
+  NOTIFYICONDATA nid = {};
+  NOTIFYICONIDENTIFIER niif = {};
```

Both are non-static members with no initializer, so they hold indeterminate
values until something writes them — and the plugin reads them first:

- `SetIcon` (line 261) tests `nid.hIcon != nullptr` and may call `DestroyIcon`
  on an indeterminate handle before it ever loads an icon.
- `_ApplyIcon` (lines 279-292) copies the indeterminate `nid.szTip` into the
  `NOTIFYICONDATA` it registers with `NIM_ADD`, and sets `NIF_TIP` when its
  first character is not zero. This is how a tray icon was observed registering
  an accessible label made of 127 × `U+CDCD` (the MSVC uninitialized-memory
  fill) ahead of the real tooltip.
- `GetBounds` (line 382) passes `niif` to `Shell_NotifyIconGetRect`.

Reading an indeterminate value is undefined behaviour, and a release build is
not guaranteed to hand out zeroed memory. `= {}` value-initializes both structs,
so `hIcon` starts null, `szTip` starts empty and `niif` starts zeroed. Both
initializers are still present, on the members that now live in
`Win32TrayShell` (delta 2). No API and no other platform is affected.

Note on the boundaries of the bug: the `szTip` copy is *not* an out-of-bounds
read. `nid.szTip` and the local backup are both `WCHAR[128]` and `StringCchCopy`
is bounded by the destination size. The defect is the indeterminate read, the
`DestroyIcon` on a garbage handle, and the garbage tooltip — not a buffer
overrun.

## Delta 2 — failures reported as success

The published plugin ignores every result the shell gives it:

- `SetIcon` destroys the current icon *before* loading its replacement, never
  checks whether `LoadImage` returned null, and answers `Success(true)`.
- `_ApplyIcon` ignores what `Shell_NotifyIcon` returns and ends with
  `tray_icon_setted = true` regardless, so a refused `NIM_ADD` is remembered as
  added and every later call is a `NIM_MODIFY` of an icon that does not exist.
- `SetToolTip` answers `Success(true)` whatever `NIM_MODIFY` returns.
- The `TaskbarCreated` handler clears `tray_icon_setted` and re-applies once. If
  that single attempt fails, the icon is gone until the app is restarted.

A false success is worse here than a crash: the Dart API returns `Future<void>`
and ignores the boolean payload, so the app cannot tell that its only user
surface — the icon, its menu and its Quit item — is missing.

The fix separates policy from Win32.

- `windows/tray_icon.h` (new, local) holds the state machine. It owns the icon
  handle and the registration and **updates them transactionally**: a candidate
  icon or tooltip is adopted only after the shell accepted it. On a rejected
  modify the previously accepted icon and tooltip stay owned — a refusal says
  nothing about what is on screen, so what is kept is the last accepted state,
  not a known-visible one — and the rejected candidate is released exactly once — nothing
  else knows about it, so this is its only chance. With nothing registered
  there is no accepted state to protect, so the candidate is kept: the add
  retries need something to add.
- `windows/win32_tray_shell.h` (new, local) is the Win32 half: NOTIFYICONDATA
  assembly, `NIM_*`, the recovery timer, and the failure-to-channel mapping.
  Its Win32 entry points are function pointers, bound to the real API in
  production and to fakes in tests.
- `windows/tray_manager_plugin.cpp` keeps the Flutter plumbing and turns
  failures into method-channel errors (`icon_load_failed`, `shell_rejected`)
  instead of `Success(true)`.

**Recovery policy, exactly.** A *missing registration* — the only failure the
user cannot work around — arms a one-shot `WM_TIMER` on the main window, at
most `kRetryBudget = 5` attempts `kRetryDelayMs = 2000` ms apart.

- A rejected *modify* never arms a timer. A refusal does not tell us the
  registration is gone, and the state machine has had no authoritative
  `TaskbarCreated`/restore event, so it conservatively assumes the earlier
  accepted registration still stands and declines to add a duplicate. The call
  returns an error and the app resyncs on its next sample. This is the state
  machine's own memory, not knowledge of the shell: visibility is unguaranteed
  either way.
- Budget reset: an accepted call restores the full budget. Between failures a
  routine sync buys nothing — a caller-driven attempt after exhaustion is made
  and reported, but does not restore the budget or re-arm the timer. That is
  what stops a 2-second poll loop from renewing recovery forever. A genuine
  shell event (`TaskbarCreated`, resume from sleep) does start a fresh budget,
  because it is rare and means every icon was dropped.
- Scheduling failure: if `SetTimer` returns 0, or there is no window, the
  budget is set to 0 rather than decremented. A timer that could not be set is
  not a recovery, and the state machine must not claim an attempt is coming.
- Timer identity: the id is the adapter instance's own address, not a literal.
  The main window is shared with the engine and every other plugin, so a fixed
  id such as `1` could replace or consume someone else's timer. The adapter
  tracks the pending shot and its window, only consumes and kills its own, and
  lets a foreign or stale `WM_TIMER` fall through untouched. Scheduling always
  retires the shot it already owns first, so a failed replacement leaves
  nothing armed and a replacement on a different window does not orphan the
  old one's timer.
- Residual timing limitation, stated rather than papered over: the id is stable
  for the object's lifetime, so there is no generation isolation. A shot already
  queued in the message queue when a new one was armed can still be delivered
  and consume the current bounded attempt early. It cannot add an extra attempt
  or re-arm anything — the budget is the bound — so the effect is at worst one
  retry firing sooner than 2000 ms.
- Deactivation: `deactivateRecovery` (new method, also added to this copy's
  `lib/src/tray_manager.dart`) cancels the timer and makes `RetryNow`,
  `Restore` and any re-arming inert, without giving up the icon. An app whose
  `destroy` is queued behind other work needs recovery to stop when it decides
  to quit, not when the queue drains. `Destroy` remains idempotent and releases
  the handle exactly once.

There is no dialog, no new setting and no generic retry service.

## Evidence for delta 2 (historical)

The evidence below was produced by two headless suites under `windows/test/`,
neither part of the plugin's `CMakeLists.txt`, so the app build was unchanged.
**Those suites are no longer shipped: the test sources were removed from the
repository at the user's request.** What follows records what they covered when
they last ran green; it is a historical result, not something reproducible from
this tree, and no fresh native validation is claimed. The production policy it
describes is unchanged and still in force.

`tray_icon_test.cpp` — the state machine against a fake shell: failed load,
failed add versus failed modify, failed tooltip, successful retry with no new
Dart sample, budget exhaustion, `Restore` failure and recovery, replacement
ownership, destroy with a retry pending, rejected-modify rollback of both icon
and tooltip, candidate retention while unregistered, scheduling failure, and
deactivation with a queued shot and a shell event arriving afterwards.

`win32_tray_shell_test.cpp` — the **production adapter** with the Win32 calls
bound to fakes: load failure and its error, `NIM_ADD`/`NIM_MODIFY`/`NIM_DELETE`
mapping, `NIF_TIP` set only for a non-empty tooltip, identifier recorded only
after an accepted add, refused calls returning false, `SetTimer` failure, timer
id uniqueness, own-shot consumption, foreign-id and other-window and stale
deliveries left alone, cancellation, and the `TrayResult` -> channel
disposition mapping including the end-to-end path with the shell refusing.

### What this evidence does not cover

- **The final `MethodResult` call is source-only.** The tests checked that a
  failure resolves to an error *disposition* and error code; constructing a
  Flutter engine to observe the actual `result->Error(...)` is out of scope.
- **No real Win32 shell call was made.** No test called `Shell_NotifyIcon`,
  `LoadImage`, `SetTimer` or `KillTimer`, and none touched Explorer or the
  notification area. The mapping from a genuine shell refusal to these paths
  rests on the Win32 contract, not on an observed failure. The one real Win32
  call the harness executed was `GetSystemMetrics(SM_CXSMICON)` inside
  `LoadIconFile`, a read-only metric query.
- **`TaskbarCreated` was simulated by calling `Restore()`.** Actual
  `RegisterWindowMessage`/`WM_TIMER` message delivery through the window
  procedure was not exercised.
- **Untested by either suite:** `GetBounds`, `TrackPopupMenu`/the context menu,
  the `WM_COMMAND` and mouse-message paths, and the plugin's Flutter
  registration. `GetBounds` now reads the identifier from the adapter but is
  otherwise behaviourally unchanged; none of these is included in the native
  proof above.
- The `GetLastError` value in the messages is a hint — `Shell_NotifyIcon` is
  not documented to set it.

## Upstream status

There is no released fix for either delta. 0.5.3 is the newest version on
pub.dev, and upstream `main`
(`packages/tray_manager/windows/tray_manager_plugin.cpp`, newest commit touching
it `43eb1471bd`, 2025-11-01) still declares both members uninitialized and still
reports shell failures as success.

## Maintenance cost

Keeping this copy is not free:

- Every future `tray_manager` release has to be re-vendored by hand: download
  the archive, verify its hash, replace these files, re-apply both deltas, and
  re-check the diff. There is no automation, and delta 2 is a real rewrite of
  three methods rather than a two-line change.
- We now own a third-party plugin's macOS and Linux sources as well. They are
  byte-identical to upstream and unmodified, but they are ours to update, and
  neither has been built or run from this copy — those platforms stay pending.
- The Dart analyzer sees a second package inside the repository.

**To remove it**, once upstream ships the initializers: delete this directory,
delete the `dependency_overrides` block in the root `pubspec.yaml`, raise the
`tray_manager` constraint to the fixed version, and run `flutter pub get`.
