import 'package:flutter_test/flutter_test.dart';
import 'package:pi_link_status/idle_alert.dart';
import 'package:pi_link_status/link_status.dart';

final start = DateTime.utc(2024, 1, 1, 9);

/// The instant sample [index] arrived, one poll (2 s) apart.
DateTime at(int index) => start.add(Duration(seconds: 2 * index));

/// A snapshot whose members are exactly [members], mapping name to status; a
/// null status is a terminal the hub has not heard from. Insertion order only
/// decides which name is the hub, never the membership set.
Online snapshot(Map<String, String?> members) {
  final names = members.keys.toList();
  return Online(
    hub: names.first,
    terminals: [
      for (var i = 0; i < names.length; i++)
        Terminal(
          name: names[i],
          role: i == 0 ? 'hub' : 'client',
          context: null,
          status: members[names[i]],
          sinceSeconds: members[names[i]] == null ? null : 5,
        ),
    ],
    receivedAt: at(0),
  );
}

// The stable two-member fleet used by the aggregate sequences.
final busy = snapshot({'a': 'thinking', 'b': 'idle'});
final compacting = snapshot({'a': 'compacting', 'b': 'idle'});
final unknown = snapshot({'a': null, 'b': 'idle'});
final idle = snapshot({'a': 'idle', 'b': 'idle'});

/// Feeds [samples] in order, one poll apart, and collects the answers.
List<bool> run(IdleAlert alert, List<LinkStatus> samples) => [
  for (var i = 0; i < samples.length; i++) alert.observe(samples[i], at(i)),
];

void main() {
  group('the basic trigger rule', () {
    test('busy, idle, idle alerts on the second confirmation', () {
      final alert = IdleAlert();
      expect(run(alert, [busy, idle, idle]), [false, false, true]);
      expect(alert.lastAllIdle, at(2));
    });

    test('work restarting before the confirmation defers the alert', () {
      final alert = IdleAlert();
      expect(run(alert, [busy, idle, busy, idle, idle]), [
        false,
        false,
        false,
        false,
        true,
      ]);
      expect(alert.lastAllIdle, at(4));
    });

    test('sustained idle alerts once and freezes the historical time', () {
      final alert = IdleAlert();
      expect(run(alert, [busy, idle, idle, idle, idle]), [
        false,
        false,
        true,
        false,
        false,
      ]);
      expect(alert.lastAllIdle, at(2));
    });

    test('starting already idle records the time but never alerts', () {
      final alert = IdleAlert();
      expect(run(alert, [idle, idle, idle]), [false, false, false]);
      expect(alert.lastAllIdle, at(1), reason: 'set on the second sample');
    });

    test('compacting arms just like busy', () {
      final alert = IdleAlert();
      expect(run(alert, [compacting, idle, idle]), [false, false, true]);
    });

    test('a single short busy sample is enough: no minimum duration', () {
      final alert = IdleAlert();
      final brief = snapshot({'a': 'tool:bash', 'b': 'idle'});
      expect(brief.terminals.first.sinceSeconds, lessThan(60));
      expect(run(alert, [idle, brief, idle, idle]), [
        false,
        false,
        false,
        true,
      ]);
    });

    test('confirmations: 1 alerts on the first idle sample', () {
      final alert = IdleAlert(confirmations: 1);
      expect(run(alert, [busy, idle]), [false, true]);
      expect(alert.lastAllIdle, at(1));
    });
  });

  group('unknown blocks confirmation without arming or disarming', () {
    test('unknown never arms', () {
      final alert = IdleAlert();
      expect(run(alert, [unknown, idle, idle]), [false, false, false]);
      expect(alert.lastAllIdle, at(2), reason: 'still confirmed all idle');
    });

    test('unknown restarts the streak but keeps the observed work', () {
      final alert = IdleAlert();
      expect(run(alert, [busy, idle, unknown, idle, idle]), [
        false,
        false,
        false,
        false,
        true,
      ]);
    });
  });

  group('offline disarms and forgets the roster', () {
    test('busy, offline, idle, idle does not alert', () {
      for (final offline in [const NoHub(), const Unsupported()]) {
        final alert = IdleAlert();
        expect(run(alert, [busy, offline, idle, idle]), [
          false,
          false,
          false,
          false,
        ], reason: '$offline');
        expect(alert.lastAllIdle, at(3));
      }
    });

    test('reconnecting already idle cannot recover an old arming', () {
      for (final offline in [const NoHub(), const Unsupported()]) {
        final alert = IdleAlert();
        expect(run(alert, [busy, idle, offline, idle, idle, idle]), [
          false,
          false,
          false,
          false,
          false,
          false,
        ], reason: '$offline');
      }
    });

    test('offline never erases the historical time', () {
      for (final offline in [const NoHub(), const Unsupported()]) {
        final alert = IdleAlert();
        run(alert, [busy, idle, idle]);
        final recorded = alert.lastAllIdle;
        expect(recorded, at(2));
        expect(alert.observe(offline, at(3)), isFalse);
        expect(alert.lastAllIdle, recorded, reason: '$offline');
      }
    });

    test('work after reconnecting arms a new cycle normally', () {
      final alert = IdleAlert();
      expect(run(alert, [busy, const NoHub(), busy, idle, idle]), [
        false,
        false,
        false,
        false,
        true,
      ]);
    });
  });

  group('muting', () {
    test('suppresses the alert but still records the time', () {
      final alert = IdleAlert()..muted = true;
      expect(run(alert, [busy, idle, idle]), [false, false, false]);
      expect(alert.lastAllIdle, at(2));
    });

    test('un-muting while still idle replays nothing', () {
      final alert = IdleAlert()..muted = true;
      run(alert, [busy, idle, idle]);
      alert.muted = false;
      expect(alert.observe(idle, at(3)), isFalse);
      expect(alert.observe(idle, at(4)), isFalse);
      expect(alert.lastAllIdle, at(2), reason: 'the time stays frozen too');
    });

    test('fresh work after un-muting arms a new cycle that does alert', () {
      final alert = IdleAlert()..muted = true;
      run(alert, [busy, idle, idle]);
      alert.muted = false;
      expect(run(alert, [busy, idle, idle]), [false, false, true]);
    });

    test(
      'mute does not touch the debounce: unmuting mid-streak still fires',
      () {
        final alert = IdleAlert()..muted = true;
        expect(alert.observe(busy, at(0)), isFalse);
        expect(alert.observe(idle, at(1)), isFalse);
        alert.muted = false;
        expect(
          alert.observe(idle, at(2)),
          isTrue,
          reason: 'the streak and the arming survived the mute',
        );
      },
    );
  });

  group('membership changes', () {
    test('a departure is not a completion, even of the working member', () {
      final alert = IdleAlert();
      expect(
        run(alert, [
          snapshot({'a': 'thinking', 'b': 'idle'}),
          snapshot({'b': 'idle'}),
          snapshot({'b': 'idle'}),
        ]),
        [false, false, false],
      );
      expect(alert.lastAllIdle, at(2), reason: 'confirmed, just not announced');
    });

    test('losing a member that was already idle suppresses the arming', () {
      final alert = IdleAlert();
      expect(
        run(alert, [
          snapshot({'a': 'thinking', 'b': 'idle', 'c': 'idle'}),
          snapshot({'a': 'idle', 'b': 'idle', 'c': 'idle'}),
          snapshot({'a': 'idle', 'b': 'idle'}),
          snapshot({'a': 'idle', 'b': 'idle'}),
        ]),
        [false, false, false, false],
      );
    });

    test('a departure during the first confirmation restarts it', () {
      final alert = IdleAlert();
      expect(
        run(alert, [
          snapshot({'a': 'thinking', 'b': 'idle', 'c': 'idle'}),
          snapshot({'a': 'idle', 'b': 'idle', 'c': 'idle'}),
          snapshot({'a': 'idle', 'b': 'idle'}),
          snapshot({'a': 'idle', 'b': 'idle'}),
          snapshot({'a': 'idle', 'b': 'idle'}),
        ]),
        [false, false, false, false, false],
      );
    });

    test('work surviving a departure arms a new cycle in the same sample', () {
      final alert = IdleAlert();
      expect(
        run(alert, [
          snapshot({'a': 'thinking', 'b': 'thinking'}),
          snapshot({'b': 'thinking'}),
          snapshot({'b': 'idle'}),
          snapshot({'b': 'idle'}),
        ]),
        [false, false, false, true],
      );
      expect(alert.lastAllIdle, at(3));
    });

    test('an arrival restarts the streak but keeps the observed work', () {
      final alert = IdleAlert();
      expect(
        run(alert, [
          snapshot({'a': 'thinking', 'b': 'idle'}),
          snapshot({'a': 'idle', 'b': 'idle'}),
          snapshot({'a': 'idle', 'b': 'idle', 'c': 'idle'}),
          snapshot({'a': 'idle', 'b': 'idle', 'c': 'idle'}),
        ]),
        [false, false, false, true],
      );
    });

    test('reordering the same members changes nothing', () {
      final alert = IdleAlert();
      expect(
        run(alert, [
          snapshot({'a': 'thinking', 'b': 'idle'}),
          snapshot({'a': 'idle', 'b': 'idle'}),
          snapshot({'b': 'idle', 'a': 'idle'}),
        ]),
        [false, false, true],
      );
    });

    test('a rename is a departure plus an arrival, handled conservatively', () {
      final alert = IdleAlert();
      expect(
        run(alert, [
          snapshot({'a': 'thinking', 'b': 'idle'}),
          snapshot({'a': 'idle', 'b': 'idle'}),
          snapshot({'a': 'idle', 'b2': 'idle'}),
          snapshot({'a': 'idle', 'b2': 'idle'}),
        ]),
        [false, false, false, false],
      );
      expect(alert.lastAllIdle, at(3));
    });

    test('the first Online sample is not a departure', () {
      final alert = IdleAlert();
      expect(run(alert, [busy, idle, idle]), [false, false, true]);
    });

    test('no membership reset erases the historical time', () {
      final alert = IdleAlert();
      run(alert, [busy, idle, idle]);
      final recorded = alert.lastAllIdle;
      expect(recorded, at(2));
      // A departure, then an arrival, neither of them confirming anything new.
      expect(alert.observe(snapshot({'a': 'idle'}), at(3)), isFalse);
      expect(
        alert.observe(snapshot({'a': 'idle', 'z': 'idle'}), at(4)),
        isFalse,
      );
      expect(alert.lastAllIdle, recorded);
    });
  });
}
