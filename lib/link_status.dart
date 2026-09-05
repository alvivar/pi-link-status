/// Model, parsing and formatting for the pi-link `GET /status` contract.
///
/// Pure Dart: no Flutter, no I/O, no clock of its own. Validation mirrors
/// `isStatusPayload` in pi-link 0.4.0 (`bin/pi-link.mjs`), so anything that
/// implementation rejects becomes a `FormatException` here and `Unsupported`
/// upstream, never a cast error while rendering.
library;

/// What a single query produced. Exactly the three outcomes of the CLI.
sealed class LinkStatus {
  const LinkStatus();

  /// Aggregate colour of the whole fleet, in priority order.
  FleetState get fleet => switch (this) {
    NoHub() || Unsupported() => FleetState.offline,
    Online(:final terminals) => _fleetOf(terminals),
  };
}

/// Nothing answered on the port: refused, unreachable or timed out. May be
/// transient — hub promotion takes 2–5 s.
final class NoHub extends LinkStatus {
  const NoHub();
}

/// Something answered but does not speak this contract (old hub, non-200,
/// unparseable or invalid body).
final class Unsupported extends LinkStatus {
  const Unsupported();
}

/// A valid payload, plus the instant it arrived: `sinceSeconds` is relative to
/// the response, so ages are only correct against [receivedAt].
final class Online extends LinkStatus {
  const Online({
    required this.hub,
    required this.terminals,
    required this.receivedAt,
  });

  /// Parses a decoded JSON payload. Throws [FormatException] if it does not
  /// match the contract; unknown fields are ignored on purpose, since the hub
  /// is allowed to grow.
  factory Online.fromJson(Object? json, {required DateTime receivedAt}) {
    if (json is! Map) throw const FormatException('payload is not an object');
    final hub = json['hub'];
    if (hub is! String) throw const FormatException('hub is not a string');
    if (json['port'] is! num) {
      throw const FormatException('port is not a number');
    }

    final entries = json['terminals'];
    // A hub always reports itself, so an empty list is not this contract.
    if (entries is! List || entries.isEmpty) {
      throw const FormatException('terminals is not a non-empty array');
    }
    final terminals = [
      for (var i = 0; i < entries.length; i++)
        Terminal._fromJson(entries[i], i),
    ];
    if (terminals.first.name != hub) {
      throw const FormatException('terminals[0] is not the hub');
    }
    return Online(hub: hub, terminals: terminals, receivedAt: receivedAt);
  }

  final String hub;

  /// Hub first, then clients sorted by name — the order the hub sends.
  final List<Terminal> terminals;
  final DateTime receivedAt;
}

/// One terminal connected to the hub.
final class Terminal {
  const Terminal({
    required this.name,
    required this.role,
    required this.context,
    this.status,
    this.sinceSeconds,
    this.cwd,
  });

  factory Terminal._fromJson(Object? json, int index) {
    if (json is! Map) {
      throw FormatException('terminals[$index] is not an object');
    }
    final name = json['name'];
    if (name is! String) {
      throw FormatException('terminals[$index].name is not a string');
    }
    // Hub first, then clients — the ordering every consumer relies on.
    final role = index == 0 ? 'hub' : 'client';
    if (json['role'] != role) {
      throw FormatException("terminals[$index].role is not '$role'");
    }

    // `status` and `sinceSeconds` are one optional pair: both or neither.
    // Absence means unknown; substituting `idle` is the mistake this contract
    // exists to prevent.
    final hasStatus = json.containsKey('status');
    if (hasStatus != json.containsKey('sinceSeconds')) {
      throw FormatException(
        'terminals[$index]: status and sinceSeconds must appear together',
      );
    }
    String? status;
    int? sinceSeconds;
    if (hasStatus) {
      final value = json['status'];
      // The vocabulary is deliberately not frozen: a future hub kind must
      // render as itself, not reject the payload. Empty is still rejected.
      if (value is! String || value.isEmpty) {
        throw FormatException('terminals[$index] has an invalid status');
      }
      status = value;
      sinceSeconds = _integerFrom(
        json['sinceSeconds'],
        'terminals[$index].sinceSeconds',
      );
    }

    final cwd = json['cwd'];
    if (json.containsKey('cwd') && cwd is! String) {
      throw FormatException('terminals[$index].cwd is not a string');
    }
    if (!json.containsKey('context')) {
      throw FormatException('terminals[$index].context is missing');
    }
    return Terminal(
      name: name,
      role: role,
      context: ContextUsage._fromJson(json['context'], index),
      status: status,
      sinceSeconds: sinceSeconds,
      cwd: cwd as String?,
    );
  }

  final String name;

  /// `hub` for the first entry, `client` for the rest.
  final String role;

  /// `null` when the hub has registered this terminal but not heard from it.
  final String? status;

  /// Seconds in [status] at [Online.receivedAt]; `null` with [status].
  final int? sinceSeconds;

  /// `null` when the hub does not know the working directory.
  final String? cwd;

  /// `null` when there is no context snapshot.
  final ContextUsage? context;

  /// The status as sent, or `?` when unknown. Never `idle` by default.
  String get statusLabel => status ?? _unknown;

  /// Seconds in [status] as of [now], or `null` when the status is unknown.
  int? ageSeconds(DateTime receivedAt, DateTime now) {
    final since = sinceSeconds;
    return since == null ? null : since + now.difference(receivedAt).inSeconds;
  }
}

/// Context window usage of one terminal.
final class ContextUsage {
  const ContextUsage({required this.tokens, required this.window});

  /// Returns `null` when there is no snapshot at all, which the hub sends as an
  /// explicit `context: null`. A snapshot whose `tokens` is null is still a
  /// snapshot, so it returns a [ContextUsage].
  static ContextUsage? _fromJson(Object? json, int index) {
    if (json == null) return null;
    if (json is! Map) {
      throw FormatException('terminals[$index].context is not an object');
    }
    // Both keys are required: an omitted `tokens` is not the same as a null
    // one, exactly as for `context` itself.
    if (!json.containsKey('tokens')) {
      throw FormatException('terminals[$index].context.tokens is missing');
    }
    final tokens = json['tokens'];
    return ContextUsage(
      tokens: tokens == null
          ? null
          : _integerFrom(tokens, 'terminals[$index].context.tokens'),
      window: _integerFrom(json['window'], 'terminals[$index].context.window'),
    );
  }

  /// `null` while the token count is mid-refresh; the window is still known.
  final int? tokens;
  final int window;
}

/// The first double above the signed 64-bit range, so `abs() < _intLimit`
/// means [num.toInt] converts without clamping.
const _intLimit = 9223372036854775808.0;

/// A JSON number stored as an `int`. `jsonDecode` yields an `int` only for
/// integral literals, so `272000.0` arrives as a `double` and is accepted.
/// Fractional values truncate deliberately: the documented payload uses whole
/// seconds, token counts and window sizes, while the JS validator itself
/// accepts fractions and the CLI would print them as sent.
///
/// Values a Dart `int` cannot hold are rejected: `1e400` decodes as
/// `double.infinity` and `1e300` would silently clamp to the maximum `int`.
/// The reference client tolerates both because JavaScript keeps them as
/// doubles, so this is a representation boundary of this app, not parity.
int _integerFrom(Object? value, String what) {
  if (value is int) return value;
  if (value is double && value.isFinite && value.abs() < _intLimit) {
    return value.toInt();
  }
  throw FormatException('$what is not a number an int can hold');
}

/// Aggregate state of the fleet, evaluated in this order.
enum FleetState { offline, compacting, busy, unknown, idle }

/// Unknown blocks confirming "all idle" but is not observed work: `thinking`
/// or `tool:*` beside an unknown still means busy.
FleetState _fleetOf(List<Terminal> terminals) {
  var busy = false;
  var unknown = false;
  for (final terminal in terminals) {
    switch (terminal.status) {
      case 'compacting':
        return FleetState.compacting; // outranks everything else
      case 'thinking':
        busy = true;
      case final status? when status.startsWith('tool:'):
        busy = true;
      case 'idle':
        break;
      default:
        unknown = true; // absent, or a status this version does not know
    }
  }
  if (busy) return FleetState.busy;
  if (unknown) return FleetState.unknown;
  return FleetState.idle;
}

/// What the hub could not report.
const _unknown = '?';

/// `92000 → 92K`, `1300000 → 1.3M`, `999 → 999`.
String formatTokens(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).round()}K';
  return '$n';
}

/// `92K/272K (34%)`, `?/272K` without a token count, `?` without a snapshot.
String formatContext(ContextUsage? context) {
  // A non-positive window is well typed but means nothing to report.
  if (context == null || context.window <= 0) return _unknown;
  final window = formatTokens(context.window);
  final tokens = context.tokens;
  if (tokens == null) return '$_unknown/$window';
  final percent = (tokens / context.window * 100).round();
  return '${formatTokens(tokens)}/$window ($percent%)';
}

/// `12 → 12s`, `420 → 7m`, `7200 → 2h`.
String formatDuration(int seconds) {
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m';
  return '${seconds ~/ 3600}h';
}

/// Replaces [home] with `~` in a display path. Accepts either separator and
/// only matches on a directory boundary, so `/home/andrew` is not shortened
/// against `/home/andre`.
String shortenHome(String path, String home) {
  if (home.isEmpty) return path;
  final normalizedHome = _normalizeSeparators(home);
  if (normalizedHome.isEmpty) return path;
  final normalizedPath = _normalizeSeparators(path);
  // Windows compares paths case-insensitively and POSIX does not, so the
  // syntax of the home decides. Display keeps the original casing.
  final fold = _isWindowsPath(home);
  final comparableHome = fold ? normalizedHome.toLowerCase() : normalizedHome;
  final comparablePath = fold ? normalizedPath.toLowerCase() : normalizedPath;
  if (comparablePath == comparableHome) return '~';
  if (!comparablePath.startsWith('$comparableHome/')) return path;
  return '~${normalizedPath.substring(normalizedHome.length)}';
}

/// A drive letter or a backslash: enough to tell a Windows path from a POSIX
/// one without reading the ambient platform, which keeps this pure.
bool _isWindowsPath(String path) =>
    path.contains(r'\') || RegExp(r'^[A-Za-z]:').hasMatch(path);

/// Collapses runs of either separator to `/` and drops trailing ones, so
/// comparison and the suffix agree on lengths.
String _normalizeSeparators(String path) =>
    path.replaceAll(RegExp(r'[/\\]+'), '/').replaceAll(RegExp(r'/$'), '');
