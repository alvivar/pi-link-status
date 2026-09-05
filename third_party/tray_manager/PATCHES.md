# tray_manager 0.5.3, patched

This is a local copy of the published `tray_manager` package with **one**
correction: the Windows plugin's two native members are now value-initialized.
`pubspec.yaml` points at this copy through `dependency_overrides` while keeping
the `tray_manager: ^0.5.3` dependency, so removing the override is all it takes
to go back to the published package.

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

## The delta

`windows/tray_manager_plugin.cpp`, lines 49-50:

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
so `hIcon` starts null, `szTip` starts empty and `niif` starts zeroed. Nothing
else is changed: no logic, no API, no other platform.

Note on the boundaries of the bug: the `szTip` copy is *not* an out-of-bounds
read. `nid.szTip` and the local backup are both `WCHAR[128]` and `StringCchCopy`
is bounded by the destination size. The defect is the indeterminate read, the
`DestroyIcon` on a garbage handle, and the garbage tooltip — not a buffer
overrun.

## Upstream status

There is no released fix. 0.5.3 is the newest version on pub.dev, and upstream
`main` (`packages/tray_manager/windows/tray_manager_plugin.cpp`, newest commit
touching it `43eb1471bd`, 2025-11-01) still declares both members uninitialized.

## Maintenance cost

Keeping this copy is not free:

- Every future `tray_manager` release has to be re-vendored by hand: download
  the archive, verify its hash, replace these files, re-apply the delta, and
  re-check the diff. There is no automation.
- We now own a third-party plugin's macOS and Linux sources as well. They are
  byte-identical to upstream and unmodified, but they are ours to update, and
  neither has been built or run from this copy — those platforms stay pending.
- The Dart analyzer sees a second package inside the repository.

**To remove it**, once upstream ships the initializers: delete this directory,
delete the `dependency_overrides` block in the root `pubspec.yaml`, raise the
`tray_manager` constraint to the fixed version, and run `flutter pub get`.
