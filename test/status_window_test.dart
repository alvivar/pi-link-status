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
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    final statusNotifier = ValueNotifier<LinkStatus>(status);
    final idleNotifier = ValueNotifier<DateTime?>(lastAllIdle);
    addTearDown(statusNotifier.dispose);
    addTearDown(idleNotifier.dispose);
    final taps = <void>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Builder(
          builder: (context) => MediaQuery(
            // Only the text scale is overridden: the view still sees the real
            // 420×320 window it was given.
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: StatusView(
              status: statusNotifier,
              lastAllIdle: idleNotifier,
              muted: muted,
              visible: visible,
              onTap: () => taps.add(null),
              clock: clock ?? () => at,
            ),
          ),
        ),
      ),
    );
    return (status: statusNotifier, lastAllIdle: idleNotifier, taps: taps);
  }

  /// The row names on screen, top to bottom, each with its hub marker if it
  /// carries one. Only the names contain '@': the title, the paths, the
  /// statuses and the footer never reach this list.
  List<String> rows(WidgetTester tester) => tester
      .widgetList<RichText>(find.byType(RichText))
      .map((name) => name.text.toPlainText())
      .where((name) => name.contains('@'))
      .toList();

  group('header', () {
    testWidgets('states the scope, the hub and the historical time', (
      tester,
    ) async {
      await pumpView(
        tester,
        status: online([terminal('opus@pi-link')]),
        lastAllIdle: DateTime(2024, 5, 6, 9, 7),
      );

      expect(find.text('Entire pi-link network · 1 online'), findsOneWidget);
      // The hub keeps its identity on its own row, not in the scope line.
      expect(
        find.textContaining('opus@pi-link  hub', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('Last all idle: 09:07'), findsOneWidget);
      expect(find.text('Click to hide'), findsOneWidget);
    });

    testWidgets('shows a dash when it never happened', (tester) async {
      await pumpView(tester, status: const NoHub());

      expect(find.text('Last all idle: —'), findsOneWidget);
    });

    testWidgets('announces the muted alerts only while muted', (tester) async {
      await pumpView(
        tester,
        status: online([terminal('opus@pi-link')]),
        muted: true,
      );
      expect(find.text('Alerts muted'), findsOneWidget);

      await pumpView(tester, status: online([terminal('opus@pi-link')]));
      expect(find.text('Alerts muted'), findsNothing);
    });

    testWidgets('all idle is a current state, not a memory', (tester) async {
      final view = await pumpView(
        tester,
        status: online([terminal('opus@pi-link')]),
        lastAllIdle: DateTime(2024, 5, 6, 9, 7),
      );
      expect(find.text('All agents are idle'), findsOneWidget);

      // Work resumes while the window is open: the claim goes, the history
      // stays.
      view.status.value = online([
        terminal('opus@pi-link', status: 'thinking', since: 2),
      ]);
      await tester.pump();

      expect(find.text('All agents are idle'), findsNothing);
      expect(find.text('1 working'), findsOneWidget);
      expect(find.text('thinking 2s'), findsOneWidget);
      expect(find.text('Last all idle: 09:07'), findsOneWidget);
    });

    testWidgets('the title counts every category exactly once', (tester) async {
      await pumpView(
        tester,
        status: online([
          terminal('a@pi-link', status: 'compacting', since: 8),
          terminal('b@pi-link', status: 'tool:read', since: 4),
          terminal('c@pi-link', status: 'waiting-approval', since: 14),
          terminal('d@pi-link'),
          terminal('e@pi-link'),
        ]),
      );

      expect(
        find.text('1 working · 1 compacting · 1 unknown · 2 idle'),
        findsOneWidget,
      );
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

      expect(
        find.textContaining('opus@pi-link', findRichText: true),
        findsOneWidget,
      );
      expect(find.text('tool:link_send 12s'), findsOneWidget);
      expect(find.text('92K/272K (34%)'), findsOneWidget);
      expect(find.text('C:/code/pi_link_status'), findsOneWidget);
    });

    testWidgets(
      'an unrecognised status keeps its age; an absent one has none',
      (tester) async {
        await pumpView(
          tester,
          status: online([
            terminal('a@pi-link', status: 'waiting-approval', since: 14),
            terminal('b@pi-link', status: null),
          ]),
        );

        // status and sinceSeconds arrive together: a word this version does not
        // know is still a word with an age behind it.
        expect(find.text('waiting-approval 14s'), findsOneWidget);
        expect(find.text('?'), findsOneWidget);
      },
    );

    testWidgets('marks the hub, and only the hub', (tester) async {
      await pumpView(
        tester,
        status: online([terminal('fable@pi-link'), terminal('sol@pi-link')]),
      );

      expect(
        find.textContaining('fable@pi-link  hub', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('sol@pi-link  hub', findRichText: true),
        findsNothing,
      );
      expect(
        find.textContaining('sol@pi-link', findRichText: true),
        findsOneWidget,
        reason: 'the client keeps its full identity, just no marker',
      );
    });

    testWidgets('a doubled text scale keeps every text', (tester) async {
      await pumpView(
        tester,
        status: online([
          terminal('opus@pi-link', status: 'tool:link_send', since: 12),
        ]),
        lastAllIdle: DateTime(2024, 5, 6, 9, 7),
        muted: true,
        textScaler: const TextScaler.linear(2.0),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('1 working'), findsOneWidget);
      expect(find.text('tool:link_send 12s'), findsOneWidget);
      expect(find.text('92K/272K (34%)'), findsOneWidget);
      expect(find.text('Alerts muted'), findsOneWidget);
      expect(find.text('Last all idle: 09:07'), findsOneWidget);
      expect(find.text('Click to hide'), findsOneWidget);
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
      // Header and footer keep their place while the list scrolls, under a
      // scrollbar that says there is more.
      expect(find.text('Entire pi-link network · 10 online'), findsOneWidget);
      expect(find.text('Click to hide'), findsOneWidget);
      expect(find.byType(RawScrollbar), findsOneWidget);
      expect(
        find.textContaining(
          'very-long-terminal-name-number-9@',
          findRichText: true,
        ),
        findsNothing,
      );

      await tester.drag(find.byType(ListView), const Offset(0, -2000));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(
        find.textContaining(
          'very-long-terminal-name-number-9@',
          findRichText: true,
        ),
        findsOneWidget,
      );
      expect(find.text('Click to hide'), findsOneWidget);
    });
  });

  group('ordering', () {
    testWidgets('activity ranks the rows, and no age can overrule it', (
      tester,
    ) async {
      await pumpView(
        tester,
        status: online([
          // Deliberately scrambled, and the hub is the idle one.
          terminal('hub@x', since: 5),
          terminal('old-worker@x', status: 'thinking', since: 3600),
          terminal('fresh-unknown@x', status: 'waiting-approval', since: 1),
          terminal('compactor@x', status: 'compacting', since: 900),
          terminal('tool-user@x', status: 'tool:read', since: 7),
        ]),
      );

      expect(rows(tester), [
        // Working first, even the one that started an hour ago; then
        // compacting; then idle; and last the word this version cannot read,
        // however recent it is.
        'tool-user@x',
        'old-worker@x',
        'compactor@x',
        'hub@x  hub',
        'fresh-unknown@x',
      ]);
    });

    testWidgets('inside a rank, the most recent state change comes first', (
      tester,
    ) async {
      await pumpView(
        tester,
        status: online([
          terminal('long-idle@x', since: 300),
          terminal('just-idle@x', since: 5),
          terminal('a-while@x', since: 60),
          terminal('also-just-idle@x', since: 5),
        ]),
      );

      expect(rows(tester), [
        // Recently idle before long idle, and the two that tie stay in the
        // order the hub sent them.
        'just-idle@x',
        'also-just-idle@x',
        'a-while@x',
        'long-idle@x  hub',
      ]);
    });

    testWidgets('ages are compared as numbers, not as the text on screen', (
      tester,
    ) async {
      await pumpView(
        tester,
        status: online([
          terminal('an-hour@x', since: 3600),
          terminal('a-minute@x', since: 59),
        ]),
      );

      // On screen these read '1h' and '59s': sorted as text the hour would
      // come first.
      expect(find.text('idle 1h'), findsOneWidget);
      expect(find.text('idle 59s'), findsOneWidget);
      expect(rows(tester), ['a-minute@x', 'an-hour@x  hub']);
    });

    testWidgets('an unknown row with an age precedes one without', (
      tester,
    ) async {
      await pumpView(
        tester,
        status: online([
          terminal('hub@x', status: null),
          terminal('known-age@x', status: 'waiting-approval', since: 30),
          terminal('no-age@x', status: null),
        ]),
      );

      // A missing age is not a fresh one: it sorts last, and the two rows that
      // have none keep the roster's order between them.
      expect(rows(tester), ['known-age@x', 'hub@x  hub', 'no-age@x']);
    });

    testWidgets('the roster the rest of the app reads is left alone', (
      tester,
    ) async {
      final roster = [
        terminal('hub@x', since: 5),
        terminal('worker@x', status: 'thinking', since: 4),
      ];
      final asSent = List<Terminal>.of(roster);
      final status = online(roster);

      await pumpView(tester, status: status);

      // Same objects, same positions: sorting in place would have swapped
      // them here, and the poller, the alert and the tray read this list.
      expect(roster, orderedEquals(asSent));
      expect(identical(status.terminals.first, asSent.first), isTrue);
      expect(status.hub, 'hub@x', reason: 'the payload still names its hub');
      expect(rows(tester), [
        'worker@x',
        'hub@x  hub',
      ], reason: 'the display did reorder, so the checks above mean something');
    });

    testWidgets('a new snapshot re-sorts and moves the marker', (tester) async {
      final view = await pumpView(
        tester,
        status: online([
          terminal('first-hub@x', since: 5),
          terminal('worker@x', status: 'thinking', since: 4),
        ]),
      );

      expect(rows(tester), ['worker@x', 'first-hub@x  hub']);

      // The hub changed, the worker went idle, and a newcomer is working.
      view.status.value = online([
        terminal('second-hub@x', status: 'tool:read', since: 12),
        terminal('worker@x', since: 2),
        terminal('newcomer@x', status: 'thinking', since: 1),
      ]);
      await tester.pump();

      expect(rows(tester), [
        'newcomer@x',
        'second-hub@x  hub',
        'worker@x',
      ], reason: 'order and marker come from the new snapshot, not the old');
    });
  });

  group('hiding', () {
    testWidgets('a click anywhere hides, a drag does not', (tester) async {
      final view = await pumpView(
        tester,
        status: online(List.generate(10, (i) => terminal('terminal-$i@pi'))),
      );

      expect(
        find.textContaining('terminal-9@pi', findRichText: true),
        findsNothing,
      );

      // A wheel scroll over the list: it moves, and it is not a click.
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(200, 200),
          scrollDelta: Offset(0, 600),
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('terminal-9@pi', findRichText: true),
        findsOneWidget,
        reason: 'scrolled',
      );
      expect(view.taps, isEmpty, reason: 'scrolling is not a click');

      // A drag over the list.
      await tester.drag(find.byType(ListView), const Offset(0, -120));
      await tester.pump();
      expect(view.taps, isEmpty, reason: 'dragging is not a click');

      // A click on the list, on the header, and on empty padding where no
      // child can answer: all three hide.
      await tester.tap(find.byType(ListView));
      await tester.tap(find.text('Entire pi-link network · 10 online'));
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
      expect(find.text('idle 10s'), findsOneWidget);

      now = at.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('idle 11s'), findsOneWidget);

      now = at.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('idle 12s'), findsOneWidget);
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
      expect(find.text('idle 10s'), findsOneWidget);

      await pumpVisible(true);
      expect(find.text('idle 40s'), findsOneWidget, reason: 'caught up');

      // Hiding again stops the tick, and the widget going away cancels it.
      await pumpVisible(false);
      now = at.add(const Duration(seconds: 90));
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('idle 40s'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('offline states', () {
    testWidgets('NoHub explains the promotion delay', (tester) async {
      await pumpView(tester, status: const NoHub());

      expect(find.text('No hub on :9900'), findsOneWidget, reason: 'title');
      expect(
        find.text('Entire pi-link network · disconnected'),
        findsOneWidget,
      );
      expect(find.textContaining('a client promotes itself'), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
      // The history and the way out stay put in every state.
      expect(find.text('Last all idle: —'), findsOneWidget);
      expect(find.text('Click to hide'), findsOneWidget);
    });

    testWidgets('Unsupported asks for an upgrade', (tester) async {
      await pumpView(
        tester,
        status: const Unsupported(),
        lastAllIdle: DateTime(2024, 5, 6, 9, 7),
      );

      expect(find.text('Outdated hub · update pi-link'), findsOneWidget);
      expect(find.text('Entire pi-link network · no /status'), findsOneWidget);
      expect(
        find.textContaining('update pi-link and restart the terminals'),
        findsOneWidget,
      );
      expect(find.text('Last all idle: 09:07'), findsOneWidget);
    });
  });

  group('tray tooltip', () {
    test('says there is no hub, and that an old hub needs upgrading', () {
      expect(tooltipFor(const NoHub()), 'pi-link · no hub');
      expect(
        tooltipFor(const Unsupported()),
        'pi-link · outdated hub (update pi-link)',
      );
    });

    test('an idle fleet is called idle', () {
      expect(
        tooltipFor(online([terminal('opus@pi-link'), terminal('sol@pi-link')])),
        'pi-link · 2 online · all idle',
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
        'pi-link · 4 online · 3 working',
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
        'pi-link · 4 online · 1 working · 2 unknown',
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

        expect(tooltip, 'pi-link · 10 online · 5 working');
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

    setUp(() {
      plugins = _Plugins()..install();
      reported = <FlutterErrorDetails>[];
    });

    /// Collects the errors the app reports while [operations] run, and hands
    /// the framework's own reporter back before returning.
    ///
    /// Only the native failures a test provokes are evidence; everything else
    /// belongs to flutter_test. The handover matters: while this handler is
    /// installed, a failed `expect` is collected instead of raised and comes
    /// back as the binding's `_pendingExceptionDetails != null` assertion,
    /// which hides the real mismatch and leaves every later test in the file
    /// reporting that it did not complete. So the capture wraps the calls that
    /// are expected to fail, never the expectations about them.
    Future<void> capturing(Future<void> Function() operations) async {
      final reporter = FlutterError.onError;
      FlutterError.onError = reported.add;
      // Fallback: the restore below covers a throwing operation, this covers
      // an escape the try cannot see, such as a failure inside the restore.
      addTearDown(() => FlutterError.onError = reporter);
      try {
        await operations();
      } finally {
        FlutterError.onError = reporter;
      }
    }

    /// Starts the app with a poller that never reaches the network. Startup is
    /// not expected to fail, so it reports to flutter_test like any other test
    /// code: an error here should be a red test, not collected evidence.
    Future<void> pumpApp(WidgetTester tester) async {
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

      await capturing(() async {
        await plugins.trayEvent('onTrayIconMouseDown');
        await drain(tester);
      });
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

      await capturing(() async {
        final showing = plugins.hold('window_manager.show');
        await plugins.trayEvent('onTrayIconMouseDown'); // show, held mid-call
        await drain(tester);
        // Two clicks while that show is stuck: hide, then show again. The
        // newest intent is the same boolean the stuck call is applying, so
        // reconciling it away would silently drop the user's latest decision.
        await plugins.trayEvent('onTrayIconMouseDown');
        await plugins.trayEvent('onTrayIconMouseDown');

        showing.complete(); // the held show fails now
        await drain(tester);
      });

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

      await capturing(() async {
        await plugins.clickMenuItem('quit');
        await drain(tester);
      });

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

      await capturing(() async {
        // Delivered in the same turn as the quit click: only the synchronous
        // flag can stop these, the deferred unregistration is already too
        // late.
        final quit = plugins.clickMenuItem('quit');
        final rightClick = plugins.trayEvent('onTrayIconRightMouseDown');
        final leftClick = plugins.trayEvent('onTrayIconMouseDown');
        await Future.wait([quit, rightClick, leftClick]);
        await drain(tester);
      });

      expect(plugins.calls, isNot(contains('tray_manager.popUpContextMenu')));
      expect(plugins.calls, isNot(contains('window_manager.show')));

      await capturing(() async {
        stuck.complete();
        await drain(tester);
      });
      expect(plugins.calls.last, 'window_manager.destroy');
      expect(reported, isEmpty);
    });

    testWidgets('an unqueued popup failure is reported, not swallowed', (
      tester,
    ) async {
      await pumpApp(tester);
      plugins.failing.add('tray_manager.popUpContextMenu');

      await capturing(() async {
        await plugins.trayEvent('onTrayIconRightMouseDown');
        await drain(tester);
      });

      expect(plugins.calls, contains('tray_manager.popUpContextMenu'));
      expect(reported.single.context.toString(), 'while opening the tray menu');

      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    });

    testWidgets(
      'ordinary disposal releases the tray and survives late clicks',
      (tester) async {
        await pumpApp(tester);
        await capturing(() async {
          await tester.pumpWidget(const SizedBox());
          await drain(tester);
        });

        expect(plugins.calls, contains('tray_manager.destroy'));
        await capturing(() async {
          // A click after disposal must not setState or reappear.
          await plugins.trayEvent('onTrayIconMouseDown');
          await plugins.trayEvent('onTrayMenuItemClick', {
            'id': plugins.idOf('mute'),
          });
          await drain(tester);
        });

        expect(plugins.calls, isNot(contains('window_manager.show')));
        expect(reported, isEmpty);
      },
    );

    testWidgets('quitting and then being disposed cleans up exactly once', (
      tester,
    ) async {
      await pumpApp(tester);
      await capturing(() async {
        await plugins.clickMenuItem('quit');
        await drain(tester);
        await tester.pumpWidget(const SizedBox());
        await drain(tester);
      });

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
