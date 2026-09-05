import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'link_status.dart';

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
    final theme = Theme.of(context);
    return GestureDetector(
      // Opaque so the padding and the gaps between rows hide the window too;
      // a scroll or a drag is a different gesture and never reaches onTap.
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: Material(
        color: theme.colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: ValueListenableBuilder<LinkStatus>(
            valueListenable: widget.status,
            builder: (context, status, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _header(theme, status),
                const SizedBox(height: 8),
                Expanded(child: _body(theme, status)),
                const SizedBox(height: 4),
                Text(
                  'Click para ocultar',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, LinkStatus status) {
    final small = theme.textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The scope matters: a terminal from another project also counts.
        Text(
          'Toda la red pi-link',
          style: theme.textTheme.titleSmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (status is Online)
          Text(
            '${status.hub} · ${status.terminals.length} online',
            style: small,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        // Current state, not a memory: it disappears as soon as work resumes.
        if (status.fleet == FleetState.idle)
          Text(
            'Todos los agentes están idle',
            style: small?.copyWith(color: Colors.green.shade400),
          ),
        ValueListenableBuilder<DateTime?>(
          valueListenable: widget.lastAllIdle,
          builder: (context, last, _) => Text(
            'Última vez todos idle: ${last == null ? '—' : _hhmm(last)}',
            style: small?.copyWith(
              color: theme.hintColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        if (widget.muted)
          Text(
            'Alertas silenciadas',
            style: small?.copyWith(color: Colors.amber.shade400),
          ),
      ],
    );
  }

  Widget _body(ThemeData theme, LinkStatus status) => switch (status) {
    NoHub() => _explanation(
      theme,
      'No hay hub en :9900. Si acabas de cerrar el hub, un cliente se '
      'promociona en 2–5 s.',
    ),
    Unsupported() => _explanation(
      theme,
      'El hub responde pero no soporta /status — actualiza pi-link y '
      'reinicia los terminales.',
    ),
    Online(:final terminals, :final receivedAt) => ListView.builder(
      // Ten terminals do not fit in 320 px, so the list is the only part that
      // scrolls; header and footer stay put.
      padding: EdgeInsets.zero,
      itemCount: terminals.length,
      itemBuilder: (context, i) => _terminal(theme, terminals[i], receivedAt),
    ),
  };

  Widget _explanation(ThemeData theme, String text) =>
      Text(text, style: theme.textTheme.bodySmall);

  Widget _terminal(ThemeData theme, Terminal terminal, DateTime receivedAt) {
    final age = terminal.ageSeconds(receivedAt, _now);
    final state = age == null
        ? terminal.statusLabel
        : '${terminal.statusLabel} (${formatDuration(age)})';
    final numbers = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Wrap, not Row: a long name or a large text scale moves the context
          // to the next line instead of overflowing.
          Wrap(
            spacing: 10,
            runSpacing: 1,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              Text(terminal.name, style: theme.textTheme.bodyMedium),
              Text(state, style: numbers),
              Text(
                formatContext(terminal.context),
                style: numbers?.copyWith(color: theme.hintColor),
              ),
            ],
          ),
          Text(
            shortenHome(terminal.cwd ?? '?', _home),
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// Local time, zero padded. No `intl` for two numbers.
String _hhmm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
