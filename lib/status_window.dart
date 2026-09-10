import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'link_status.dart';

/// The panel's own background. The app theme paints the same colour, so no
/// lighter surface can show through before the panel is laid out.
const graphiteSurface = Color(0xFF1B1B1F);

/// Graphite palette. Final colours, no alpha, so contrast against
/// [graphiteSurface] is what was measured on the approved design: every
/// informative text is at or above 4.5:1, and the scrollbar thumb — the only
/// non-text element that has to be noticed — is 3.25:1.
const _border = Color(0xFF34343A);
const _hairline = Color(0xFF2A2A2F);
const _foreground = Color(0xFFF2EFEA); // names
const _meta = Color(0xFFACA9A4); // state, age, context, scope, history
const _pathColour = Color(0xFF9C9994);
const _hint = Color(0xFF8F8C88); // 'Click or Esc to hide'
const _thumb = Color(0xFF6B6B72);
const _idle = Color(0xFF81C784);
const _busy = Color(0xFF64B5F6);
const _compacting = Color(0xFFFFD54F);
const _grey = Color(
  0xFF9E9E9E,
); // offline, and any status this version cannot read

/// Text styles are stated here rather than derived from the theme: the panel is
/// a single fixed-size instrument, and reading its scale off a Material text
/// theme would only hide the numbers the design was measured with.
const _titleStyle = TextStyle(
  fontSize: 15,
  height: 20 / 15,
  fontWeight: FontWeight.w600,
);
const _metaStyle = TextStyle(fontSize: 12, height: 16 / 12, color: _meta);
const _nameStyle = TextStyle(
  fontSize: 14,
  height: 18 / 14,
  fontWeight: FontWeight.w600,
  color: _foreground,
);
// The @suffix stays legible but stops competing with the name it qualifies.
const _suffixStyle = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w400,
  color: _meta,
);
const _hubStyle = TextStyle(fontSize: 12, color: _meta, letterSpacing: 0.4);
// Ages, token counts and the historical time are the only numbers that must
// line up between rows, so they are the styles carrying tabular figures.
const _railStyle = TextStyle(
  fontSize: 12,
  height: 18 / 12,
  color: _meta,
  fontFeatures: [FontFeature.tabularFigures()],
);
const _pathStyle = TextStyle(fontSize: 12, height: 16 / 12, color: _pathColour);
const _contextStyle = TextStyle(
  fontSize: 12,
  height: 16 / 12,
  color: _meta,
  fontFeatures: [FontFeature.tabularFigures()],
);
const _historyStyle = TextStyle(
  fontSize: 12,
  height: 16 / 12,
  color: _meta,
  fontFeatures: [FontFeature.tabularFigures()],
);
const _hintStyle = TextStyle(fontSize: 12, height: 16 / 12, color: _hint);

/// Height of a row's first line, and so the box the status dot centres in.
const _firstLineHeight = 18.0;

/// The dot's column: 7 px of marker plus the 8 px that separate it from the
/// text. Both lines of a row are indented by it, so a wrapped name continues
/// under the text and never under the dot.
const _markerColumn = 15.0;

/// The whole window: header, terminal list and footer.
///
/// Owns nothing but the one-second tick that keeps the ages moving. Status and
/// the historical time arrive as listenables; mute and visibility are plain
/// values the owner rebuilds with, because it already knows when they change.
class StatusView extends StatefulWidget {
  const StatusView({
    super.key,
    required this.status,
    required this.lastAllIdle,
    required this.muted,
    required this.visible,
    required this.onTap,
    this.clock = DateTime.now,
  });

  final ValueListenable<LinkStatus> status;
  final ValueListenable<DateTime?> lastAllIdle;

  /// Shows the muted notice. Alerts are suppressed by the owner, not here.
  final bool muted;

  /// Whether the window is on screen: the ages only tick while it is.
  final bool visible;

  /// Hides the window. A click anywhere counts; scrolling does not.
  final VoidCallback onTap;

  /// The clock the ages are measured against. Injected so tests can advance
  /// time deterministically, since a widget test's fake timers do not move
  /// [DateTime.now].
  @visibleForTesting
  final DateTime Function() clock;

  @override
  State<StatusView> createState() => _StatusViewState();
}

class _StatusViewState extends State<StatusView> {
  /// `~` shortening is display-only; an unset home simply shortens nothing.
  static final _home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '';

  /// Shared with the scrollbar, which is the only overflow affordance.
  final _scroll = ScrollController();

  late DateTime _now = widget.clock();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    if (widget.visible) _startTicking();
  }

  @override
  void didUpdateWidget(StatusView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _now = widget.clock(); // hidden time passed: catch up before showing
      _startTicking();
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _startTicking() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _now = widget.clock());
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LinkStatus>(
      valueListenable: widget.status,
      builder: (context, status, _) {
        // The fleet state is the loudest thing on screen: it colours the title
        // and the left edge, and nothing else in the panel is tinted.
        final accent = _accentOf(status.fleet);
        return GestureDetector(
          // Opaque so the padding and the gaps between rows hide the window
          // too; a scroll or a drag is a different gesture and never reaches
          // onTap.
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Material(
            color: graphiteSurface,
            child: Container(
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: accent, width: 3),
                  top: const BorderSide(color: _border),
                  right: const BorderSide(color: _border),
                  bottom: const BorderSide(color: _border),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: Column(
                // Stretch, so the header, footer and rows can align their
                // right-hand column against the real width.
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(status, accent),
                  Expanded(child: _body(context, status)),
                  _footer(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header(LinkStatus status, Color accent) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(_title(status), style: _titleStyle.copyWith(color: accent)),
      const SizedBox(height: 2),
      // Wrap, not Row: at a large text scale the muted notice drops to its own
      // line instead of squeezing the scope out.
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 12,
        runSpacing: 2,
        children: [
          // The scope matters: a terminal from another project also counts.
          Text(_scope(status), style: _metaStyle),
          if (widget.muted)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.notifications_off_outlined,
                  size: 13,
                  color: _meta,
                ),
                const SizedBox(width: 5),
                Text('Alerts muted', style: _metaStyle),
              ],
            ),
        ],
      ),
      const SizedBox(height: 6),
      const Divider(height: 1, thickness: 1, color: _hairline),
      const SizedBox(height: 6),
    ],
  );

  Widget _body(BuildContext context, LinkStatus status) => switch (status) {
    NoHub() => _explanation(
      'No hub on :9900. If you just closed the hub, a client promotes itself '
      'within 2–5 s.',
    ),
    Unsupported() => _explanation(
      'The hub responds but does not support /status — update pi-link and '
      'restart the terminals.',
    ),
    Online(:final terminals, :final receivedAt) => _list(terminals, receivedAt),
  };

  Widget _explanation(String text) => Text(text, style: _metaStyle);

  /// The terminals, in display order.
  Widget _list(List<Terminal> terminals, DateTime receivedAt) {
    // Recomputed from the snapshot in hand on every build, so a new roster, a
    // new activity or a new hub is on screen at once and no order outlives the
    // data it came from.
    final rows = _ordered(terminals);
    // The parser guarantees the canonical first entry is the hub and rejects a
    // payload where it is not. Holding the object, rather than a position or a
    // name, keeps the badge on that terminal wherever the sort moves it.
    final hub = terminals.first;
    return RawScrollbar(
      // Ten terminals do not fit in 320 px, so the list is the only part that
      // scrolls; header and footer stay put. The thumb is the only sign that
      // there is more, and it appears only when there is.
      controller: _scroll,
      thumbVisibility: true,
      thumbColor: _thumb,
      thickness: 3,
      radius: const Radius.circular(2),
      child: ListView.builder(
        controller: _scroll,
        // Room for the thumb, so it never sits on top of an age.
        padding: const EdgeInsets.only(right: 10),
        itemCount: rows.length,
        itemBuilder: (context, i) => _terminal(
          context,
          rows[i],
          receivedAt,
          isHub: identical(rows[i], hub),
        ),
      ),
    );
  }

  Widget _terminal(
    BuildContext context,
    Terminal terminal,
    DateTime receivedAt, {
    required bool isHub,
  }) {
    final age = terminal.ageSeconds(receivedAt, _now);
    // An unrecognised word keeps its age: status and sinceSeconds arrive
    // together or not at all, so only the absent status ('?') has none.
    final state = age == null
        ? terminal.statusLabel
        : '${terminal.statusLabel} ${formatDuration(age)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: _markerColumn,
            // Scaled, so the dot stays on the middle of the first line when
            // the user enlarges text.
            height: MediaQuery.textScalerOf(context).scale(_firstLineHeight),
            child: Center(child: _StatusDot(terminal.status)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Wrap, not Row: a long name, a long status or a large text
                // scale moves the right-hand text to the next line instead of
                // clipping either of them.
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 12,
                  runSpacing: 1,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _name(terminal, isHub: isHub),
                    Text(state, style: _railStyle, textAlign: TextAlign.right),
                  ],
                ),
                const SizedBox(height: 1),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The path is the one text that ellipsises: it is the only
                    // one long enough to push the context off the row, and its
                    // tail is the part that identifies the directory.
                    Expanded(
                      child: Text(
                        shortenHome(terminal.cwd ?? '?', _home),
                        style: _pathStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(formatContext(terminal.context), style: _contextStyle),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The full identity, with the `@suffix` de-emphasised and the hub marked on
  /// its own row. One paragraph, so a long name wraps as one text.
  Widget _name(Terminal terminal, {required bool isHub}) {
    final at = terminal.name.indexOf('@');
    final base = at < 0 ? terminal.name : terminal.name.substring(0, at);
    return Text.rich(
      TextSpan(
        style: _nameStyle,
        children: [
          TextSpan(text: base),
          if (at >= 0)
            TextSpan(text: terminal.name.substring(at), style: _suffixStyle),
          if (isHub) const TextSpan(text: '  hub', style: _hubStyle),
        ],
      ),
    );
  }

  Widget _footer() => Container(
    margin: const EdgeInsets.only(top: 6),
    padding: const EdgeInsets.only(top: 6),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: _hairline)),
    ),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      spacing: 12,
      runSpacing: 2,
      children: [
        ValueListenableBuilder<DateTime?>(
          valueListenable: widget.lastAllIdle,
          builder: (context, last, _) => Text(
            'Last all idle: ${last == null ? '—' : _hhmm(last)}',
            style: _historyStyle,
          ),
        ),
        const Text('Click or Esc to hide', style: _hintStyle),
      ],
    ),
  );
}

/// Filled for a state this version knows, a hollow ring for one it does not.
class _StatusDot extends StatelessWidget {
  const _StatusDot(this.status);

  final String? status;

  @override
  Widget build(BuildContext context) {
    final colour = _colourOf(status);
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colour,
        border: colour == null ? Border.all(color: _grey, width: 1.5) : null,
      ),
    );
  }

  /// `null` means unknown, which is drawn rather than coloured.
  static Color? _colourOf(String? status) => switch (_activityOf(status)) {
    _Activity.working => _busy,
    _Activity.compacting => _compacting,
    _Activity.idle => _idle,
    _Activity.unknown => null,
  };
}

/// What a terminal is doing, in the order the panel lists the rows: the ones
/// working now first, the ones nothing is known about last.
enum _Activity { working, compacting, idle, unknown }

/// The one place this file reads a raw status word. The vocabulary is the
/// model's own — `thinking`, `tool:*`, `compacting`, `idle`, and anything else
/// is a word this version does not know.
_Activity _activityOf(String? status) => switch (status) {
  'thinking' => _Activity.working,
  final status? when status.startsWith('tool:') => _Activity.working,
  'compacting' => _Activity.compacting,
  'idle' => _Activity.idle,
  _ => _Activity.unknown,
};

/// The rows, most active first and, within the same activity, whichever
/// changed state most recently.
///
/// Returns a new list. [terminals] is the canonical roster the poller, the
/// alert and the tray read from the same snapshot, and reordering it here
/// would quietly change what the hub said.
List<Terminal> _ordered(List<Terminal> terminals) {
  // Positions are sorted rather than the terminals themselves, so the roster
  // index survives as the last comparison: Dart's sort is not stable, and rows
  // that tie must stay in the order the hub sent them.
  final positions = [for (var i = 0; i < terminals.length; i++) i];
  positions.sort((a, b) {
    final left = terminals[a];
    final right = terminals[b];
    final byActivity = _activityOf(
      left.status,
    ).index.compareTo(_activityOf(right.status).index);
    // Activity always wins: a terminal that started working an hour ago is
    // still ahead of one that went idle a second ago.
    if (byActivity != 0) return byActivity;
    final byAge = _compareAges(left.sinceSeconds, right.sinceSeconds);
    if (byAge != 0) return byAge;
    return a.compareTo(b);
  });
  return [for (final position in positions) terminals[position]];
}

/// Ascending, with an unknown age last.
///
/// These are the raw seconds from the payload, not the ages on screen: every
/// row of one snapshot ages by the same amount, so the two orders are
/// identical and this one does not move while the clock ticks.
int _compareAges(int? a, int? b) {
  if (a == null) return b == null ? 0 : 1;
  if (b == null) return -1;
  return a.compareTo(b);
}

/// The fleet state leads the panel, so it is the title.
String _title(LinkStatus status) => switch (status) {
  NoHub() => 'No hub on :9900',
  Unsupported() => 'Outdated hub · update pi-link',
  Online(:final terminals) => _fleetTitle(terminals),
};

/// `2 working · 4 idle`, or the whole sentence when there is nothing to do.
/// Every terminal is counted exactly once, so the parts always add up to the
/// online count. Idle is a current state, never a finished task.
String _fleetTitle(List<Terminal> terminals) {
  var working = 0;
  var compacting = 0;
  var unknown = 0;
  var idle = 0;
  for (final terminal in terminals) {
    switch (_activityOf(terminal.status)) {
      case _Activity.working:
        working++;
      case _Activity.compacting:
        compacting++;
      case _Activity.idle:
        idle++;
      case _Activity.unknown:
        unknown++;
    }
  }
  if (idle == terminals.length) return 'All agents are idle';
  // Listed in the order the title has always read them, which is not the order
  // the rows are sorted in: the rows put the unknown last, the title keeps
  // idle — the reassuring number — at the end.
  return [
    if (working > 0) '$working working',
    if (compacting > 0) '$compacting compacting',
    if (unknown > 0) '$unknown unknown',
    if (idle > 0) '$idle idle',
  ].join(' · ');
}

/// What is being watched, and how much of it answered.
String _scope(LinkStatus status) {
  final detail = switch (status) {
    NoHub() => 'disconnected',
    Unsupported() => 'no /status',
    Online(:final terminals) => '${terminals.length} online',
  };
  return 'Entire pi-link network · $detail';
}

Color _accentOf(FleetState fleet) => switch (fleet) {
  FleetState.offline || FleetState.unknown => _grey,
  FleetState.compacting => _compacting,
  FleetState.busy => _busy,
  FleetState.idle => _idle,
};

/// Local time, zero padded. No `intl` for two numbers.
String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
