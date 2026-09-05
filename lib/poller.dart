import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'link_status.dart';

/// The pi-link hub endpoint. Fixed by the contract, not a user setting.
final _statusEndpoint = Uri.parse('http://127.0.0.1:9900/status');

/// How a request is opened. The only seam in this file: tests need an
/// acquisition they can hold open, because a loopback connection is otherwise
/// impossible to catch in flight deterministically.
typedef OpenRequest =
    Future<HttpClientRequest> Function(HttpClient client, Uri uri);

/// One poll, and everything it owns.
///
/// The resources live here, not on the [Poller], so a continuation of a
/// cancelled attempt can only ever touch its own request, subscription and
/// completers — never those of the attempt that came after it.
class _Attempt {
  /// Completed by cancellation, which both decides the result and marks every
  /// later continuation of this attempt as stale.
  final Completer<LinkStatus> cancelled = Completer<LinkStatus>();

  HttpClientRequest? request;
  StreamSubscription<String>? body;
  Completer<String>? bodyDone;

  /// The subscription's asynchronous cleanup, awaited before the attempt is
  /// considered settled.
  Future<void>? cleanup;

  bool get isCancelled => cancelled.isCompleted;
}

/// Polls `/status` serially and publishes the result.
///
/// One attempt at a time, and one *completely finished* attempt at a time: the
/// next poll starts [interval] after the previous one has settled, cancellation
/// included. Each attempt gets a single [deadline] budget covering connection,
/// headers and the whole body, including bodies that are only discarded.
/// Expiring the budget cancels the request for real: a `Future.timeout` would
/// leave the socket alive and the response arriving behind the next attempt.
class Poller {
  Poller({
    Uri? uri,
    this.interval = const Duration(seconds: 2),
    this.deadline = const Duration(seconds: 2),
    @visibleForTesting OpenRequest? openRequest,
  }) : uri = uri ?? _statusEndpoint,
       _open = openRequest ?? _getUrl;

  static Future<HttpClientRequest> _getUrl(HttpClient client, Uri uri) =>
      client.getUrl(uri);

  /// Endpoint to poll. Injectable so tests can aim at an ephemeral server.
  final Uri uri;

  /// Pause after an attempt settles before the next one starts.
  final Duration interval;

  /// Total budget per attempt, from before asking for a connection until the
  /// body is fully read or discarded.
  final Duration deadline;

  final OpenRequest _open;

  /// Last known state; `NoHub` until the first attempt finishes.
  ValueListenable<LinkStatus> get status => _status;
  final ValueNotifier<LinkStatus> _status = ValueNotifier(const NoHub());

  /// Kept across attempts for keep-alive; replaced only when an attempt has to
  /// be cancelled, because force-closing is the only way to drop a connection
  /// that is still being acquired.
  HttpClient? _client;

  /// The attempt in flight, so the budget and [dispose] can reach it.
  _Attempt? _current;

  /// The wait between attempts, interruptible by [dispose].
  Timer? _waitTimer;
  Completer<void>? _waiting;

  bool _started = false;
  bool _disposed = false;

  /// Starts the polling loop. Calling it again is a no-op: one loop only.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _loop();
  }

  Future<void> _loop() async {
    while (!_disposed) {
      final result = await _attempt();
      if (_disposed) return; // disposal wins over a result already in hand
      _status.value = result;
      if (_disposed) return; // a listener may have disposed us while notified
      await _wait();
    }
  }

  /// Runs one attempt under the total budget and returns only once it has
  /// settled, so the caller never schedules work behind a live request.
  Future<LinkStatus> _attempt() async {
    final attempt = _Attempt();
    _current = attempt;
    final budget = Timer(deadline, () => _cancel(attempt));
    final fetch = _fetch(attempt);
    try {
      // The loser of this race is not abandoned: it is awaited below, and
      // Future.any keeps an error handler on it meanwhile.
      return await Future.any([fetch, attempt.cancelled.future]);
    } on FormatException {
      return const Unsupported(); // malformed JSON or an incompatible payload
    } on IOException {
      return const NoHub(); // refused, reset, aborted: the hub is not usable
    } finally {
      budget.cancel();
      await _settle(attempt, fetch);
      _current = null;
    }
  }

  /// Waits for the fetch continuation and the cancellation cleanup to finish.
  /// Their failures are expected here — we caused them — so they are consumed
  /// deliberately rather than left to an ignored future.
  Future<void> _settle(_Attempt attempt, Future<LinkStatus> fetch) async {
    await fetch.then((_) {}, onError: (Object _, StackTrace _) {});
    await attempt.cleanup;
  }

  Future<LinkStatus> _fetch(_Attempt attempt) async {
    final client = _client ??= HttpClient()
      ..connectionTimeout = const Duration(seconds: 2);

    final HttpClientRequest request;
    try {
      request = await _open(client, uri);
    } catch (_) {
      // Cancellation force-closes the client, so a failure here is our own
      // doing, not a hub problem worth classifying.
      if (attempt.isCancelled) return const NoHub();
      rethrow;
    }
    if (attempt.isCancelled) {
      // The connection arrived after the attempt was cancelled: make it
      // unusable instead of letting it run behind the next attempt.
      request.abort();
      return const NoHub();
    }
    attempt.request = request;

    final response = await request.close();
    if (attempt.isCancelled) return const NoHub(); // socket already destroyed
    // A non-200 body is read and discarded rather than left dangling, and it
    // spends the same budget as a real one.
    final body = await _read(
      attempt,
      response,
      keep: response.statusCode == 200,
    );
    final receivedAt = DateTime.now();
    if (attempt.isCancelled) return const NoHub();
    if (response.statusCode != 200) return const Unsupported();
    return Online.fromJson(jsonDecode(body), receivedAt: receivedAt);
  }

  /// Drains [response], collecting it only when [keep]. The subscription is
  /// held by [attempt] so cancellation can stop the read instead of draining.
  Future<String> _read(
    _Attempt attempt,
    HttpClientResponse response, {
    required bool keep,
  }) {
    final done = Completer<String>();
    final buffer = StringBuffer();
    attempt.bodyDone = done;
    attempt.body = response
        .transform(utf8.decoder)
        .listen(
          (chunk) {
            if (keep) buffer.write(chunk);
          },
          onDone: () {
            if (!done.isCompleted) done.complete(buffer.toString());
          },
          onError: (Object error, StackTrace stack) {
            if (!done.isCompleted) done.completeError(error, stack);
          },
          cancelOnError: true,
        );
    return done.future;
  }

  /// Aborts [attempt] and releases everything it holds. Safe at any phase and
  /// idempotent; the attempt is only *settled* once [_settle] returns.
  void _cancel(_Attempt attempt) {
    if (attempt.isCancelled) return;
    attempt.cancelled.complete(const NoHub()); // the result is decided now

    final body = attempt.body;
    attempt.body = null;
    // cancel() finishes asynchronously, so its future is kept and awaited.
    attempt.cleanup = body?.cancel().then(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );

    // Unblock the reader too: a cancelled subscription never calls onDone, so
    // without this the fetch would stay pending for good.
    final bodyDone = attempt.bodyDone;
    attempt.bodyDone = null;
    if (bodyDone != null && !bodyDone.isCompleted) {
      bodyDone.completeError(const HttpException('poll cancelled'));
    }

    attempt.request?.abort();
    attempt.request = null;

    _closeClient();
  }

  /// Drops the socket being acquired, the one being read, and any idle
  /// keep-alive socket. A normal poll never closes the client, so successful
  /// polls keep reusing the same connection.
  void _closeClient() {
    _client?.close(force: true);
    _client = null;
  }

  /// Waits [interval] between attempts, returning early on disposal.
  Future<void> _wait() {
    final waiting = Completer<void>();
    _waiting = waiting;
    _waitTimer = Timer(interval, () {
      if (!waiting.isCompleted) waiting.complete();
    });
    // Clears the reference once the wait is over; the guard in [dispose] still
    // matters, because disposal can land in the same turn as the timer, before
    // this callback runs.
    return waiting.future.whenComplete(() {
      _waiting = null;
      _waitTimer = null;
    });
  }

  /// Stops polling and releases every resource. After this the loop publishes
  /// nothing, starts no request and leaves no pending timer.
  void dispose() {
    if (_disposed) return;
    _disposed = true; // checked after every await, so no continuation publishes

    final current = _current;
    if (current != null) _cancel(current);
    _closeClient(); // ...and the keep-alive client, when nothing was in flight

    _waitTimer?.cancel();
    _waitTimer = null;
    final waiting = _waiting;
    _waiting = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();

    // Deferred on purpose: dispose() may be called by a status listener, i.e.
    // from inside notifyListeners(), where ChangeNotifier.dispose asserts.
    // Everything above already stopped the poller; only the notifier waits for
    // the notification to unwind.
    scheduleMicrotask(_status.dispose);
  }
}
