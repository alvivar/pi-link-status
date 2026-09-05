import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pi_link_status/link_status.dart';
import 'package:pi_link_status/poller.dart';

/// A payload the real hub could send: hub first, roles by position, one working
/// terminal, and both shapes of `context`.
const validBody =
    '{"hub":"opus@pi-link","port":9900,"terminals":['
    '{"name":"opus@pi-link","role":"hub","status":"idle","sinceSeconds":420,'
    '"cwd":"C:/AERO/me","context":{"tokens":92000,"window":272000}},'
    '{"name":"sol@proj","role":"client","status":"thinking","sinceSeconds":12,'
    '"context":null}]}';

/// Deadline used everywhere: long enough to be reliable on a loaded machine,
/// short enough to keep the suite quick.
const deadline = Duration(milliseconds: 250);

/// An interval no test is expected to reach, for single-poll scenarios.
const once = Duration(seconds: 30);

String httpResponse(String body, {int status = 200, int? contentLength}) =>
    'HTTP/1.1 $status OK\r\n'
    'content-type: application/json\r\n'
    'content-length: ${contentLength ?? body.length}\r\n'
    '\r\n$body';

/// An `HttpServer` that always answers the same way, recording what it saw.
class Fixture {
  Fixture._(this._server);

  final HttpServer _server;

  /// One entry per request served, holding the client's source port: equal
  /// ports mean the same connection was reused.
  final requests = <int>[];

  static Future<Fixture> serve(
    String body, {
    int status = 200,
    Duration delay = Duration.zero,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = Fixture._(server);
    server.listen((request) async {
      fixture.requests.add(request.connectionInfo!.remotePort);
      await request.drain<void>();
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      request.response.statusCode = status;
      request.response.write(body);
      await request.response.close();
    });
    return fixture;
  }

  Uri get uri =>
      Uri.parse('http://${_server.address.address}:${_server.port}/status');

  Future<void> close() => _server.close(force: true);
}

/// A raw TCP fixture, for responses no `HttpServer` would produce: silence,
/// truncated bodies, headers and body split in time. It also observes when the
/// client drops a connection, which is how the tests see cancellation happen.
class RawFixture {
  RawFixture._(this._server);

  final ServerSocket _server;
  final _sockets = <Socket>[];
  final _timers = <Timer>[];

  int accepted = 0;
  int closed = 0;
  int live = 0;
  int maxLive = 0;

  /// [script] runs once per accepted connection, with the connection index.
  static Future<RawFixture> start(
    void Function(RawFixture fixture, Socket socket, int index) script,
  ) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final fixture = RawFixture._(server);
    server.listen((socket) {
      final index = fixture.accepted++;
      fixture._sockets.add(socket);
      fixture.live++;
      fixture.maxLive = fixture.maxLive > fixture.live
          ? fixture.maxLive
          : fixture.live;
      void gone() {
        if (fixture._sockets.remove(socket)) {
          fixture.closed++;
          fixture.live--;
          socket.destroy();
        }
      }

      socket.listen((_) {}, onDone: gone, onError: (_) => gone());
      script(fixture, socket, index);
    });
    return fixture;
  }

  Uri get uri =>
      Uri.parse('http://${_server.address.address}:${_server.port}/status');

  /// Sends [data] after [delay], ignoring a connection the client already cut.
  void writeLater(Socket socket, Duration delay, String data) {
    _timers.add(
      Timer(delay, () {
        try {
          socket.write(data);
        } on Object catch (_) {
          // The client cancelled: nothing left to write to.
        }
      }),
    );
  }

  Future<void> close() async {
    for (final timer in _timers) {
      timer.cancel();
    }
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    await _server.close();
  }
}

/// Runs [poller] for [window] and returns what it published, then disposes it.
Future<LinkStatus> settle(
  Poller poller, {
  Duration window = const Duration(milliseconds: 450),
}) async {
  poller.start();
  await Future<void>.delayed(window);
  final published = poller.status.value;
  poller.dispose();
  return published;
}

/// Waits until [test] holds, or gives up after [within].
Future<void> until(
  bool Function() test, {
  Duration within = const Duration(seconds: 3),
}) async {
  final deadline = DateTime.now().add(within);
  while (!test() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('starts offline before any attempt', () {
    final poller = Poller();
    addTearDown(poller.dispose);
    expect(poller.status.value, isA<NoHub>());
    expect(poller.uri, Uri.parse('http://127.0.0.1:9900/status'));
  });

  group('completed responses', () {
    test('a valid payload becomes Online', () async {
      final fixture = await Fixture.serve(validBody);
      addTearDown(fixture.close);
      final before = DateTime.now();

      final status = await settle(
        Poller(uri: fixture.uri, interval: once, deadline: deadline),
      );

      expect(status, isA<Online>());
      final online = status as Online;
      expect(online.hub, 'opus@pi-link');
      expect(online.terminals, hasLength(2));
      expect(online.fleet, FleetState.busy);
      expect(
        online.receivedAt.isBefore(before),
        isFalse,
        reason: 'receivedAt is stamped when the response completes',
      );
    });

    for (final entry in {
      'malformed JSON': '{"hub": ',
      'an HTML error page': '<html><body>nope</body></html>',
      'a valid JSON of the wrong shape': '{"hub": 7, "terminals": []}',
    }.entries) {
      test('${entry.key} becomes Unsupported', () async {
        final fixture = await Fixture.serve(entry.value);
        addTearDown(fixture.close);

        final status = await settle(
          Poller(uri: fixture.uri, interval: once, deadline: deadline),
        );

        expect(status, isA<Unsupported>());
      });
    }

    test('a completed 426 becomes Unsupported, body drained', () async {
      final fixture = await Fixture.serve('upgrade required', status: 426);
      addTearDown(fixture.close);

      final status = await settle(
        Poller(uri: fixture.uri, interval: once, deadline: deadline),
      );

      expect(status, isA<Unsupported>());
      expect(fixture.requests, hasLength(1));
    });
  });

  group('transport failures', () {
    test('a port with no listener stays NoHub', () async {
      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final uri = Uri.parse('http://127.0.0.1:${closed.port}/status');
      await closed.close();

      final started = DateTime.now();
      final status = await settle(
        Poller(uri: uri, interval: once, deadline: deadline),
        window: const Duration(milliseconds: 200),
      );

      expect(status, isA<NoHub>());
      expect(
        DateTime.now().difference(started),
        lessThan(deadline),
        reason: 'refusal is immediate, it does not burn the budget',
      );
    });

    test('a listener that never answers times out to NoHub', () async {
      final fixture = await RawFixture.start(
        (_, _, _) {},
      ); // accept, say nothing
      addTearDown(fixture.close);

      final poller = Poller(
        uri: fixture.uri,
        interval: once,
        deadline: deadline,
      );
      addTearDown(poller.dispose);

      poller.start();
      // Asserted while the poller is still alive: the expiring budget must drop
      // the socket, not the later disposal.
      await until(() => fixture.closed == 1);

      expect(
        fixture.closed,
        1,
        reason: 'the cancelled attempt released its socket',
      );
      expect(fixture.accepted, 1);
      expect(poller.status.value, isA<NoHub>());
    });

    for (final status in [200, 503]) {
      test('a $status body that never ends times out to NoHub', () async {
        final fixture = await RawFixture.start((fixture, socket, _) {
          // Headers promise 500 bytes; only a fragment ever arrives.
          socket.write(
            httpResponse('{"hub"', status: status, contentLength: 500),
          );
        });
        addTearDown(fixture.close);

        final poller = Poller(
          uri: fixture.uri,
          interval: once,
          deadline: deadline,
        );
        addTearDown(poller.dispose);

        poller.start();
        await until(() => fixture.closed == 1); // before any disposal

        expect(fixture.closed, 1, reason: 'the body read was cancelled');
        expect(
          poller.status.value,
          isA<NoHub>(),
          reason: 'not Unsupported: nothing completed',
        );
      });
    }

    test('slow headers and slow body share one budget', () async {
      // Each phase alone fits in the budget; together they do not.
      final phase = Duration(milliseconds: deadline.inMilliseconds * 3 ~/ 4);
      final fixture = await RawFixture.start((fixture, socket, _) {
        fixture.writeLater(
          socket,
          phase,
          'HTTP/1.1 200 OK\r\ncontent-length: ${validBody.length}\r\n\r\n',
        );
        fixture.writeLater(socket, phase * 2, validBody);
      });
      addTearDown(fixture.close);

      final status = await settle(
        Poller(uri: fixture.uri, interval: once, deadline: deadline),
      );

      expect(
        status,
        isA<NoHub>(),
        reason: 'per-phase deadlines would have let this through',
      );
    });

    test('a response inside the shared budget still succeeds', () async {
      final phase = Duration(milliseconds: deadline.inMilliseconds ~/ 4);
      final fixture = await RawFixture.start((fixture, socket, _) {
        fixture.writeLater(
          socket,
          phase,
          'HTTP/1.1 200 OK\r\ncontent-length: ${validBody.length}\r\n\r\n',
        );
        fixture.writeLater(socket, phase * 2, validBody);
      });
      addTearDown(fixture.close);

      final status = await settle(
        Poller(uri: fixture.uri, interval: once, deadline: deadline),
      );

      expect(status, isA<Online>());
    });
  });

  group('serialization and recovery', () {
    test(
      'a timeout is followed by a successful poll, nothing overlaps',
      () async {
        final fixture = await RawFixture.start((fixture, socket, index) {
          if (index == 0) return; // the first attempt gets silence
          socket.write(httpResponse(validBody));
        });
        addTearDown(fixture.close);
        final poller = Poller(
          uri: fixture.uri,
          interval: const Duration(milliseconds: 20),
          deadline: deadline,
        );
        addTearDown(poller.dispose);
        final published = <LinkStatus>[];
        poller.status.addListener(() => published.add(poller.status.value));

        poller.start();
        await until(() => poller.status.value is Online);

        expect(poller.status.value, isA<Online>());
        expect(fixture.accepted, greaterThanOrEqualTo(2));
        expect(
          fixture.maxLive,
          1,
          reason: 'the stalled connection was gone before the next one opened',
        );
        expect(
          published.whereType<Online>(),
          hasLength(1),
          reason: 'the late response of the cancelled attempt never published',
        );
      },
    );

    test('successful polls reuse one connection', () async {
      final fixture = await Fixture.serve(validBody);
      addTearDown(fixture.close);
      final poller = Poller(
        uri: fixture.uri,
        interval: const Duration(milliseconds: 20),
        deadline: deadline,
      );
      addTearDown(poller.dispose);

      poller.start();
      await until(() => fixture.requests.length >= 3);
      poller.dispose();

      expect(fixture.requests.length, greaterThanOrEqualTo(3));
      expect(
        fixture.requests.toSet(),
        hasLength(1),
        reason: 'same source port: keep-alive, no client rebuilt per poll',
      );
    });

    test(
      'a late SUCCESSFUL acquisition is aborted as the stale attempt',
      () async {
        // The connection is really established, and only its *delivery* to the
        // poller is withheld, so after the budget expires `_fetch` receives a
        // usable HttpClientRequest belonging to a cancelled attempt: the
        // `isCancelled -> request.abort()` branch, which a gate placed before
        // getUrl can never reach.
        final fixture = await RawFixture.start(
          (_, socket, _) => socket.write(httpResponse(validBody)),
        );
        addTearDown(fixture.close);
        final acquired = Completer<void>();
        final gate = Completer<void>();
        var opened = 0;
        final poller = Poller(
          uri: fixture.uri,
          interval: const Duration(milliseconds: 20),
          deadline: const Duration(milliseconds: 200),
          openRequest: (client, uri) async {
            if (opened++ > 0) return client.getUrl(uri);
            final request = await client.getUrl(uri); // connection established
            acquired.complete();
            await gate.future; // ...delivery withheld until the test says so
            return request;
          },
        );
        addTearDown(poller.dispose);
        final published = <LinkStatus>[];
        poller.status.addListener(() => published.add(poller.status.value));

        poller.start();
        await acquired.future; // the socket exists before the budget can expire
        expect(fixture.accepted, 1);

        // Now let the budget expire while the request is still withheld.
        await Future<void>.delayed(const Duration(milliseconds: 400));

        expect(published, isEmpty);
        expect(
          opened,
          1,
          reason: 'no successor started while the stale attempt was unsettled',
        );
        expect(
          fixture.live,
          0,
          reason: 'cancellation released the acquired socket',
        );
        expect(fixture.closed, 1);

        gate.complete(); // the acquired request is delivered, post-cancellation
        await until(() => published.isNotEmpty);

        expect(published.single, isA<Online>());
        expect(
          fixture.accepted,
          2,
          reason:
              'the aborted request was never sent; only the successor polled',
        );
        expect(
          fixture.maxLive,
          1,
          reason: 'the stale attempt was released before the next connected',
        );
      },
    );

    test('an acquisition failing after cancellation settles too', () async {
      // The other half: cancellation force-closed the client, so an acquisition
      // started later fails instead of returning a request.
      final fixture = await RawFixture.start(
        (_, socket, _) => socket.write(httpResponse(validBody)),
      );
      addTearDown(fixture.close);
      final gate = Completer<void>();
      var opened = 0;
      final poller = Poller(
        uri: fixture.uri,
        interval: const Duration(milliseconds: 20),
        deadline: const Duration(milliseconds: 150),
        openRequest: (client, uri) async {
          if (opened++ == 0) await gate.future; // the first attempt hangs here
          return client.getUrl(uri);
        },
      );
      addTearDown(poller.dispose);
      final published = <LinkStatus>[];
      poller.status.addListener(() => published.add(poller.status.value));

      poller.start();
      // Well past the budget: the first attempt is cancelled but unsettled.
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(published, isEmpty);
      expect(fixture.accepted, 0, reason: 'nothing ever reached the network');
      expect(
        opened,
        1,
        reason: 'no second attempt started while the first was in flight',
      );

      gate.complete(); // the doomed acquisition finally runs, and fails
      await until(() => published.isNotEmpty);

      expect(published.single, isA<Online>());
      expect(
        fixture.maxLive,
        1,
        reason: 'the stale attempt was released before the next connected',
      );
      expect(
        published.whereType<Online>(),
        hasLength(1),
        reason: 'the stale attempt published nothing of its own',
      );
    });

    test('starting twice does not start a second loop', () async {
      final fixture = await Fixture.serve(validBody);
      addTearDown(fixture.close);
      final poller = Poller(
        uri: fixture.uri,
        interval: const Duration(milliseconds: 300),
        deadline: deadline,
      );
      addTearDown(poller.dispose);

      poller.start();
      poller.start();
      poller.start();
      await until(() => fixture.requests.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(fixture.requests, hasLength(1));
    });
  });

  group('error boundary', () {
    test('an unexpected defect surfaces instead of becoming NoHub', () async {
      final fixture = await Fixture.serve(validBody);
      addTearDown(fixture.close);
      final escaped = <Object>[];
      final published = <LinkStatus>[];

      await runZonedGuarded(() async {
        var opened = 0;
        final poller = Poller(
          uri: fixture.uri,
          interval: const Duration(milliseconds: 20),
          deadline: deadline,
          openRequest: (client, uri) async {
            if (opened++ == 1) throw StateError('a defect, not a hub problem');
            return client.getUrl(uri);
          },
        );
        addTearDown(poller.dispose);
        poller.status.addListener(() => published.add(poller.status.value));
        poller.start();
        await until(() => escaped.isNotEmpty);
      }, (error, _) => escaped.add(error));

      expect(escaped.single, isA<StateError>());
      expect(
        published.single,
        isA<Online>(),
        reason: 'the defect was never dressed up as an offline hub',
      );
    });
  });

  group('disposal', () {
    /// Disposes [poller] at [when] and asserts nothing was published after it.
    Future<List<LinkStatus>> disposeDuring(Poller poller, Duration when) async {
      final published = <LinkStatus>[];
      poller.status.addListener(() => published.add(poller.status.value));
      poller.start();
      if (when > Duration.zero) await Future<void>.delayed(when);
      poller.dispose();
      final atDisposal = published.length;
      // Long enough for any survivor to answer, publish or blow up.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(published, hasLength(atDisposal));
      return published;
    }

    test('while an acquisition that already succeeded is delivered', () async {
      // Disposal counterpart of the timeout case: the connection is genuinely
      // established first, disposal happens next, and only then is the request
      // handed to `_fetch`, which must abort it rather than use it.
      final fixture = await RawFixture.start(
        (_, socket, _) => socket.write(httpResponse(validBody)),
      );
      addTearDown(fixture.close);
      final acquired = Completer<void>();
      final gate = Completer<void>();
      final poller = Poller(
        uri: fixture.uri,
        interval: once,
        deadline: const Duration(seconds: 30), // the budget must not interfere
        openRequest: (client, uri) async {
          final request = await client.getUrl(uri);
          acquired.complete();
          await gate.future;
          return request;
        },
      );
      final published = <LinkStatus>[];
      poller.status.addListener(() => published.add(poller.status.value));

      poller.start();
      await acquired.future;
      expect(fixture.accepted, 1, reason: 'the socket really was established');

      poller.dispose();
      gate.complete(); // the acquired request is delivered after disposal
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(published, isEmpty);
      expect(
        fixture.accepted,
        1,
        reason: 'the aborted request was never sent and nothing polled again',
      );
      expect(fixture.live, 0, reason: 'the socket was released on disposal');
      expect(fixture.closed, 1);
    });

    test('while the connection is still being acquired', () async {
      // The pre-acquisition path: the gate is held before getUrl, so disposal
      // force-closes the client and the acquisition fails instead of returning.
      final fixture = await RawFixture.start(
        (_, socket, _) => socket.write(httpResponse(validBody)),
      );
      addTearDown(fixture.close);
      final gate = Completer<void>();
      final poller = Poller(
        uri: fixture.uri,
        interval: once,
        deadline: deadline,
        openRequest: (client, uri) async {
          await gate.future;
          return client.getUrl(uri);
        },
      );
      final published = <LinkStatus>[];
      poller.status.addListener(() => published.add(poller.status.value));

      poller.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      poller.dispose();
      gate.complete(); // the acquisition runs *after* disposal
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(published, isEmpty);
      expect(
        fixture.accepted,
        0,
        reason: 'the disposed client never opened a connection',
      );
      expect(fixture.live, 0);
    });

    test('while waiting for headers', () async {
      final fixture = await RawFixture.start((_, _, _) {});
      addTearDown(fixture.close);

      final published = await disposeDuring(
        Poller(uri: fixture.uri, interval: once, deadline: deadline),
        const Duration(milliseconds: 60),
      );

      expect(published, isEmpty);
      expect(fixture.accepted, 1);
      expect(fixture.closed, 1, reason: 'the socket was released on disposal');
    });

    for (final status in [200, 503]) {
      test('while reading a $status body', () async {
        final fixture = await RawFixture.start((fixture, socket, _) {
          socket.write(
            httpResponse('{"hub"', status: status, contentLength: 500),
          );
        });
        addTearDown(fixture.close);

        final published = await disposeDuring(
          Poller(uri: fixture.uri, interval: once, deadline: deadline),
          const Duration(milliseconds: 60),
        );

        expect(published, isEmpty);
        expect(fixture.closed, 1, reason: 'the body read was cancelled');
      });
    }

    test('while waiting between polls', () async {
      final fixture = await Fixture.serve(validBody);
      addTearDown(fixture.close);
      final poller = Poller(
        uri: fixture.uri,
        interval: const Duration(milliseconds: 300),
        deadline: deadline,
      );
      final published = <LinkStatus>[];
      poller.status.addListener(() => published.add(poller.status.value));

      poller.start();
      await until(() => published.isNotEmpty);
      poller.dispose(); // now inside the interval wait
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(published, hasLength(1));
      expect(
        fixture.requests,
        hasLength(1),
        reason: 'the pending wait never started another poll',
      );
    });

    test('while a poll that would publish something else is in flight', () async {
      // The other disposal tests end in NoHub, which equals the value already
      // published and therefore notifies nobody. Here the pending attempt would
      // publish a *different* status, so a missing guard is visible: it would
      // touch a disposed notifier and blow up in the loop's continuation.
      final fixture = await Fixture.serve(
        validBody,
        delay: const Duration(milliseconds: 120),
      );
      addTearDown(fixture.close);
      final poller = Poller(
        uri: fixture.uri,
        interval: const Duration(milliseconds: 20),
        deadline: const Duration(milliseconds: 400),
      );
      final published = <LinkStatus>[];
      poller.status.addListener(() => published.add(poller.status.value));

      poller.start();
      await until(() => published.isNotEmpty); // Online is out
      await Future<void>.delayed(const Duration(milliseconds: 60));
      poller.dispose(); // the second attempt is in flight
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(published, hasLength(1));
      expect(published.single, isA<Online>());
      expect(fixture.requests, hasLength(2), reason: 'no third attempt began');
    });

    test('a listener disposing during publication is safe', () async {
      // dispose() from inside notifyListeners() would trip the assert in
      // ChangeNotifier.dispose, which notifyListeners reports instead of
      // throwing: silent listener leak. Errors are captured to catch that.
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);

      final fixture = await Fixture.serve(validBody);
      addTearDown(fixture.close);
      final poller = Poller(
        uri: fixture.uri,
        interval: const Duration(milliseconds: 20),
        deadline: deadline,
      );
      final published = <LinkStatus>[];
      poller.status.addListener(() {
        published.add(poller.status.value);
        poller.dispose(); // reentrant, from within the notification
      });

      poller.start();
      await until(() => published.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(errors, isEmpty, reason: 'no Flutter error was reported');
      expect(published, hasLength(1));
      expect(fixture.requests, hasLength(1), reason: 'no poll after disposal');
      expect(
        () => poller.status.addListener(() {}),
        throwsA(isA<FlutterError>()),
        reason: 'the notifier really was disposed, listeners released',
      );
    });

    test('disposing twice is harmless', () async {
      final fixture = await Fixture.serve(validBody);
      addTearDown(fixture.close);
      final poller = Poller(
        uri: fixture.uri,
        interval: once,
        deadline: deadline,
      );

      poller.start();
      poller.dispose();
      poller.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    test('starting after disposal does nothing', () async {
      final fixture = await Fixture.serve(validBody);
      addTearDown(fixture.close);
      final poller = Poller(
        uri: fixture.uri,
        interval: once,
        deadline: deadline,
      );

      poller.dispose();
      poller.start();
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(fixture.requests, isEmpty);
    });
  });
}
