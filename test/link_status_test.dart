import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pi_link_status/link_status.dart';

/// The README payload of `pi-link --status --json`, verbatim in shape: a hub
/// that is idle, a client running a tool, and a client the hub has registered
/// but never heard from.
const readmePayload = '''
{
  "hub": "opus@pi-link",
  "port": 9900,
  "terminals": [
    { "name": "opus@pi-link", "role": "hub", "status": "idle", "sinceSeconds": 420,
      "cwd": "C:/Users/andre/my-project", "context": { "tokens": 92000, "window": 272000 } },
    { "name": "gpt@pi-link", "role": "client", "status": "tool:link_send", "sinceSeconds": 3,
      "cwd": "C:/Users/andre/my-project", "context": { "tokens": null, "window": 272000 } },
    { "name": "new@pi-link", "role": "client", "context": null }
  ]
}
''';

final receivedAt = DateTime.utc(2024, 1, 1, 12);

Online parse(Object? json) => Online.fromJson(json, receivedAt: receivedAt);

/// A payload of terminals described only by status, which is what the fleet
/// rules turn on. `null` means the pair is absent.
Object payloadWith(List<String?> statuses) => {
  'hub': 'a@pi-link',
  'port': 9900,
  'terminals': [
    for (var i = 0; i < statuses.length; i++)
      {
        'name': i == 0 ? 'a@pi-link' : 'c$i@pi-link',
        'role': i == 0 ? 'hub' : 'client',
        'context': null,
        if (statuses[i] != null) 'status': statuses[i],
        if (statuses[i] != null) 'sinceSeconds': 5,
      },
  ],
};

/// A single-terminal payload whose one entry is [entry], for shape checks. The
/// hub name follows the entry so a rejection can only come from [entry] itself.
Object payloadOf(Map<String, Object?> entry) => {
  'hub': entry['name'] is String ? entry['name'] : 'a@pi-link',
  'port': 9900,
  'terminals': [entry],
};

void main() {
  group('parsing the README payload', () {
    late Online online;

    setUp(() => online = parse(jsonDecode(readmePayload)));

    test('reads hub, terminals and every field', () {
      expect(online.hub, 'opus@pi-link');
      expect(online.receivedAt, receivedAt);
      expect(online.terminals, hasLength(3));

      final hub = online.terminals[0];
      expect(hub.name, 'opus@pi-link');
      expect(hub.role, 'hub');
      expect(hub.status, 'idle');
      expect(hub.sinceSeconds, 420);
      expect(hub.cwd, 'C:/Users/andre/my-project');
      expect(hub.context?.tokens, 92000);
      expect(hub.context?.window, 272000);

      final tool = online.terminals[1];
      expect(tool.role, 'client');
      expect(tool.status, 'tool:link_send');
      expect(tool.sinceSeconds, 3);

      final fresh = online.terminals[2];
      expect(fresh.status, isNull);
      expect(fresh.sinceSeconds, isNull);
      expect(fresh.cwd, isNull);
      expect(fresh.context, isNull);
    });

    test('is busy: one terminal is in a tool, unknowns do not hide it', () {
      expect(online.fleet, FleetState.busy);
    });

    test('renders context: full, mid-refresh and absent', () {
      expect(formatContext(online.terminals[0].context), '92K/272K (34%)');
      expect(formatContext(online.terminals[1].context), '?/272K');
      expect(formatContext(online.terminals[2].context), '?');
    });

    test('renders labels: known status as sent, absent as ?', () {
      expect(online.terminals[1].statusLabel, 'tool:link_send');
      expect(online.terminals[2].statusLabel, '?');
    });
  });

  group('fleet state', () {
    test('offline when nothing usable answered', () {
      expect(const NoHub().fleet, FleetState.offline);
      expect(const Unsupported().fleet, FleetState.offline);
    });

    test('idle only when every terminal says idle', () {
      expect(
        parse(payloadWith(['idle', 'idle', 'idle'])).fleet,
        FleetState.idle,
      );
    });

    test('unknown when a status is absent and nobody is working', () {
      final online = parse(payloadWith(['idle', null]));
      expect(online.fleet, FleetState.unknown);
      expect(online.terminals[1].statusLabel, '?');
      expect(online.terminals[1].ageSeconds(receivedAt, receivedAt), isNull);
    });

    test('unknown for an unrecognized status, shown as sent', () {
      final online = parse(payloadWith(['idle', 'dreaming']));
      expect(online.fleet, FleetState.unknown);
      expect(online.terminals[1].statusLabel, 'dreaming');
    });

    test('busy: observed work outranks unknowns in either form', () {
      expect(parse(payloadWith(['thinking', null])).fleet, FleetState.busy);
      expect(parse(payloadWith(['tool:bash', null])).fleet, FleetState.busy);
      expect(
        parse(payloadWith(['idle', 'thinking', 'dreaming'])).fleet,
        FleetState.busy,
      );
      expect(
        parse(payloadWith(['tool:read', 'dreaming'])).fleet,
        FleetState.busy,
      );
    });

    test('compacting outranks thinking, tools and unknowns', () {
      expect(
        parse(payloadWith(['thinking', 'compacting'])).fleet,
        FleetState.compacting,
      );
      expect(
        parse(payloadWith(['compacting', 'tool:bash'])).fleet,
        FleetState.compacting,
      );
      expect(
        parse(payloadWith([null, 'compacting'])).fleet,
        FleetState.compacting,
      );
    });

    test('a lone hub is enough to decide', () {
      expect(parse(payloadWith(['idle'])).fleet, FleetState.idle);
      expect(parse(payloadWith([null])).fleet, FleetState.unknown);
    });
  });

  group('rejecting payloads that are not this contract', () {
    void rejects(String reason, Object? json) {
      test(reason, () => expect(() => parse(json), throwsFormatException));
    }

    rejects('not an object', [1, 2, 3]);
    rejects('null body', null);
    rejects('hub is not a string', {
      'hub': 42,
      'port': 9900,
      'terminals': [
        {'name': 'a', 'role': 'hub', 'context': null},
      ],
    });
    rejects('port is missing', {
      'hub': 'a',
      'terminals': [
        {'name': 'a', 'role': 'hub', 'context': null},
      ],
    });
    rejects('port is not a number', {
      'hub': 'a',
      'port': '9900',
      'terminals': [
        {'name': 'a', 'role': 'hub', 'context': null},
      ],
    });
    rejects('terminals is empty', {'hub': 'a', 'port': 9900, 'terminals': []});
    rejects('terminals is not a list', {
      'hub': 'a',
      'port': 9900,
      'terminals': {},
    });
    rejects('terminals is missing', {'hub': 'a', 'port': 9900});
    rejects('a terminal is not an object', {
      'hub': 'a',
      'port': 9900,
      'terminals': ['a'],
    });
    rejects(
      'name is not a string',
      payloadOf({'name': 7, 'role': 'hub', 'context': null}),
    );
    rejects(
      'the first terminal is not the hub role',
      payloadOf({'name': 'a', 'role': 'client', 'context': null}),
    );
    rejects('a later terminal claims the hub role', {
      'hub': 'a',
      'port': 9900,
      'terminals': [
        {'name': 'a', 'role': 'hub', 'context': null},
        {'name': 'b', 'role': 'hub', 'context': null},
      ],
    });
    rejects('hub does not match terminals[0]', {
      'hub': 'other',
      'port': 9900,
      'terminals': [
        {'name': 'a', 'role': 'hub', 'context': null},
      ],
    });
    rejects(
      'status without sinceSeconds',
      payloadOf({
        'name': 'a',
        'role': 'hub',
        'context': null,
        'status': 'idle',
      }),
    );
    rejects(
      'sinceSeconds without status',
      payloadOf({
        'name': 'a',
        'role': 'hub',
        'context': null,
        'sinceSeconds': 5,
      }),
    );
    rejects(
      'status is empty',
      payloadOf({
        'name': 'a',
        'role': 'hub',
        'context': null,
        'status': '',
        'sinceSeconds': 5,
      }),
    );
    rejects(
      'status is not a string',
      payloadOf({
        'name': 'a',
        'role': 'hub',
        'context': null,
        'status': 1,
        'sinceSeconds': 5,
      }),
    );
    rejects(
      'sinceSeconds is not a number',
      payloadOf({
        'name': 'a',
        'role': 'hub',
        'context': null,
        'status': 'idle',
        'sinceSeconds': '5',
      }),
    );
    rejects(
      'cwd is not a string',
      payloadOf({'name': 'a', 'role': 'hub', 'context': null, 'cwd': 3}),
    );
    rejects('context is missing', payloadOf({'name': 'a', 'role': 'hub'}));
    rejects(
      'context is not an object',
      payloadOf({'name': 'a', 'role': 'hub', 'context': 'none'}),
    );
    rejects(
      'context window is missing',
      payloadOf({
        'name': 'a',
        'role': 'hub',
        'context': {'tokens': 10},
      }),
    );
    rejects(
      'context window is not a number',
      payloadOf({
        'name': 'a',
        'role': 'hub',
        'context': {'tokens': 10, 'window': '272000'},
      }),
    );
    rejects(
      'context tokens is not a number',
      payloadOf({
        'name': 'a',
        'role': 'hub',
        'context': {'tokens': 'many', 'window': 272000},
      }),
    );
    rejects(
      'context tokens is missing',
      payloadOf({
        'name': 'a',
        'role': 'hub',
        'context': {'window': 272000},
      }),
    );

    test('an absent context is not the same as a null one', () {
      expect(
        () => parse(payloadOf({'name': 'a', 'role': 'hub'})),
        throwsFormatException,
      );
      expect(
        parse(
          payloadOf({'name': 'a', 'role': 'hub', 'context': null}),
        ).terminals.single.context,
        isNull,
      );
    });

    test('an absent tokens is not the same as a null one', () {
      expect(
        () => parse(
          payloadOf({
            'name': 'a',
            'role': 'hub',
            'context': {'window': 272000},
          }),
        ),
        throwsFormatException,
      );
      expect(
        parse(
          payloadOf({
            'name': 'a',
            'role': 'hub',
            'context': {'tokens': null, 'window': 272000},
          }),
        ).terminals.single.context?.tokens,
        isNull,
      );
    });

    test('unknown fields are ignored, at every level', () {
      final online = parse({
        'hub': 'a@pi-link',
        'port': 9900,
        'protocol': 5,
        'terminals': [
          {
            'name': 'a@pi-link',
            'role': 'hub',
            'status': 'idle',
            'sinceSeconds': 5,
            'model': 'opus',
            'context': {'tokens': 10, 'window': 100, 'cached': 4},
          },
        ],
      });
      expect(online.terminals.single.status, 'idle');
      expect(online.terminals.single.context?.window, 100);
    });
  });

  group('numbers a Dart int cannot hold', () {
    /// Builds a payload around one raw JSON number, decoded for real.
    Object decodedWith(String sinceSeconds, String tokens, String window) =>
        jsonDecode('''
{
  "hub": "a@pi-link",
  "port": 9900,
  "terminals": [
    { "name": "a@pi-link", "role": "hub", "status": "idle",
      "sinceSeconds": $sinceSeconds,
      "context": { "tokens": $tokens, "window": $window } }
  ]
}
''');

    test('integral doubles are accepted and stored as ints', () {
      // jsonDecode yields a double here, not an int: the contract says number.
      expect(jsonDecode('272000.0'), isA<double>());
      final terminal = parse(
        decodedWith('5.0', '92000.0', '272000.0'),
      ).terminals.single;
      expect(terminal.sinceSeconds, 5);
      expect(terminal.context?.tokens, 92000);
      expect(terminal.context?.window, 272000);
      expect(formatContext(terminal.context), '92K/272K (34%)');
    });

    test('fractions truncate, the disclosed bounded difference', () {
      final terminal = parse(
        decodedWith('5.9', '92000.7', '272000.4'),
      ).terminals.single;
      expect(terminal.sinceSeconds, 5);
      expect(terminal.context?.tokens, 92000);
      expect(terminal.context?.window, 272000);
    });

    test('non-finite is a FormatException, not an UnsupportedError', () {
      // 1e400 decodes as double.infinity, whose toInt() throws.
      expect(jsonDecode('1e400'), double.infinity);
      expect(
        () => parse(decodedWith('1e400', '1', '1')),
        throwsFormatException,
      );
      expect(
        () => parse(decodedWith('1', '1e400', '1')),
        throwsFormatException,
      );
      expect(
        () => parse(decodedWith('1', '1', '1e400')),
        throwsFormatException,
      );
      expect(
        () => parse(decodedWith('-1e400', '1', '1')),
        throwsFormatException,
      );
    });

    test('out of int range is rejected instead of clamping', () {
      // 1e300.toInt() would silently become the maximum int.
      expect(
        () => parse(decodedWith('1e300', '1', '1')),
        throwsFormatException,
      );
      expect(
        () => parse(decodedWith('1', '1e300', '1')),
        throwsFormatException,
      );
      expect(
        () => parse(decodedWith('1', '1', '1e300')),
        throwsFormatException,
      );
    });
  });

  group('formatTokens', () {
    test('rounds thousands and keeps one decimal for millions', () {
      expect(formatTokens(92000), '92K');
      expect(formatTokens(272000), '272K');
      expect(formatTokens(1300000), '1.3M');
      expect(formatTokens(2000000), '2.0M');
      expect(formatTokens(999), '999');
    });

    test('boundaries', () {
      expect(formatTokens(0), '0');
      expect(formatTokens(1000), '1K');
      expect(formatTokens(999999), '1000K');
    });
  });

  group('formatContext', () {
    test('percent is rounded', () {
      expect(
        formatContext(const ContextUsage(tokens: 92000, window: 272000)),
        '92K/272K (34%)',
      );
      expect(
        formatContext(const ContextUsage(tokens: 1300000, window: 2000000)),
        '1.3M/2.0M (65%)',
      );
    });

    test('unknown when there is no snapshot or no usable window', () {
      expect(formatContext(null), '?');
      expect(formatContext(const ContextUsage(tokens: 10, window: 0)), '?');
    });
  });

  group('formatDuration', () {
    test('seconds, minutes, hours', () {
      expect(formatDuration(12), '12s');
      expect(formatDuration(420), '7m');
      expect(formatDuration(7200), '2h');
    });

    test('boundaries truncate, never round up', () {
      expect(formatDuration(0), '0s');
      expect(formatDuration(59), '59s');
      expect(formatDuration(60), '1m');
      expect(formatDuration(3599), '59m');
      expect(formatDuration(3600), '1h');
    });
  });

  group('ageSeconds', () {
    test('adds the time since the response arrived', () {
      final now = receivedAt.add(const Duration(seconds: 5));
      final online = parse(
        payloadOf({
          'name': 'a@pi-link',
          'role': 'hub',
          'context': null,
          'status': 'idle',
          'sinceSeconds': 10,
        }),
      );
      expect(online.terminals.single.ageSeconds(receivedAt, now), 15);
    });

    test('stays absent when the status is unknown', () {
      final online = parse(payloadWith([null]));
      final now = receivedAt.add(const Duration(hours: 1));
      expect(online.terminals.single.ageSeconds(receivedAt, now), isNull);
    });
  });

  group('shortenHome', () {
    test('replaces the home prefix across separator styles', () {
      expect(
        shortenHome('C:/Users/andre/my-project', r'C:\Users\andre'),
        '~/my-project',
      );
      expect(
        shortenHome(r'C:\Users\andre\my-project', 'C:/Users/andre'),
        '~/my-project',
      );
      expect(
        shortenHome('/home/andre/my-project', '/home/andre'),
        '~/my-project',
      );
    });

    test('the home itself is just ~', () {
      expect(shortenHome('/home/andre', '/home/andre'), '~');
      expect(shortenHome(r'C:\Users\andre\', r'C:\Users\andre'), '~');
    });

    test('Windows paths compare without case, POSIX paths do not', () {
      expect(
        shortenHome('C:/USERS/Andre/project', r'c:\users\andre'),
        '~/project',
      );
      expect(shortenHome(r'C:\Users\Andre', r'c:\users\andre'), '~');
      expect(shortenHome('/home/ANDRE/x', '/home/andre'), '/home/ANDRE/x');
    });

    test('only matches on a directory boundary', () {
      expect(shortenHome('/home/andrew/x', '/home/andre'), '/home/andrew/x');
      expect(
        shortenHome('/home/andre-old/x', '/home/andre'),
        '/home/andre-old/x',
      );
    });

    test('leaves unrelated paths alone', () {
      expect(shortenHome('/opt/tools', '/home/andre'), '/opt/tools');
      expect(shortenHome('relative/path', '/home/andre'), 'relative/path');
    });

    test('an unknown home shortens nothing', () {
      expect(shortenHome('/home/andre/x', ''), '/home/andre/x');
    });
  });
}
