# T1a — Desktop feasibility: showing without stealing focus, and positioning

Research carried out before T5. It answers three questions before the UI is built:
showing the window without activating it, placing it next to the tray icon inside
the work area, and what the fallback guarantees when no position data is available.

**Short result:** the "show without stealing focus" requirement **is not met by
`windowManager.show(inactive: true)`** on Windows: the `inactive` parameter is not
implemented in the native code and the window steals focus. **No valid end-to-end route
was found within the audited public APIs and the installed implementations.** The
opacity alternative (§Q1, option B) does avoid activation *once the window is already
visible*, but **it was only verified starting from a launch that had already shown and
activated the window**, so it is not a product path: it is incompatible with the
truly-hidden-window semantics and the flash-free startup required by §Diseño/Ventana and
T6 (see §Q1, "Why option B does not close the loop"). A second, seemingly obvious route
(`show()` + `blur()`) was tried and is **dangerous**: it hands focus to an arbitrary
window, not to the one that had it.
**Outcome:** the user resolved the dilemma by **relaxing the requirement**, not by
choosing a technical remedy. v1 uses plain `show()`/`hide()` with a **centered** window,
accepts that opening steals focus, and gives up anchoring next to the icon. See
§"Current decision (v1)". Everything this report says about non-activation, opacity, a
native bridge and multi-monitor geometry **remains valid evidence about the earlier
contract**, but none of it is a v1 requirement or blocker any more.

## Scope of the evidence

Every claim in this document carries one of these tags:

| Tag | Meaning |
|---|---|
| **[OBS]** | Observed in a real run on this machine, with recorded values |
| **[SRC]** | Read in the installed source/native code of the plugin |
| **[SIM]** | Geometry computed/derived, not physically reproduced |
| **[NO-EXEC]** | Not executable on this machine; left pending |

Section references such as §Diseño/Ventana, §Diseño/Tray or §Out of scope point to the
project plan that was current when this report was written (since removed). They are
kept verbatim as historical pointers. Likewise, tray menu labels quoted below
(`Mostrar`/`Ocultar`) are the Spanish labels the product had at the time.

## Versions tested

| Component | Version |
|---|---|
| Flutter | 3.47.2 stable (revision d3b14c8769) · Dart 3.13.2 |
| `window_manager` | 0.5.2 |
| `tray_manager` | 0.5.3 |
| `screen_retriever` | 0.2.2 (transitive via `window_manager`; **not imported**) |
| Windows | Windows 11, a single physical 2560×1600 monitor, DPI 192 (200 % scale), taskbar set to **auto-hide** |

Temporary harness: a separate Flutter project in `%TEMP%\pi_link_t1a_spike`, outside
the delivery tree, with the same pinned versions and no new dependencies
(Win32 access uses `dart:ffi` with `kernel32!LocalAlloc`, without `package:ffi`).
It was run as a compiled `.exe` and deleted afterwards. No change to the product.

---

## Q1 — Showing an `alwaysOnTop` window without activating it

### What `show(inactive: true)` actually does

**[SRC]** `window_manager-0.5.2/lib/src/window_manager.dart:209` accepts
`show({bool inactive = false})` and sends `{'inactive': inactive}` over the method channel.
The Windows native side **ignores the argument**:

- `windows/window_manager_plugin.cpp:383` → `window_manager->Show();` (no arguments).
- `windows/window_manager.cpp:276-288` → `Show()` ends with
  `ShowWindowAsync(hWnd, SW_SHOW); SetForegroundWindow(GetMainWindow());`.
- `grep -rn "inactive" windows/` → **no results**. The parameter is decorative here.

**[SRC]** macOS has the same problem by a different route:
`macos/.../WindowManager.swift:134-140` → `makeKeyAndOrderFront(nil)` +
`NSApp.activate(ignoringOtherApps: true)`, always activates.
**[SRC]** Linux: `linux/window_manager_plugin.cc:95-99` → `gtk_widget_show()`, no
explicit activation; the actual behavior depends on the WM. **[NO-EXEC]**

### Option A — `show(inactive: true)` as is: **FAILS**

**[OBS]** spike-1, three hide/show cycles with the user in another application:

```
[Q1 cycle 2] show(inactive:true)  before: hwnd=1049812 title="pi_link_status - Visual Studio Code"
[Q1 cycle 2]                       after: hwnd=198238  title="PI_LINK_T1A_SPIKE" isFocused=true
[Q1 cycle 3] show(inactive:true)  before: hwnd=1049812 title="pi_link_status - Visual Studio Code"
[Q1 cycle 3]                       after: hwnd=198238  title="PI_LINK_T1A_SPIKE" isFocused=true
```

Focus moved from VS Code to the harness window. Requirement not met.

**[OBS]** It is also **non-deterministic**, which rules it out even as
"works sometimes": in spike-3 the same `show()` stole focus in the first cycle and
did **not** steal it in the second and third, because Windows' foreground lock denies
`SetForegroundWindow` once the process has lost its input rights. The behavior depends
on whether the process was recently in the foreground.

### Option C — `show(inactive: true)` + `blur()`: **DANGEROUS, discarded**

It looked like the cheap solution: show, then give focus back immediately.
**[SRC]** `windows/window_manager.cpp:260-270` — `Blur()` walks the Z-order with
`GetNextWindow(GW_HWNDNEXT)` and calls `SetForegroundWindow` on the **first visible
window it finds**. It does not remember who had focus.

**[OBS]** spike-3, first cycle, measuring the intermediate state (the `<-` annotations
are the author's notes, not log output):

```
[C1] before          : hwnd=198814 title="π - fallout_newvegas_mods - nvse"
[C1] after show      : hwnd=329784 title="PI_LINK_T1A_SPIKE"      <- steals focus
[C1] after blur      : hwnd=393258 title="<untitled hwnd 393258>" <- does NOT give it back
[C1] after blur +500ms: hwnd=393258 title="<untitled hwnd 393258>"
```

Focus did not return to the user's terminal; it ended up in an arbitrary untitled
window. The application in use loses focus permanently. **Discarded.**

### Option B — never call the native `Show()`: does not activate, but **does not close the loop**

> **Historical.** Option **discarded**, evaluated under the earlier contract. v1 does not
> use it (§"Current decision"); it is kept because the measurement is real and explains
> why there was no simple way out within the declared stack.

The window stays `WS_VISIBLE` and its effective visibility is toggled with
`setOpacity()` + `setIgnoreMouseEvents()`, which do not touch the foreground:

- **[SRC]** `SetOpacity` (`window_manager.cpp:1031-1038`) → `WS_EX_LAYERED` +
  `SetLayeredWindowAttributes(hWnd, 0, 255*opacity, LWA_ALPHA)`.
- **[SRC]** `SetIgnoreMouseEvents` (`:1058-1069`) → toggles
  `WS_EX_TRANSPARENT | WS_EX_LAYERED`. At opacity 0 the window is invisible and
  lets clicks through.
- Neither of them calls `ShowWindow` or `SetForegroundWindow`.

**[OBS]** spike-2, three cycles with the user in Firefox:

```
[B cycle 1] before: hwnd=132156 title="Wplace ... Mozilla Firefox"
[B cycle 1]  after: hwnd=132156 title="Wplace ... Mozilla Firefox" isFocused=false IsWindowVisible=1
[B cycle 2] before: hwnd=132156 ... after: hwnd=132156 ... isFocused=false
[B cycle 3] before: hwnd=132156 ... after: hwnd=132156 ... isFocused=false
```

**[OBS] Proof that it is also visible.** Not stealing focus is not enough: it has to be
shown that the window actually paints. The harness was colored pure magenta
(`0xFFFF00FF`), positioned at the physical rect `[200,200,1040,840]`, and an external
screen capture read the real desktop pixels in each phase:

| Phase | Pixel (300,300) | Pixel (600,500) | Foreground | Alt+Tab |
|---|---|---|---|---|
| `armed` (opacity 0) | black | black | user's terminal | meets the heuristic |
| `shown` (opacity 1) | **magenta** | **magenta** | user's terminal | meets the heuristic |
| `hidden` (`hide()`) | black | black | another user app | does not meet it |

In other words: **once the window is already visible**, toggling opacity draws it on
screen without moving focus away from the user's application (`isFocused=false`). That
is what was measured, and only that.

### Why option B does **not** close the loop (critical incompatibility)

The measurement above started from a window that **was already visible and had already
stolen focus**: the harness inherited the runner's standard startup. That detail
invalidates option B as a product path, and it is worth saying so plainly.

**[SRC]** The scaffold shows the window on the first frame:
`windows/runner/flutter_window.cpp:30-32` registers
`SetNextFrameCallback([&]() { this->Show(); })`, and
`windows/runner/win32_window.cpp:152-153` implements
`Win32Window::Show()` as `ShowWindow(window_handle_, SW_SHOWNORMAL)` — which activates.
**[OBS]** Consistent with spike-1's own measurement: before any `show()` from Dart,
`[start] isVisible=true` and the foreground was already ours.

Hence the contradiction, with no way out inside the declared stack:

- **If T6 suppresses that automatic `Show()`** (which is exactly what T6 must do for
  the flash-free startup), the HWND never becomes visible. `setOpacity()` and
  `setIgnoreMouseEvents()` **cannot make a hidden window visible**: they only modify
  attributes of a window that is already `WS_VISIBLE`. Option B stops working.
- **If that `Show()` is kept to "arm"** option B, startup activates the application
  and steals focus again, breaking the requirement (and potentially the flash-free
  startup, depending on what gets painted).

Therefore option B **is not an end-to-end solution with the declared dependencies**: it
would still require an initial native show that does not activate.

Additional lifecycle costs, even if the above were solved:

- `windowManager.isVisible()` would keep returning **true** while the window is
  logically hidden, so a parallel logical state would be needed, and the tray menu
  (`Mostrar`/`Ocultar`, i.e. Show/Hide) and the 1 s age tick — which §Diseño ties to
  visibility — could no longer rely on the native query.
- The Flutter window would always exist for the compositor: transparent,
  *always-on-top* and *click-through*, instead of hidden.
- It is less simple and less efficient than truly hiding, and it contradicts the plan's
  truly-hidden-window semantics.

**The reviewer does not endorse option B for T5.** It is documented as evidence of what
was actually measured, not as a recommended path.

### Exposure in Alt+Tab (evidence by heuristic, not by UI)

While the window is "armed" (`WS_VISIBLE` at opacity 0) it **meets the shell's standard
eligibility heuristic** (visible, no owner, no `WS_EX_TOOLWINDOW`, not *cloaked*, has a
title), and stops meeting it after a real `hide()`. In other words:
**probably visible in Alt+Tab**. The enumeration was done with that heuristic
reimplemented, not by inspecting the actual Alt+Tab interface, whose rules are partly
undocumented. It must not be treated as observed membership in the switcher UI.

**[SRC]** The cause of the exposure: `setSkipTaskbar` uses `ITaskbarList3::DeleteTab`
(`window_manager.cpp:949-963`), which removes the taskbar button but does **not**
set `WS_EX_TOOLWINDOW`; the observed ex-style was `0x80128`
(`WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_WINDOWEDGE`),
without `WS_EX_TOOLWINDOW`. The declared API exposes no way to add it. This proves the
*cause* of the eligibility, not the actual appearance in the switcher.

### Current decision (v1)

Within the audited public APIs and the installed implementations **no suitable route was
found** to show without activating; the source audit strongly supports that conclusion,
although it cannot prove that no third way exists. Given that, the user preferred to
**change the requirement rather than add complexity** (verbatim, in Spanish):

> «No importa para esta primera versión que quite el foco. No hay problema. Aprecio las
> soluciones con menos código y menos complejidad. [...] Continua.»

(Translation: "It doesn't matter for this first version if it takes focus. No problem. I
appreciate solutions with less code and less complexity. [...] Continue.")

**What v1 does** (§Diseño/Enmienda del plan, already amended and approved):

- Plain `windowManager.show()` / `hide()`, both for manual opening and for the
  automatic alert. **The window is allowed to steal focus.**
- **Centered** window, using the centering the plugin already offers. No anchoring to
  the tray icon and no multi-monitor geometry of our own.
- **No** native bridge, **no** opacity workaround, **no** new dependencies.
- The automatic, persistent "all idle" notice, the sticky `alwaysOnTop` window,
  hide-on-click, mute and the membership rules stay unchanged.
- T6 keeps only single instance and a truly hidden startup.

**What stops being a requirement:** non-activation when showing, and the advanced
geometry (anchoring, per-monitor work area, mixed DPI) are no longer gates for
product v1.

### Historical: discarded proposal from the earlier contract

> This section is kept as evidence of the analysis that preceded the amendment.
> **It does not describe v1, and nothing below is implemented or verified.**

While the contract required non-activation, the reviewer proposed a **Windows-only**
native bridge, with no new package and no fork: automatic show with `SW_SHOWNOACTIVATE`,
`SWP_NOACTIVATE` wherever position or z-order was touched, the plugin's normal `show()`
for manual opening — which **could** activate — and a consistent query of the tray
monitor's work area if anchoring was kept. The user initially approved that proposal and
then asked to see options and to simplify the functionality; the outcome was the
amendment described above. **The native bridge was never written or tested**, so there
is no claim that it works.

The seven tests that had been defined for that bridge (flash-free hidden startup,
hidden→show cycles with no foreground change, real hiding, manual opening, clamping
against `rcWork` with an auto-hide taskbar, round-trip at 200 %, pure geometry with
negative origins and small areas) belonged to **that** contract and **are not v1
acceptance criteria**. The current checks are those of §T5 (normal show/hide and
centering on Windows) and §T6 (truly hidden startup).

### Additional finding relevant to T6

**[OBS]** spike-1, before any call to `show()`:
`[start] isVisible=true` and `[start] foreground ... mine=true`. The default runner
shows the window and steals focus on the first frame. **[SRC]** The exact chain is
`flutter_window.cpp:30-32` (`SetNextFrameCallback` → `this->Show()`) →
`win32_window.cpp:152-153` (`ShowWindow(..., SW_SHOWNORMAL)`). This empirically confirms
the need for T6 (suppressing that automatic `Show()`).

This finding is also the reason option B does not close the loop: **the very `Show()`
that T6 must remove is the one that left the window in the `WS_VISIBLE` state on which
option B was measured**. Suppressing it and relying on opacity are mutually exclusive
goals within the declared stack.

---

## Q2 — Tray bounds, work area, units and DPI

> **Historical section.** Investigated under the original contract, which required
> anchoring the window to the tray icon. **v1 neither anchors nor adds geometry of its
> own** (§"Current decision"), so nothing below is a current requirement or acceptance
> criterion. The measurements are real and are kept in case anchoring is ever revisited.

### Units and origin: `tray_manager` and `window_manager` share the view's DPR

The scope of this section is **what was tested**: `tray_manager` and `window_manager`
calls that use the current DPR of the Flutter view, in a **single-monitor, single-DPI**
configuration. It is not a general claim about the whole stack: in particular
`screen_retriever` does **not** share that space (see below).

**[SRC]** Both plugins do the same conversion and share a coordinate space:

- `tray_manager` sends the Flutter view's `devicePixelRatio`
  (`lib/src/tray_manager.dart:35`) and the native side divides the physical rect by it:
  `windows/tray_manager_plugin.cpp:378-388`, on top of `Shell_NotifyIconGetRect`.
- `window_manager` does the same in `getBounds`/`setBounds`
  (`windows/window_manager.cpp:718-740`), with `window.devicePixelRatio`.

**[OBS]** Measured at DPR 2.0 (`GetDpiForWindow` = 192):

| Datum | Logical value (plugin) | Physical value (Win32) |
|---|---|---|
| `windowManager.getBounds()` | `LTRB(10, 10, 430, 330)` | `GetWindowRect` = `[20, 20, 860, 660]` |
| `trayManager.getBounds()` | `LTRB(924, 799, 956, 847)` | ×DPR = `[1848, 1598, 1912, 1694]` |
| Tray monitor | — | `rcMonitor=[0,0,2560,1600]`, `rcWork=[0,0,2560,1600]`, dpi 192 |

Conclusions:

1. **Same space between those two APIs, at a single DPI.** `physical = logical × DPR`
   exactly for the window, and the tray rect uses the same divisor. The origin is that
   of the **virtual screen**, so **it can be negative**; do not clamp to `x >= 0`.
   With mixed DPI this coincidence **is not verified** — see §"Failure mode".
2. **`setPosition` is faithful. [OBS]** `Offset(536, 471)` was requested and
   `getBounds()` returned `LTRB(536, 471, 956, 791)`, physical `[1072, 942, 1912, 1582]`.
   Exact round-trip in the tested configuration (one monitor, 200 %).
3. **Do not multiply by the DPR by hand** when combining `trayManager.getBounds()` with
   `windowManager.getBounds()`/`setPosition()`: those values already arrive converted by
   the same divisor, and scaling them again would double the error. The rule does not
   extend to values coming from `screen_retriever`, which arrive in a different scale.

### The tray rect can fall OUTSIDE the monitor

**[OBS]** Important and counter-intuitive finding: the measured tray rect was
`[1848, 1598, 1912, 1694]` physical on a monitor 1600 px tall. It sticks out **94 px
below the bottom edge** because the taskbar is set to auto-hide and
`Shell_NotifyIconGetRect` returns its retracted position.

Consequence under the original contract: **anchoring without clamping places the window
partially off-screen**; clamping was not a theoretical precaution but a necessity on
this very machine. **If anchoring is ever revisited**, this is the first case to cover.
v1 does not anchor, so it does not apply today.

### The work area is NOT available in the declared stack

**[SRC]** `tray_manager` exposes nothing about the monitor. `window_manager` does not
expose `getWorkArea`/displays either: it obtains that data **internally** from
`screen_retriever` (`lib/src/utils/calc_window_position.dart`), which is transitive and
which this task forbids importing directly.

**[SRC]** What `screen_retriever_windows-0.2.2` would do if it were declared:
`screen_retriever_windows_plugin.cpp:119-124` divides `info.rcWork` and its origin by
the `scale_factor` **of each monitor**. That is a coordinate space **different** from
the view DPR used by `window_manager`/`tray_manager`.

#### Concrete failure mode with mixed DPI **[SRC]**

The mix is not just "inconsistent coordinates": **`calcWindowPosition` can pick the
wrong monitor**. Two different scales coexist inside the same computation:

- `getAllDisplays()` returns `visiblePosition`/`visibleSize` divided by
  **each monitor's DPI** (`screen_retriever_windows_plugin.cpp:119-124`).
- `getCursorScreenPoint()` returns the cursor divided by the **Flutter view's DPR**
  (`screen_retriever_windows_plugin.cpp:196-203`).

`calc_window_position.dart` selects the display with
`Rect(...).contains(cursorScreenPoint)`, comparing the two. **The mismatch is caused by
mixed DPI**: if all monitors share one scale, both divisors are the same number and the
two quantities remain consistent. When the scales differ, the point and the rectangles
are in different units: the check can fail and fall through to
`orElse: primaryDisplay`, or pick the right monitor but return a wrongly scaled position.

A **negative virtual origin by itself does not cause this problem**: with a single scale,
the negative cursor coordinates and the display coordinates are divided by the same
factor and remain comparable. What a negative origin does do is **expose or amplify**
the mismatch when the scales also differ, because the scaling error is applied to a
large offset from the origin. Clamping with negative origins remains, independently,
**not executed** here and must be covered by pure geometry tests.

> **Rule — only if anchoring is revisited** (v1 computes no positions of its own): do
> not mix `setAlignment()` arithmetic with that of `getBounds()`/`setPosition()`. On a
> single monitor with a single DPI they coincide **[OBS]**; with **mixed DPI** the result
> can be either the wrong monitor or wrongly scaled coordinates **[SRC]**, not verified
> physically, and negative origins can amplify that case when the scales differ.

### Experiment: deriving the work area with `setAlignment` → `getBounds`

> **Status: single-display experiment, under the original contract.** It was not a
> ready-to-use solution then, and v1 no longer needs it: there is no anchoring and no
> work-area query. It is documented because the measured datum is real, not because it
> solves anything.

`setAlignment()` does use the work area (`visiblePosition`/`visibleSize` = `rcWork`),
and `getBounds()` allows **reading the result**. By aligning the window while it is
hidden and reading its bounds, the edges of the work area can be inferred, in
`setPosition` space:

- `setAlignment(Alignment.bottomRight)` ⇒ `bounds.right`/`bounds.bottom` = right/bottom
  edge of the work area.
- `setAlignment(Alignment.topLeft)` ⇒ `bounds.left`/`bounds.top` = left/top edge.

**[OBS]** Verified for two alignments (window 420×320 logical, work area
1280×800 logical; `físico` = physical):

```
setAlignment(center)      -> getBounds=LTRB(430, 240, 850, 560)  físico [860, 480, 1700, 1120]
setAlignment(bottomRight) -> getBounds=LTRB(860, 480, 1280, 800) físico [1720, 960, 2560, 1600]
```

`bottomRight` yields exactly `right=1280`, `bottom=800`, which is the real work area
(`rcWork=[0,0,2560,1600]` ÷ 2). `topLeft` uses the same function and returns
`visibleStartX/Y` directly **[SRC]**, but **it was not executed**.

**Why completing `topLeft` would not be enough.** The blockers of this technique are not
about case coverage; they are structural:

- **[SRC]** It targets the **cursor's** display, not the **tray's**. When opening by
  clicking the icon they usually coincide; on an automatic alert-driven opening the
  cursor may be on another monitor, which is precisely the scenario the feature is for.
  **[NO-EXEC]**
- **It mutates the hidden window's position** in order to measure: it turns a query into
  a side effect, with the races that implies against a concurrent `show`.
- **[SRC]** It is not consistent with mixed DPI because of the failure mode described
  above (mixing the view DPR with the per-monitor `scale_factor`), and it is not verified
  there. With a single DPI the computation is consistent, including with negative
  origins, but clamping in that case is still not executed.
- **[NO-EXEC]** Taskbar exclusion could not be observed: on this machine the taskbar is
  auto-hide and `rcWork == rcMonitor`. That `setAlignment` respects `rcWork` is
  **[SRC]**, not observed.
- **[NO-EXEC]** Mixed DPI and monitors with a negative origin: impossible on this
  machine (single monitor). Under the original contract, the clamping arithmetic was to
  be covered by **pure geometry tests** (work areas with negative origin, right edge,
  top/bottom taskbar, and an area smaller than the preferred size). Those were
  **historical** criteria: the v1 amendment withdraws them along with anchoring. In no
  case is it claimed that they were physically tested.

---

## Q3 — Fallback when there are no bounds (Linux) and other limitations

**[SRC]** `tray_manager-0.5.3/linux/tray_manager_plugin.cc:161-167` implements exactly
four methods: `destroy`, `setIcon`, `setTitle`, `setContextMenu`.
There is **no** `getBounds`, **no `setToolTip`**, and no `popUpContextMenu`. Icon mouse
events do not arrive either, but **for a different reason** that should not be conflated
(see below). On Linux, therefore:

- **No anchor is possible, and the call does not degrade silently: it throws.**
  **[SRC]** The native handler answers `fl_method_not_implemented_response_new()` to
  any method outside those four (`linux/tray_manager_plugin.cc:161-176`), and
  `TrayManager.getBounds()` uses a plain `MethodChannel`, not an
  `OptionalMethodChannel` (`lib/src/tray_manager.dart:205-216`), so Flutter turns that
  response into a **`MissingPluginException`**
  (`packages/flutter/lib/src/services/platform_channel.dart:351-365,539`).
  In other words: on Linux `getBounds()` **does not return `null`**, **it throws**.
  The Dart `null` path is only taken when the native side replies success with no data,
  which on Windows happens if the icon has not been set yet
  (`windows/tray_manager_plugin.cpp:373-376`).
  **Direct consequence for T5's wiring:** the product must **avoid or guard** that call
  on Linux and **explicitly select** the centered fallback, instead of relying on a null
  value that never arrives.
- **Invocable but unimplemented methods — they throw.** `setToolTip` and
  `popUpContextMenu` are in the same situation as `getBounds`: they are Dart→native
  calls that fall into the handler's `else`, so an unconditional invocation **throws
  `MissingPluginException`** instead of degrading silently. They must be guarded.
- **Icon mouse events — they do not throw: they simply never happen.** This is **not**
  a Dart call that fails but the opposite: they are callbacks that the native code emits
  towards Dart. **[SRC]** The Linux plugin only invokes `onTrayMenuItemClick`
  (`linux/tray_manager_plugin.cc:42-50`); it never emits `onTrayIconMouseDown` or
  `onTrayIconRightMouseDown`, which Windows does send
  (`windows/tray_manager_plugin.cpp:201-205`). There is nothing to guard with a `try`:
  the `TrayListener` handlers exist and are simply never called.
  **For T5:** on Linux, interaction must rely on the menu items, not on the icon click.
- **No tooltip.** The status summary of §Diseño/Tray does not exist on Linux; the icon
  color, the menu and the window are the only signal. It was a **limitation discovered
  in T1a** and **the v1 amendment already accepts it explicitly**: the plan says not to
  invoke `setToolTip` on Linux (§Diseño/Tray) and records the degradation under
  §Out of scope. No acceptance remains pending.
- **No left-click event**: the "Mostrar" (Show) menu item is the only way. Already
  planned for.

**[OBS]** In the tested configuration (Windows, one 1280×800 logical display, window
420×320), the `setAlignment` fallback left the window fully inside the work area
(`center` and `bottomRight`, table in Q2). **It is not a general guarantee**: it is not
verified for work areas smaller than the window's preferred size, nor for mixed DPI —
where the monitor-selection failure mode described in Q2 also applies —, nor for
negative origins, which remain unexecuted even though with a single scale the
computation is consistent. The same Dart code is used on all three platforms **[SRC]**,
but on Linux it depends on `screen_retriever_linux`, not executed here **[NO-EXEC]**.

**[SRC]** macOS: `tray_manager` does implement `getBounds`
(`macos/.../TrayManagerPlugin.swift:117`), so anchoring is viable; but
`window_manager.show()` calls `NSApp.activate(ignoringOtherApps: true)`, so the focus
problem of Q1 **also exists on macOS** and option B (opacity) would have to be
re-validated there. **[NO-EXEC]**

### Summary by platform

| Capability | Windows | macOS | Linux |
|---|---|---|---|
| Show without activating via `show(inactive:)` | **No** [OBS] | **No** [SRC] | Probably [SRC], unverified |
| Opacity without activating, **starting from an already visible window** | Yes [OBS] | Plausible, unverified | Plausible, unverified |
| Full hidden → visible cycle without activating | **No** [OBS+SRC] — requires a non-activating initial show | **No** [SRC] — `show()` forces `NSApp.activate` | **Unverified [NO-EXEC]** — `gtk_widget_show()` does not activate explicitly; depends on the WM |
| `trayManager.getBounds()` | Yes [OBS] | Yes [SRC] | **Does not exist — throws `MissingPluginException`** [SRC] |
| Tray tooltip | Yes [SRC] | Yes [SRC] | **Does not exist — throws** [SRC] |
| Work area via `setAlignment` | Only tested on 1 display, single DPI [OBS] | Yes [SRC] | Yes [SRC], unverified |

---

## Procedure (reproducible)

1. `flutter create --platforms=windows` in `%TEMP%\pi_link_t1a_spike`; pin
   `tray_manager: 0.5.3` and `window_manager: 0.5.2` (exact versions, no `^`);
   copy `assets/tray/idle.ico` from the product.
2. `lib/main.dart`: initialize `window_manager`, `waitUntilReadyToShow` with
   `size 420×320`, `skipTaskbar`, `alwaysOnTop`, `TitleBarStyle.hidden` and a unique
   title; read the Win32 ground truth with `dart:ffi`
   (`GetForegroundWindow`, `GetWindowTextW`, `FindWindowW`, `GetWindowRect`,
   `MonitorFromRect`, `GetMonitorInfoW`, `GetDpiForWindow`, `GetDpiForMonitor`),
   with `LocalAlloc`/`LocalFree` memory. Log everything to `spike.log`.
3. `flutter build windows --debug` and launch the `.exe` with `Start-Process` (not
   `flutter run`, so as not to couple focus to the launching terminal).
4. Four passes: (1) units + `show(inactive:)` + opacity, (2) `show+blur` and opacity
   test with screen capture, (3) intermediate state of `show+blur`,
   (4) `armed`/`shown`/`hidden` phases with pixel capture and Alt+Tab enumeration.
5. Captures with `System.Drawing.Graphics.CopyFromScreen` after `SetProcessDPIAware`,
   reading specific pixels inside the window's physical rect.
6. Delete the harness directory.

No input injection into the user's applications: it was only **observed** which window
had the foreground. The pi-link hub and port 9900 were not touched.

## What applies to T5 after the amendment

**T5 is no longer blocked.** With the current decision, what remains of this report is
short:

- Use plain `show()`/`hide()` and the **plugin's centering**. No need to anchor to the
  tray, derive the work area, or write multi-monitor geometry of our own.
- **Guard every call to `trayManager.getBounds()`/`setToolTip()` on Linux**: they throw
  `MissingPluginException`, they do not return `null` (§Q3). This point **does** remain
  in force and is the finding of this report with the most impact on T5's code.
- Linux is left without a tray tooltip; the plan treats it as an already accepted
  degradation.
- macOS and Linux are still not executed here: their runtime behavior is declared as
  pending, not as validated.

No longer applicable to v1, by the amendment: showing without activating, the native
bridge, the opacity option, anchoring to the icon, and the geometry tests for mixed DPI,
negative origins and areas smaller than the window.
