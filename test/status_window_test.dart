import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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
    ///
    /// [poller] replaces it when the test needs to feed samples instead.
    Future<void> pumpApp(WidgetTester tester, {Poller? poller}) async {
      await tester.pumpWidget(
        App(
          poller:
              poller ??
              Poller(
                openRequest: (client, uri) =>
                    Future.error(const SocketException('no hub in tests')),
              ),
        ),
      );
      await drain(tester);
    }

    /// One snapshot of a fleet of two, where [lead] decides the fleet state.
    ///
    /// The roster never changes: a departure or an arrival would reset the
    /// confirmation streak, which is a different rule than the one under test.
    /// [mark] rides along in the paths, so every sample is identifiable on
    /// screen — that is how these tests show a sample reached the app rather
    /// than assuming the fixture and the owner are wired together.
    Online sample(String lead, String mark) => online([
      terminal('opus@pi', status: lead, cwd: 'C:/code/$mark'),
      terminal('sol@pi', cwd: 'C:/code/$mark'),
    ], receivedAt: DateTime.now());

    /// The history line the window is showing, e.g. `Last all idle: 09:07`.
    String history(WidgetTester tester) =>
        tester.widget<Text>(find.textContaining('Last all idle: ')).data!;

    /// The history line [at] would produce. The app reads the real clock, so
    /// the tests bracket the confirming sample instead of pinning the minute.
    String historyAt(DateTime at) =>
        'Last all idle: ${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';

    /// The instant the owner published, as the window received it. The line on
    /// screen is only accurate to the minute, which is too coarse to tell a
    /// preserved time from one silently rewritten by the next idle sample.
    DateTime? recorded(WidgetTester tester) =>
        tester.widget<StatusView>(find.byType(StatusView)).lastAllIdle.value;

    /// Checks a confirmation against the bracket around the sample that caused
    /// it, and against the line the window is showing, and returns it so a
    /// later step can prove it did not move.
    DateTime confirmation(
      WidgetTester tester, {
      required DateTime before,
      required DateTime after,
    }) {
      final at = recorded(tester);
      expect(at, isNotNull, reason: 'the confirmation recorded a time');
      expect(
        at!.isBefore(before) || at.isAfter(after),
        isFalse,
        reason: 'the app recorded when it observed the confirming sample',
      );
      expect(
        history(tester),
        historyAt(at),
        reason: 'and the window is showing that very value',
      );
      return at;
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

    testWidgets('a tray icon the shell refuses still gets its menu', (
      tester,
    ) async {
      // The native plugin reports a refused registration as an error. Without
      // the icon there is no way to reach the app, so the menu it carries —
      // and its 'Quit' — must be configured anyway: the plugin retries the
      // registration on its own, with no further help from Dart.
      plugins.failing.add('tray_manager.setIcon');
      await capturing(() async {
        await pumpApp(tester);
      });

      expect(
        plugins.calls,
        containsAllInOrder([
          'tray_manager.setContextMenu',
          'tray_manager.setIcon',
        ]),
        reason: 'the menu is configured before the icon can fail',
      );
      expect(
        reported.single.exception,
        isA<PlatformException>(),
        reason: 'and the failure is reported, not swallowed',
      );

      // The same desired state must be attempted again: a failed call was not
      // remembered as applied.
      plugins.calls.clear();
      await capturing(() async {
        await plugins.clickMenuItem('mute');
        await drain(tester);
      });
      expect(
        plugins.calls,
        contains('tray_manager.setIcon'),
        reason: 'the unchanged offline icon is retried, not skipped',
      );

      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    });

    testWidgets('quitting dispatches the recovery stop before the queue drains', (
      tester,
    ) async {
      await pumpApp(tester);
      // A tray call the app is already inside when the user quits. The queued
      // destroy cannot run until this finishes, which is exactly the window in
      // which the native retry timer would keep re-adding the icon.
      final held = plugins.hold('tray_manager.setContextMenu');
      unawaited(plugins.clickMenuItem('mute'));
      await drain(tester);
      plugins.calls.clear();

      await plugins.clickMenuItem('quit');
      await drain(tester);
      expect(
        plugins.calls,
        contains('tray_manager.deactivateRecovery'),
        reason:
            'the stop is dispatched when the app decides to quit; whether the '
            'native timer has already been cancelled is not observable here',
      );
      expect(
        plugins.calls,
        isNot(contains('tray_manager.destroy')),
        reason: 'while the held call still owns the queue',
      );

      held.complete();
      await drain(tester);
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
      expect(
        plugins.calls.where((c) => c == 'tray_manager.destroy').length,
        1,
        reason: 'and the eventual cleanup still removes the icon exactly once',
      );
    });

    testWidgets('work then a confirmed idle opens the window exactly once', (
      tester,
    ) async {
      final poller = _Samples();
      await pumpApp(tester, poller: poller);
      expect(find.text('Last all idle: —'), findsOneWidget);

      poller.emit(sample('thinking', 'working'));
      await drain(tester);
      expect(
        find.text('C:/code/working'),
        findsNWidgets(2),
        reason: 'the sample reached the window through the app',
      );
      expect(plugins.calls, isNot(contains('window_manager.show')));
      expect(find.text('Last all idle: —'), findsOneWidget);

      poller.emit(sample('idle', 'first-idle'));
      await drain(tester);
      expect(find.text('C:/code/first-idle'), findsNWidgets(2));
      expect(
        plugins.calls,
        isNot(contains('window_manager.show')),
        reason: 'one idle sample is not a confirmation',
      );
      expect(
        find.text('Last all idle: —'),
        findsOneWidget,
        reason: 'and nothing is recorded before the confirmation either',
      );

      // The bracket closes on the synchronous emit, before the pumps, so the
      // app observes the sample inside it.
      final before = DateTime.now();
      poller.emit(sample('idle', 'confirmed'));
      final after = DateTime.now();
      await drain(tester);

      expect(
        plugins.calls.where((c) => c == 'window_manager.show').length,
        1,
        reason: 'the confirmed alert opened the window, once',
      );
      final confirmed = confirmation(tester, before: before, after: after);

      // Sustained idle: the fleet stays exactly as it was.
      final quiet = List.of(plugins.calls);
      poller.emit(sample('idle', 'still-idle'));
      await drain(tester);
      expect(
        find.text('C:/code/still-idle'),
        findsNWidgets(2),
        reason: 'this sample arrived, before the next one replaces it',
      );
      poller.emit(sample('idle', 'idle-again'));
      await drain(tester);
      expect(find.text('C:/code/idle-again'), findsNWidgets(2));

      expect(
        plugins.calls,
        quiet,
        reason:
            'staying idle asks the native side for nothing: no second '
            'show, and the tray skips a state it already applied',
      );
      expect(
        recorded(tester),
        confirmed,
        reason:
            'the historical time does not drift: the same instant, not '
            'merely the same minute on screen',
      );
      expect(history(tester), historyAt(confirmed));

      await tester.pumpWidget(const SizedBox());
      await drain(tester);
      expect(plugins.calls, contains('tray_manager.destroy'));
      // The app disposed the poller it was given, so the fixture refuses to
      // publish anything else. Disposal was the owner's decision, not ours.
      expect(
        () => poller.emit(sample('idle', 'after-disposal')),
        throwsStateError,
        reason: 'the app released the poller it was constructed with',
      );
    });

    testWidgets('muted, the confirmation is recorded but never opens', (
      tester,
    ) async {
      final poller = _Samples();
      await pumpApp(tester, poller: poller);
      await plugins.clickMenuItem('mute');
      await drain(tester);

      poller.emit(sample('thinking', 'muted-working'));
      await drain(tester);
      expect(
        find.text('C:/code/muted-working'),
        findsNWidgets(2),
        reason: 'the work that arms the cycle really was observed',
      );
      poller.emit(sample('idle', 'muted-first-idle'));
      await drain(tester);
      expect(find.text('C:/code/muted-first-idle'), findsNWidgets(2));
      expect(
        find.text('Last all idle: —'),
        findsOneWidget,
        reason: 'still one idle sample short of a confirmation',
      );

      final before = DateTime.now();
      poller.emit(sample('idle', 'muted-confirmed'));
      final after = DateTime.now();
      await drain(tester);

      expect(
        plugins.calls,
        isNot(contains('window_manager.show')),
        reason: 'muting suppresses the announcement itself',
      );
      final muted = confirmation(tester, before: before, after: after);

      // Unmuting is a real menu click, not an assignment to a field.
      await plugins.clickMenuItem('mute');
      await drain(tester);
      poller.emit(sample('idle', 'unmuted-idle'));
      await drain(tester);

      expect(find.text('C:/code/unmuted-idle'), findsNWidgets(2));
      expect(
        plugins.calls,
        isNot(contains('window_manager.show')),
        reason: 'the alert was consumed while muted: unmuting cannot replay it',
      );
      expect(
        recorded(tester),
        muted,
        reason: 'and no confirmation happened again to move the instant',
      );
      expect(history(tester), historyAt(muted));

      // Unarmed is not broken: work after unmuting starts a fresh cycle.
      poller.emit(sample('thinking', 'second-working'));
      await drain(tester);
      poller.emit(sample('idle', 'second-first-idle'));
      await drain(tester);
      final reBefore = DateTime.now();
      poller.emit(sample('idle', 'second-confirmed'));
      final reAfter = DateTime.now();
      await drain(tester);

      expect(
        plugins.calls.where((c) => c == 'window_manager.show').length,
        1,
        reason: 'the first alert this app ever shows is this one',
      );
      confirmation(tester, before: reBefore, after: reAfter);

      await tester.pumpWidget(const SizedBox());
      await drain(tester);
      expect(plugins.calls, contains('tray_manager.destroy'));
    });
  });
}

/// A poller that never polls: [App]'s own seam, driven by the test.
///
/// It replaces the loop, not the wiring — the app still adds its listener to
/// [status], reads `status.value` wherever it needs the newest snapshot, and
/// disposes this object exactly as it disposes a real one.
class _Samples extends Poller {
  _Samples()
    : super(
        openRequest: (client, uri) =>
            Future.error(const SocketException('the fixture never connects')),
      );

  final _samples = ValueNotifier<LinkStatus>(const NoHub());
  bool _disposed = false;

  @override
  ValueListenable<LinkStatus> get status => _samples;

  /// No loop, no timer, no socket: samples arrive only from [emit].
  @override
  void start() {}

  /// Publishes one snapshot, exactly as a settled poll would.
  void emit(LinkStatus status) {
    if (_disposed) {
      throw StateError('the fixture cannot emit after the app disposed it');
    }
    _samples.value = status;
  }

  @override
  void dispose() {
    _disposed = true;
    // Releases the base notifier the app never sees, and everything else the
    // real poller owns; deferred like the real one, because disposal can
    // arrive from inside a notification.
    super.dispose();
    scheduleMicrotask(_samples.dispose);
  }
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
