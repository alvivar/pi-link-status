import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'idle_alert.dart';
import 'poller.dart';
import 'status_window.dart';
import 'tray.dart';

/// Logical size of the status window. Fixed: there is nothing to resize.
const _windowSize = Size(420, 320);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  // No show() here: the window must not appear until asked for. The Windows
  // runner creates it without WS_VISIBLE and no longer shows it on the first
  // frame, so nothing on the native side has to be undone; [App] still hides
  // once after that frame as a defensive step.
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: _windowSize,
      center: true,
      skipTaskbar: true,
      alwaysOnTop: true,
      title: 'pi-link status',
    ),
  );
  await windowManager.setAsFrameless();
  // WindowOptions.size is only the initial size and the plugin starts
  // resizable, so 420×320 stays an invariant only by dropping WS_THICKFRAME
  // (window_manager.cpp:812) — which also disables Aero Snap — and the
  // maximize style (window_manager.cpp:847).
  await windowManager.setResizable(false);
  await windowManager.setMaximizable(false);
  // Turns the close button and ⌘W into onWindowClose, so the window hides
  // instead of being destroyed. Quitting is a tray decision.
  await windowManager.setPreventClose(true);
  runApp(const App());
}

class App extends StatefulWidget {
  const App({super.key, this.poller});

  /// Injected by tests only, so they never reach the real hub port.
  @visibleForTesting
  final Poller? poller;

  @override
  State<App> createState() => _AppState();
}

/// The only owner: poller, alert machine, tray, historical time and
/// visibility. Everything else receives what it needs.
class _AppState extends State<App> with WindowListener {
  late final Poller _poller = widget.poller ?? Poller();
  final _alert = IdleAlert();
  late final _tray = Tray(
    onToggleWindow: () => _setVisible(!_wanted),
    onToggleMute: _toggleMute,
    onQuit: _quit,
  );

  /// Historical "all idle" time, mirrored from [IdleAlert] for the window.
  final _lastAllIdle = ValueNotifier<DateTime?>(null);

  /// Visibility the user asked for, updated the instant they click, so two
  /// fast clicks toggle twice instead of showing twice.
  bool _wanted = false;

  /// Counts visibility intents. A failed action reconciles [_wanted] only
  /// while its own intent is still the newest, because clicking twice returns
  /// to the same boolean while being a newer decision.
  int _wantedRevision = 0;

  /// Visibility actually applied by the plugin. Drives the menu and the tick.
  bool _visible = false;

  /// Serializes every native call: window and tray share one queue, so a poll
  /// can never apply an older snapshot on top of a newer one. It never carries
  /// an error — [_run] handles each failure — so one broken native call can
  /// never skip the actions behind it, quit above all.
  Future<void> _queue = Future.value();

  /// No new work is accepted. Set synchronously by quit and by disposal.
  bool _stopped = false;

  /// Whether what the owner allocated was already freed.
  bool _released = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _poller.status.addListener(_onStatus);
    // Ordered startup: listeners and tray first, polling only once the tray
    // exists, so the very first sample has somewhere to land.
    _enqueue('starting the tray', () async {
      // The poller starts even if the tray failed: a broken icon must not
      // leave the window blind as well.
      try {
        await _tray.init();
      } finally {
        _poller.start();
      }
    });
    // Startup is already hidden: the runner creates the window without
    // WS_VISIBLE and never shows it, and [_visible] starts false, so this hide
    // is expected to change nothing. It stays as a cheap guard for the case
    // where something else along the startup path puts the window on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _enqueue('hiding the window at startup', () async {
        await windowManager.hide();
        _apply(visible: false);
      });
    });
  }

  @override
  void dispose() {
    _stop();
    _destroyTray();
    _release();
    super.dispose();
  }

  /// Stops every source of new work, synchronously and idempotently: after
  /// this no tray click, poll result or queued action touches the app.
  void _stop() {
    if (_stopped) return;
    _stopped = true;
    // Now, not when the queue eventually reaches destroy(): otherwise a click
    // during shutdown still opens a menu or enqueues work.
    _tray.deactivate();
    windowManager.removeListener(this);
    _poller.status.removeListener(_onStatus);
    // Returns immediately; the attempt in flight settles its own cleanup.
    _poller.dispose();
  }

  /// Frees what the owner allocated. Idempotent: quit and disposal both ask.
  void _release() {
    if (_released) return;
    _released = true;
    _lastAllIdle.dispose();
  }

  /// Removes the icon once the queue drains, so quitting or an ordinary
  /// disposal does not leave a dead icon behind. [Tray.destroy] is itself
  /// idempotent, so quitting and then being disposed still removes it once.
  void _destroyTray() {
    _queue = _queue.then(
      (_) => _run('destroying the tray icon', _tray.destroy),
    );
  }

  /// Runs [action] after everything already queued, unless the app stopped.
  void _enqueue(String what, Future<void> Function() action) {
    _queue = _queue.then((_) => _stopped ? null : _run(what, action));
  }

  /// Runs [action] reporting a failure instead of propagating it: a native
  /// error must not poison the queue nor skip the cleanup behind it.
  Future<void> _run(String what, Future<void> Function() action) async {
    try {
      await action();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'pi_link_status',
          context: ErrorDescription('while $what'),
        ),
      );
    }
  }

  /// One poll result: feed the machine, mirror the history, repaint the tray,
  /// and open the window if the alert says so.
  void _onStatus() {
    final status = _poller.status.value;
    // The full snapshot, not just the fleet: membership lives in IdleAlert.
    final alert = _alert.observe(status, DateTime.now());
    _lastAllIdle.value = _alert.lastAllIdle;
    if (alert) _setVisible(true);
    _enqueue(
      'syncing the tray',
      () => _tray.sync(status, muted: _alert.muted, windowVisible: _visible),
    );
  }

  void _setVisible(bool visible) {
    if (_stopped) return;
    _wanted = visible;
    _wantedRevision++;
    _enqueue(
      visible ? 'showing the window' : 'hiding the window',
      _applyVisibility,
    );
  }

  /// Applies the visibility the user last asked for. Nothing to do when it is
  /// already applied — that is how an alert on an open window updates the data
  /// without showing or activating it again.
  Future<void> _applyVisibility() async {
    final target = _wanted;
    final revision = _wantedRevision;
    if (target == _visible) return;
    try {
      if (target) {
        // The plugin's own centring, and its ordinary activating show: taking
        // focus is accepted for v1.
        await windowManager.center();
        await windowManager.show();
      } else {
        await windowManager.hide();
      }
    } catch (_) {
      // The window did not move: put the intent back on what is real, so the
      // next click retries instead of toggling away from a state that was
      // never reached — but only while this is still the newest intent. Two
      // clicks during the failed call ask for the same boolean again, and
      // that newer request must survive the rollback.
      if (revision == _wantedRevision) _wanted = _visible;
      rethrow;
    }
    _apply(visible: target);
    await _tray.sync(
      _poller.status.value,
      muted: _alert.muted,
      windowVisible: _visible,
    );
  }

  /// Records the visibility the plugin applied and rebuilds the window with it.
  void _apply({required bool visible}) {
    if (!mounted || _stopped || visible == _visible) return;
    setState(() => _visible = visible);
  }

  void _toggleMute() {
    if (_stopped || !mounted) return;
    setState(() => _alert.muted = !_alert.muted);
    // Muting neither hides the window nor replays suppressed alerts.
    _enqueue(
      'syncing the tray',
      () => _tray.sync(
        _poller.status.value,
        muted: _alert.muted,
        windowVisible: _visible,
      ),
    );
  }

  /// Close means hide: with preventClose the window is never destroyed.
  @override
  void onWindowClose() => _setVisible(false);

  /// Stops everything in order and lets the process end on its own.
  void _quit() {
    if (_stopped) return;
    _stop();
    // Appended directly, not through [_enqueue], which now refuses work. Each
    // step is independent: a tray that fails to disappear must not keep the
    // window — and with it the process — alive.
    _destroyTray();
    _queue = _queue.then((_) async {
      _release();
      // Windows: posts WM_QUIT, so the runner's message loop ends and the
      // process exits by itself. No exit(0) papering over a stuck cleanup.
      await _run('destroying the window', windowManager.destroy);
    });
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'pi-link status',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      // Segoe UI is the Windows interface font; the panel asks for nothing
      // else, and its own styles inherit the family from here.
      fontFamily: 'Segoe UI',
      // The same graphite the panel paints, so nothing lighter can appear
      // behind it for a frame.
      scaffoldBackgroundColor: graphiteSurface,
    ),
    home: StatusView(
      status: _poller.status,
      lastAllIdle: _lastAllIdle,
      muted: _alert.muted,
      visible: _visible,
      onTap: () => _setVisible(false),
    ),
  );
}
