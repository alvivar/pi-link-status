import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_link_status/link_status.dart';
import 'package:pi_link_status/main.dart';
import 'package:pi_link_status/poller.dart';
import 'package:pi_link_status/status_window.dart';
import 'package:pi_link_status/tray.dart';

void main() {
  // The real window size: overflow only means something at 420×320.
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.single;
    view.physicalSize = const Size(420, 320);
    view.devicePixelRatio = 1.0;
    addTearDown(view.reset);
  });

  final at = DateTime(2024, 5, 6, 15, 4, 30);

  Online online(List<Terminal> terminals, {DateTime? receivedAt}) => Online(
    hub: terminals.first.name,
    terminals: terminals,
    receivedAt: receivedAt ?? at,
  );

  Terminal terminal(
    String name, {
    String? status = 'idle',
    int? since = 10,
    String? cwd = 'C:/code/pi_link_status',
    ContextUsage? context = const ContextUsage(tokens: 92000, window: 272000),
  }) => Terminal(
    name: name,
    role: 'hub',
    status: status,
    sinceSeconds: status == null ? null : since,
    cwd: cwd,
    context: context,
  );

  /// Pumps a [StatusView] with everything the owner would pass, returning the
  /// notifiers so a test can push a new snapshot.
  Future<
    ({
      ValueNotifier<LinkStatus> status,
      ValueNotifier<DateTime?> lastAllIdle,
      List<void> taps,
    })
  >
  pumpView(
    WidgetTester tester, {
    required LinkStatus status,
    DateTime? lastAllIdle,
    bool muted = false,
    bool visible = true,
    DateTime Function()? clock,
  }) async {
    final statusNotifier = ValueNotifier<LinkStatus>(status);
    final idleNotifier = ValueNotifier<DateTime?>(lastAllIdle);
    addTearDown(statusNotifier.dispose);
    addTearDown(idleNotifier.dispose);
    final taps = <void>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: StatusView(
          status: statusNotifier,
          lastAllIdle: idleNotifier,
          muted: muted,
          visible: visible,
          onTap: () => taps.add(null),
          clock: clock ?? () => at,
        ),
      ),
    );
    return (status: statusNotifier, lastAllIdle: idleNotifier, taps: taps);
  }

  group('header', () {
    testWidgets('states the scope, the hub and the historical time', (
      tester,
    ) async {
      await pumpView(
        tester,
        status: online([terminal('opus@pi-link')]),
        lastAllIdle: DateTime(2024, 5, 6, 9, 7),
      );

      expect(find.text('Toda la red pi-link'), findsOneWidget);
      expect(find.text('opus@pi-link · 1 online'), findsOneWidget);
      expect(find.text('Última vez todos idle: 09:07'), findsOneWidget);
      expect(find.text('Click para ocultar'), findsOneWidget);
    });

    testWidgets('shows a dash when it never happened', (tester) async {
      await pumpView(tester, status: const NoHub());

      expect(find.text('Última vez todos idle: —'), findsOneWidget);
    });

    testWidgets('announces the muted alerts only while muted', (tester) async {
      await pumpView(
        tester,
        status: online([terminal('opus@pi-link')]),
        muted: true,
      );
      expect(find.text('Alertas silenciadas'), findsOneWidget);

      await pumpView(tester, status: online([terminal('opus@pi-link')]));
      expect(find.text('Alertas silenciadas'), findsNothing);
    });

    testWidgets('all idle is a current state, not a memory', (tester) async {
      final view = await pumpView(
        tester,
        status: online([terminal('opus@pi-link')]),
        lastAllIdle: DateTime(2024, 5, 6, 9, 7),
      );
      expect(find.text('Todos los agentes están idle'), findsOneWidget);

      // Work resumes while the window is open: the claim goes, the history
      // stays.
      view.status.value = online([
        terminal('opus@pi-link', status: 'thinking', since: 2),
      ]);
      await tester.pump();

      expect(find.text('Todos los agentes están idle'), findsNothing);
      expect(find.text('thinking (2s)'), findsOneWidget);
      expect(find.text('Última vez todos idle: 09:07'), findsOneWidget);
    });
  });

  group('terminals', () {
    testWidgets('renders status, age, context and shortened path', (
      tester,
    ) async {
      await pumpView(
        tester,
        status: online([
          terminal('opus@pi-link', status: 'tool:link_send', since: 12),
        ]),
      );

      expect(find.text('opus@pi-link'), findsOneWidget);
      expect(find.text('tool:link_send (12s)'), findsOneWidget);
      expect(find.text('92K/272K (34%)'), findsOneWidget);
      expect(find.text('C:/code/pi_link_status'), findsOneWidget);
    });

    testWidgets('unknown status, missing cwd and no context read as ?', (
      tester,
    ) async {
      await pumpView(
        tester,
        status: online([
          terminal('opus@pi-link', status: null, cwd: null, context: null),
        ]),
      );

      expect(find.text('?'), findsNWidgets(3)); // status, context and cwd
    });

    testWidgets('ten terminals with long names and paths do not overflow', (
      tester,
    ) async {
      final long = List.generate(
        10,
        (i) => terminal(
          'very-long-terminal-name-number-$i@pi-link-hub-machine',
          status: 'tool:some_extremely_long_tool_name_$i',
          since: 3600,
          cwd:
              'C:/Users/andre/code/some/deeply/nested/workspace/directory/'
              'project-number-$i',
        ),
      );
      await pumpView(tester, status: online(long));

      expect(tester.takeException(), isNull);
      // Header and footer keep their place while the list scrolls.
      expect(find.text('Toda la red pi-link'), findsOneWidget);
      expect(find.text('Click para ocultar'), findsOneWidget);
      expect(
        find.text('very-long-terminal-name-number-9@pi-link-hub-machine'),
        findsNothing,
      );

      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(
        find.text('very-long-terminal-name-number-9@pi-link-hub-machine'),
        findsOneWidget,
      );
      expect(find.text('Click para ocultar'), findsOneWidget);
    });
  });

  group('hiding', () {
    testWidgets('a click anywhere hides, a drag does not', (tester) async {
      final view = await pumpView(
        tester,
        status: online(List.generate(10, (i) => terminal('terminal-$i@pi'))),
      );

      expect(find.text('terminal-9@pi'), findsNothing);

      // A wheel scroll over the list: it moves, and it is not a click.
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(200, 200),
          scrollDelta: Offset(0, 600),
        ),
      );
      await tester.pump();
      expect(find.text('terminal-9@pi'), findsOneWidget, reason: 'scrolled');
      expect(view.taps, isEmpty, reason: 'scrolling is not a click');

      // A drag over the list.
      await tester.drag(find.byType(ListView), const Offset(0, -120));
      await tester.pump();
      expect(view.taps, isEmpty, reason: 'dragging is not a click');

      // A click on the list, on the header, and on empty padding where no
      // child can answer: all three hide.
      await tester.tap(find.byType(ListView));
      await tester.tap(find.text('Toda la red pi-link'));
      await tester.tapAt(const Offset(415, 317));
      await tester.pump();
      expect(view.taps, hasLength(3));
    });
  });

  group('ages', () {
    testWidgets('tick every second while visible', (tester) async {
      var now = at;
      await pumpView(
        tester,
        status: online([terminal('opus@pi-link', since: 10)]),
        clock: () => now,
      );
      expect(find.text('idle (10s)'), findsOneWidget);

      now = at.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('idle (11s)'), findsOneWidget);

      now = at.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('idle (12s)'), findsOneWidget);
    });

    testWidgets('do not tick while hidden, and catch up when shown', (
      tester,
    ) async {
      var now = at;
      final status = ValueNotifier<LinkStatus>(
        online([terminal('opus@pi-link', since: 10)]),
      );
      final lastAllIdle = ValueNotifier<DateTime?>(null);
      addTearDown(status.dispose);
      addTearDown(lastAllIdle.dispose);

      Future<void> pumpVisible(bool visible) => tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: StatusView(
            status: status,
            lastAllIdle: lastAllIdle,
            muted: false,
            visible: visible,
            onTap: () {},
            clock: () => now,
          ),
        ),
      );

      await pumpVisible(false);
      now = at.add(const Duration(seconds: 30));
      // A pending periodic timer here would fail this test at teardown.
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('idle (10s)'), findsOneWidget);

      await pumpVisible(true);
      expect(find.text('idle (40s)'), findsOneWidget, reason: 'caught up');

      // Hiding again stops the tick, and the widget going away cancels it.
      await pumpVisible(false);
      now = at.add(const Duration(seconds: 90));
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('idle (40s)'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('offline states', () {
    testWidgets('NoHub explains the promotion delay', (tester) async {
      await pumpView(tester, status: const NoHub());

      expect(find.textContaining('No hay hub en :9900'), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
    });

    testWidgets('Unsupported asks for an upgrade', (tester) async {
      await pumpView(tester, status: const Unsupported());

      expect(
        find.textContaining('actualiza pi-link y reinicia los terminales'),
        findsOneWidget,
      );
    });
  });

  group('tray tooltip', () {
    test('says there is no hub, and that an old hub needs upgrading', () {
      expect(tooltipFor(const NoHub()), 'pi-link · sin hub');
      expect(
        tooltipFor(const Unsupported()),
        'pi-link · hub antiguo (actualiza pi-link)',
      );
    });

    test('an idle fleet is called idle', () {
      expect(
        tooltipFor(online([terminal('opus@pi-link'), terminal('sol@pi-link')])),
        'pi-link · 2 online · todos idle',
      );
    });

    test('counts thinking, tool:* and compacting as working', () {
      expect(
        tooltipFor(
          online([
            terminal('a@pi-link', status: 'thinking'),
            terminal('b@pi-link', status: 'tool:bash'),
            terminal('c@pi-link', status: 'compacting'),
            terminal('d@pi-link'),
          ]),
        ),
        'pi-link · 4 online · 3 trabajando',
      );
    });

    test('counts absent and unrecognised states as unknown', () {
      expect(
        tooltipFor(
          online([
            terminal('a@pi-link', status: 'thinking'),
            terminal('b@pi-link', status: null),
            terminal('c@pi-link', status: 'meditating'),
            terminal('d@pi-link'),
          ]),
        ),
        'pi-link · 4 online · 1 trabajando · 2 desconocido',
      );
    });

    test(
      'stays one line under 127 chars with long names and ten terminals',
      () {
        final tooltip = tooltipFor(
          online([
            for (var i = 0; i < 10; i++)
              terminal(
                'very-long-terminal-name-number-$i@pi-link-machine',
                status: i.isEven ? 'idle' : 'tool:some_long_tool_name',
              ),
          ]),
        );

        expect(tooltip, 'pi-link · 10 online · 5 trabajando');
        expect(tooltip.length, lessThanOrEqualTo(127));
        expect(tooltip, isNot(contains('\n')));
        // No name from the payload is interpolated: that is what bounds it.
        expect(tooltip, isNot(contains('@')));
      },
    );
  });

  group('app lifecycle', () {
    // The real App against mocked plugin channels: tray_manager,
    // window_manager and Poller all run their own code; only the native side
    // and the network are replaced.
    late _Plugins plugins;
    late List<FlutterErrorDetails> reported;
    late void Function() restoreErrors;

    setUp(() {
      plugins = _Plugins()..install();
      reported = <FlutterErrorDetails>[];
    });

    /// Starts the app with a poller that never reaches the network. Also takes
    /// over the error reporting, which flutter_test installs per test, so a
    /// handled native failure is evidence instead of a test failure.
    Future<void> pumpApp(WidgetTester tester) async {
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      restoreErrors = () => FlutterError.onError = previous;
      addTearDown(restoreErrors);
      await tester.pumpWidget(
        App(
          poller: Poller(
            openRequest: (client, uri) =>
                Future.error(const SocketException('no hub in tests')),
          ),
        ),
      );
      await drain(tester);
    }

    testWidgets('a failed native call neither poisons the queue nor quit', (
      tester,
    ) async {
      plugins.failing.add('window_manager.show');
      await pumpApp(tester);

      await plugins.trayEvent('onTrayIconMouseDown');
      await drain(tester);
      expect(plugins.calls, contains('window_manager.show'));
      expect(reported.single.context.toString(), 'while showing the window');

      // The queue survived: later actions still reach the plugin.
      plugins.failing.clear();
      await plugins.trayEvent('onTrayIconMouseDown');
      await drain(tester);
      expect(
        plugins.calls.where((c) => c == 'window_manager.show').length,
        2,
        reason: 'the failed intent was reconciled, so a click retries showing',
      );

      await plugins.clickMenuItem('quit');
      await drain(tester);
      expect(plugins.calls, contains('window_manager.destroy'));
    });

    testWidgets('two clicks during a failed show keep the newest intent', (
      tester,
    ) async {
      await pumpApp(tester);
      plugins.failing.add('window_manager.show');
      final showing = plugins.hold('window_manager.show');

      await plugins.trayEvent('onTrayIconMouseDown'); // show, held mid-call
      await drain(tester);
      // Two clicks while that show is stuck: hide, then show again. The newest
      // intent is the same boolean the stuck call is applying, so reconciling
      // it away would silently drop the user's latest decision.
      await plugins.trayEvent('onTrayIconMouseDown');
      await plugins.trayEvent('onTrayIconMouseDown');

      showing.complete(); // the held show fails now
      await drain(tester);
      restoreErrors(); // so a failing expectation reports itself, not a mask

      expect(
        plugins.calls.where((c) => c == 'window_manager.show').length,
        2,
        reason: 'the queued click still applied the newest show intent',
      );
      expect(
        reported.map((r) => r.context.toString()),
        ['while showing the window', 'while hiding the window'],
        reason:
            'both attempts failed loudly; the second reports under the label '
            'of its own click, because the action applies the newest intent',
      );
      expect(
        plugins.calls.where((c) => c == 'window_manager.hide').length,
        1,
        reason: 'only the startup hide: the toggles ended on show',
      );
    });

    testWidgets('a tray that fails to disappear still lets the window go', (
      tester,
    ) async {
      await pumpApp(tester);
      plugins.failing.add('tray_manager.destroy');

      await plugins.clickMenuItem('quit');
      await drain(tester);

      expect(plugins.calls, contains('tray_manager.destroy'));
      expect(plugins.calls.last, 'window_manager.destroy');
      expect(
        reported.single.context.toString(),
        'while destroying the tray icon',
      );
    });

    testWidgets('quit stops the clicks before the queue reaches the tray', (
      tester,
    ) async {
      // The queue is stuck on the very first menu, so quitting cannot reach
      // Tray.destroy: only the synchronous deactivation can stop a click.
      final stuck = plugins.hold('tray_manager.setContextMenu');
      await pumpApp(tester);

      // Delivered in the same turn as the quit click: only the synchronous
      // flag can stop these, the deferred unregistration is already too late.
      final quit = plugins.clickMenuItem('quit');
      final rightClick = plugins.trayEvent('onTrayIconRightMouseDown');
      final leftClick = plugins.trayEvent('onTrayIconMouseDown');
      await Future.wait([quit, rightClick, leftClick]);
      await drain(tester);

      expect(plugins.calls, isNot(contains('tray_manager.popUpContextMenu')));
      expect(plugins.calls, isNot(contains('window_manager.show')));

      stuck.complete();
      await drain(tester);
      expect(plugins.calls.last, 'window_manager.destroy');
      expect(reported, isEmpty);
    });

    testWidgets('an unqueued popup failure is reported, not swallowed', (
      tester,
    ) async {
      await pumpApp(tester);
      plugins.failing.add('tray_manager.popUpContextMenu');

      await plugins.trayEvent('onTrayIconRightMouseDown');
      await drain(tester);

      expect(plugins.calls, contains('tray_manager.popUpContextMenu'));
      expect(reported.single.context.toString(), 'while opening the tray menu');

      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    });

    testWidgets(
      'ordinary disposal releases the tray and survives late clicks',
      (tester) async {
        await pumpApp(tester);
        await tester.pumpWidget(const SizedBox());
        await drain(tester);

        expect(plugins.calls, contains('tray_manager.destroy'));
        // A click that arrives after disposal must not setState or reappear.
        await plugins.trayEvent('onTrayIconMouseDown');
        await plugins.trayEvent('onTrayMenuItemClick', {
          'id': plugins.idOf('mute'),
        });
        await drain(tester);

        expect(plugins.calls, isNot(contains('window_manager.show')));
        expect(reported, isEmpty);
      },
    );

    testWidgets('quitting and then being disposed cleans up exactly once', (
      tester,
    ) async {
      await pumpApp(tester);
      await plugins.clickMenuItem('quit');
      await drain(tester);
      await tester.pumpWidget(const SizedBox());
      await drain(tester);

      expect(
        plugins.calls.where((c) => c == 'tray_manager.destroy').length,
        1,
        reason: 'the icon is removed once, however many owners ask',
      );
      expect(reported, isEmpty, reason: 'no double disposal of the notifier');
    });
  });
}

/// Lets the queued native work and the poller's microtasks run.
Future<void> drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump();
  }
}

/// The native side of both plugins, recorded and optionally broken.
class _Plugins {
  static const _channels = [
    'window_manager',
    'tray_manager',
    // window_manager.center() asks this transitive plugin where the screen is.
    'dev.leanflutter.plugins/screen_retriever',
  ];

  static const _display = {
    'id': 'test',
    'size': {'width': 1920.0, 'height': 1080.0},
    'visiblePosition': {'dx': 0.0, 'dy': 0.0},
    'visibleSize': {'width': 1920.0, 'height': 1080.0},
    'scaleFactor': 1.0,
  };

  /// What the native side answers when a call has a return value.
  static const _answers = {
    'isMinimized': false,
    'getBounds': {'x': 0.0, 'y': 0.0, 'width': 420.0, 'height': 320.0},
    'getPrimaryDisplay': _display,
    'getAllDisplays': {
      'displays': [_display],
    },
    'getCursorScreenPoint': {'dx': 10.0, 'dy': 10.0},
  };

  /// Every call as `channel.method`, in order.
  final calls = <String>[];

  /// Qualified names that must fail, e.g. `tray_manager.destroy`.
  final failing = <String>{};

  /// Qualified names whose call blocks until the test lets it finish.
  final _holds = <String, Completer<void>>{};

  List<Map<Object?, Object?>> _menu = const [];

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in _channels) {
      final channel = MethodChannel(name);
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add('$name.${call.method}');
        if (call.method == 'setContextMenu') {
          final menu = (call.arguments as Map)['menu'] as Map;
          _menu = (menu['items'] as List).cast<Map<Object?, Object?>>();
        }
        await _holds['$name.${call.method}']?.future;
        if (failing.contains('$name.${call.method}')) {
          throw PlatformException(code: 'boom', message: call.method);
        }
        return _answers[call.method];
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    }
  }

  /// Makes calls to [qualified] block until the returned completer is done.
  Completer<void> hold(String qualified) =>
      _holds[qualified] = Completer<void>();

  /// The plugin-assigned id of the menu item with [key].
  int idOf(String key) =>
      _menu.firstWhere((item) => item['key'] == key)['id']! as int;

  /// Delivers a tray event the way the native side does.
  Future<void> trayEvent(String method, [Object? arguments]) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'tray_manager',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, arguments),
            ),
            null,
          );

  Future<void> clickMenuItem(String key) =>
      trayEvent('onTrayMenuItemClick', {'id': idOf(key)});
}
