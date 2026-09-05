import 'link_status.dart';

/// Decides when to announce that every agent went idle.
///
/// Pure: no timers, no UI, no clock of its own. The owner feeds it every
/// snapshot with the instant it arrived and acts on the returned bool.
///
/// The rule is deliberately conservative. Being idle does not prove the work
/// succeeded, so the alert only fires after recognized work was *observed*
/// (`busy` or `compacting`) and idle is then confirmed on consecutive samples.
/// Anything ambiguous — an unknown status, a terminal leaving, the hub going
/// away — resets the confirmation instead of counting as completion.
class IdleAlert {
  IdleAlert({this.confirmations = 2}) : assert(confirmations >= 1);

  /// Consecutive idle samples required before announcing. Two at a 2 s poll is
  /// roughly 2–4 s after the transition; lower values exist for tests.
  final int confirmations;

  /// Suppresses the announcement without touching the machine: membership,
  /// arming and the confirmation streak all keep running, and the historical
  /// time keeps updating. Un-muting never replays a suppressed alert.
  bool muted = false;

  /// When every agent was last confirmed idle in this session, or `null` if it
  /// never happened. Session memory: no reset ever erases it.
  DateTime? get lastAllIdle => _lastAllIdle;
  DateTime? _lastAllIdle;

  /// Recognized work has been observed and not yet answered by a confirmation.
  bool _armed = false;

  /// Consecutive idle samples so far, capped at [confirmations].
  int _idleStreak = 0;

  /// Names in the previous Online snapshot, or `null` when the last sample was
  /// offline or none has arrived. Order is irrelevant, so a set.
  Set<String>? _previousNames;

  /// Feeds one snapshot, taken at [now]. Returns true exactly once per armed
  /// cycle, on the sample that confirms the fleet is idle.
  bool observe(LinkStatus status, DateTime now) {
    if (status is! Online) {
      // The hub is gone or unusable. That is not "they finished": disarm and
      // forget the roster, so reconnecting already idle cannot alert. Only the
      // historical time survives.
      _armed = false;
      _idleStreak = 0;
      _previousNames = null;
      return false;
    }

    // Membership is settled before the fleet is judged, so that recognized work
    // among the survivors can arm a new cycle in the very same sample where
    // someone left.
    final names = {for (final terminal in status.terminals) terminal.name};
    final previous = _previousNames;
    if (previous != null) {
      if (!names.containsAll(previous)) {
        // Someone left, even if they were idle. A departure is not a
        // completion, and a rename shows up as one, so treat it conservatively.
        _armed = false;
        _idleStreak = 0;
      } else if (names.length != previous.length) {
        // Only arrivals: the new roster has to prove itself idle, but the work
        // already observed still counts.
        _idleStreak = 0;
      }
    }
    _previousNames = names;

    switch (status.fleet) {
      case FleetState.busy || FleetState.compacting:
        // Observed work of any duration arms; there is no minimum.
        _armed = true;
        _idleStreak = 0;
      case FleetState.unknown:
        // Blocks confirmation without arming, and without disarming: unknown is
        // not work and not completion.
        _idleStreak = 0;
      case FleetState.idle:
        // Sustained idle changes nothing: neither a second alert nor a moving
        // historical time.
        if (_idleStreak >= confirmations) return false;
        _idleStreak++;
        if (_idleStreak < confirmations) return false;
        // Confirmed. The time is recorded even when unarmed or muted.
        _lastAllIdle = now;
        final wasArmed = _armed;
        _armed = false; // consumed either way, so mute cannot queue an alert
        return wasArmed && !muted;
      case FleetState.offline:
        break; // unreachable: an Online snapshot never aggregates to offline
    }
    return false;
  }
}
