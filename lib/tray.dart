import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import 'link_status.dart';

/// The tray icon: colour, tooltip and menu, plus the three user actions.
///
/// Knows nothing about the window or the poller — the owner injects what the
/// clicks mean. It only remembers what it has already applied, so a poll that
/// changes nothing visible costs no plugin calls.
class Tray with TrayListener {
  Tray({
    required this.onToggleWindow,
    required this.onToggleMute,
    required this.onQuit,
  });

  final VoidCallback onToggleWindow;
  final VoidCallback onToggleMute;
  final VoidCallback onQuit;

  /// Values successfully applied to the plugin; `null` until the first sync.
  /// They are only assigned after the await, so a failed call is retried on the
  /// next sample instead of being remembered as applied.
  String? _icon;
  String? _tooltip;
  (bool muted, bool windowVisible)? _menu;

  /// Whether clicks are still accepted. Every callback checks it, so shutting
  /// down is instantaneous and does not depend on the async [destroy].
  bool _active = false;
  bool _destroyed = false;

  /// Registers for clicks and paints the initial offline state.
  Future<void> init() async {
    _active = true;
    trayManager.addListener(this);
    await sync(const NoHub(), muted: false, windowVisible: false);
  }

  /// Applies [status] to the icon, tooltip and menu, skipping whatever already
  /// matches. The caller serializes these calls; nothing here is reentrant.
  Future<void> sync(
    LinkStatus status, {
    required bool muted,
    required bool windowVisible,
  }) async {
    // The menu goes first, and not for cosmetic reasons: if the icon cannot be
    // registered at startup the plugin reports an error, and everything after
    // it in this method is skipped. Configuring the menu first means that when
    // the icon does appear — the plugin retries a failed registration on its
    // own — it already has 'Quit' on it. The other order leaves a hidden app
    // with an icon and no way to close it.
    final menu = (muted, windowVisible);
    if (menu != _menu) {
      await trayManager.setContextMenu(_menuFor(muted, windowVisible));
      _menu = menu;
    }
    final icon = _iconPath(status.fleet);
    if (icon != _icon) {
      await trayManager.setIcon(icon);
      _icon = icon;
    }
    // Linux (AppIndicator) has no tooltip: the method is not implemented and
    // throws MissingPluginException, so it is never called there.
    if (!Platform.isLinux) {
      final tooltip = tooltipFor(status);
      if (tooltip != _tooltip) {
        await trayManager.setToolTip(tooltip);
        _tooltip = tooltip;
      }
    }
  }

  /// Stops accepting clicks, immediately and idempotently. Unregistering is
  /// deferred one microtask on purpose: this is called *from* a tray callback
  /// (the 'Quit' item), and tray_manager dispatches while iterating its
  /// ObserverList (tray_manager.dart:42), which a removal mid-loop would break.
  void deactivate() {
    if (!_active) return;
    _active = false;
    scheduleMicrotask(() => trayManager.removeListener(this));
    // The native recovery timer has to stop now. [destroy] would stop it too,
    // but the owner queues that behind whatever tray work is already running,
    // and a held call makes that interval unbounded — the timer would keep
    // re-adding an icon for an app that is quitting. Not awaited on purpose,
    // so this only guarantees the request is dispatched ahead of the queued
    // work, not that the native cancel has run by the time this returns; a
    // failure is reported rather than dropped.
    if (Platform.isWindows) {
      trayManager.deactivateRecovery().catchError((
        Object error,
        StackTrace stack,
      ) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'pi_link_status',
            context: ErrorDescription('while stopping tray icon recovery'),
          ),
        );
      });
    }
  }

  /// Removes the icon. Idempotent: quit and disposal may both ask for it.
  Future<void> destroy() async {
    deactivate();
    if (_destroyed) return;
    _destroyed = true;
    await trayManager.destroy();
  }

  @override
  void onTrayIconMouseDown() {
    if (!_active) return;
    onToggleWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    // Not implemented on Linux, where AppIndicator opens the menu itself; the
    // 'Show' item is what keeps the window reachable there.
    if (!_active || Platform.isLinux) return;
    // Deliberately not serialized with [sync]: the menu must open at click
    // time, not behind a poll's icon update. It applies no app state — but its
    // failure is reported rather than dropped on the floor.
    trayManager.popUpContextMenu().catchError((Object error, StackTrace stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'pi_link_status',
          context: ErrorDescription('while opening the tray menu'),
        ),
      );
    });
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (!_active) return;
    switch (menuItem.key) {
      case 'show':
        onToggleWindow();
      case 'mute':
        onToggleMute();
      case 'quit':
        onQuit();
    }
  }

  /// `unknown` reuses the busy asset on purpose: the texts distinguish them.
  String _iconPath(FleetState fleet) {
    final asset = switch (fleet) {
      FleetState.offline => 'offline',
      FleetState.compacting => 'compacting',
      FleetState.busy || FleetState.unknown => 'busy',
      FleetState.idle => 'idle',
    };
    return 'assets/tray/$asset.${Platform.isWindows ? 'ico' : 'png'}';
  }

  Menu _menuFor(bool muted, bool windowVisible) => Menu(
    items: [
      // The key stays 'show' in both states: it is a toggle, not two actions.
      MenuItem(key: 'show', label: windowVisible ? 'Hide' : 'Show'),
      MenuItem.checkbox(key: 'mute', label: 'Mute alerts', checked: muted),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'),
    ],
  );
}

/// One line, ≤ 127 characters (the Windows limit). Only the counts vary, and
/// no name from the payload is interpolated, so the length is bounded by
/// construction.
@visibleForTesting
String tooltipFor(LinkStatus status) {
  if (status is! Online) {
    return status is Unsupported
        ? 'pi-link · outdated hub (update pi-link)'
        : 'pi-link · no hub';
  }
  var working = 0;
  var unknown = 0;
  for (final terminal in status.terminals) {
    switch (terminal.status) {
      case 'compacting' || 'thinking':
        working++;
      case final s? when s.startsWith('tool:'):
        working++;
      case 'idle':
        break;
      default:
        unknown++;
    }
  }
  final summary = StringBuffer('pi-link · ${status.terminals.length} online');
  if (working > 0) summary.write(' · $working working');
  if (unknown > 0) summary.write(' · $unknown unknown');
  if (working == 0 && unknown == 0) summary.write(' · all idle');
  return summary.toString();
}
