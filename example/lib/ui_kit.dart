import 'package:flutter/material.dart';

import 'route_totals.dart';

/// A figure over its label: "1.49 km" over "Distance", with an optional
/// [note] below ("recorded 1.78 km").
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.value,
    required this.label,
    this.icon,
    this.note,
    this.large = false,
  });

  final String value;
  final String label;
  final IconData? icon;
  final String? note;

  /// Whether [value] is the screen's main figure.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              (large ? theme.textTheme.titleLarge : theme.textTheme.titleSmall)
                  ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Row(
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 12, color: colors.onSurfaceVariant),
              const SizedBox(width: 3),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: muted,
              ),
            ),
          ],
        ),
        if (note != null)
          Text(
            note!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: muted,
          ),
      ],
    );
  }
}

/// [children] in rows of [columns] equal cells.
class StatGrid extends StatelessWidget {
  const StatGrid({
    super.key,
    required this.children,
    this.columns = 4,
    this.spacing = 12,
    this.runSpacing,
  });

  final List<Widget> children;
  final int columns;

  /// Space between columns.
  final double spacing;

  /// Space between rows; [spacing] when null.
  final double? runSpacing;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var start = 0; start < children.length; start += columns) {
      final cells = children.skip(start).take(columns).toList();
      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (var index = 0; index < columns; index += 1) ...<Widget>[
              if (index > 0) SizedBox(width: spacing),
              Expanded(
                child: index < cells.length
                    ? cells[index]
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final (index, row) in rows.indexed) ...<Widget>[
          if (index > 0) SizedBox(height: runSpacing ?? spacing),
          row,
        ],
      ],
    );
  }
}

/// A coloured status word with a dot: "● Tracking".
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    ),
  );
}

/// A small uppercase heading, with an optional [trailing] widget.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.1,
              ),
            ),
          ),
          if (trailing case final trailing?) Flexible(child: trailing),
        ],
      ),
    );
  }
}

/// A preference showing its current [value]; tapping it changes it.
class PreferenceTile extends StatelessWidget {
  const PreferenceTile({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;

  /// Null while the preference is locked.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final enabled = onTap != null;
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: <Widget>[
              Icon(
                icon,
                size: 20,
                color: enabled ? colors.primary : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: enabled ? null : colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                enabled ? Icons.expand_more_rounded : Icons.lock_outline,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Asks for one of [values] in a bottom sheet, [selected] marked; null when
/// dismissed.
Future<T?> showPreferencePicker<T>({
  required BuildContext context,
  required String title,
  String? description,
  required List<T> values,
  required T selected,
  required String Function(T value) labelOf,
  String? Function(T value)? detailOf,
}) => showModalBottomSheet<T>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (description != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            for (final value in values)
              ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                selected: value == selected,
                leading: Icon(
                  value == selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(labelOf(value)),
                subtitle: switch (detailOf?.call(value)) {
                  final detail? => Text(detail),
                  null => null,
                },
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    );
  },
);

/// A recorded route or Trip in the history list: its name and status, when
/// it was recorded, its main figures and quieter [details].
class RouteHistoryCard extends StatelessWidget {
  const RouteHistoryCard({
    super.key,
    required this.title,
    required this.statusLabel,
    required this.statusColor,
    required this.when,
    required this.stats,
    required this.menu,
    this.details = const <String>[],
    this.onTap,
  });

  final String title;
  final String statusLabel;
  final Color statusColor;

  /// When it was recorded: "24 Oct · 02:00–03:00".
  final String when;
  final List<Widget> stats;
  final List<String> details;
  final Widget menu;

  /// Opens the map; null when there is nothing to draw.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  StatusPill(label: statusLabel, color: statusColor),
                  menu,
                ],
              ),
              Text(
                when,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: StatGrid(columns: 3, children: stats),
              ),
              for (final detail in details)
                Padding(
                  padding: const EdgeInsets.only(top: 8, right: 12),
                  child: Text(
                    detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A history card's figures: the distance it shows ([distanceMeters], the
/// corrected one once reviewed) and, with stored [totals], the time moving
/// and the time stopped at its stops.
List<Widget> routeHistoryStats(double distanceMeters, RouteTotals? totals) =>
    <Widget>[
      StatTile(
        value: kilometres(distanceMeters),
        label: 'Distance',
        icon: Icons.straighten_rounded,
      ),
      if (totals != null) ...<Widget>[
        StatTile(
          value: hoursMinutes(totals.moving),
          label: 'Moving',
          icon: Icons.timer_outlined,
        ),
        StatTile(
          value: hoursMinutes(totals.stopped),
          label: switch (totals.stopCount) {
            0 => 'No stops',
            1 => '1 stop',
            final count => '$count stops',
          },
          icon: Icons.local_parking_rounded,
        ),
      ],
    ];

/// A history card's quieter lines: the steps and, with [showDiagnostics],
/// the quality events and visible gaps.
List<String> routeHistoryDetails(
  RouteTotals? totals, {
  required bool showDiagnostics,
}) => <String>[
  ?totals?.stepsText,
  if (totals != null && showDiagnostics)
    '${totals.qualityEventCount} quality event(s) • '
        '${totals.visibleGapCount} visible gap(s)',
];

/// A history overflow-menu entry; [destructive] ones are drawn in red.
PopupMenuItem<T> historyMenuItem<T>(
  T action,
  IconData icon,
  String label,
  bool enabled, {
  bool destructive = false,
}) => PopupMenuItem<T>(
  value: action,
  enabled: enabled,
  child: Row(
    children: <Widget>[
      Icon(icon, color: destructive ? Colors.red : null),
      const SizedBox(width: 12),
      Flexible(
        child: Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: destructive ? const TextStyle(color: Colors.red) : null,
        ),
      ),
    ],
  ),
);

/// The history list's message when nothing is recorded yet.
class EmptyHistory extends StatelessWidget {
  const EmptyHistory({super.key, required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
      child: Column(
        children: <Widget>[
          CircleAvatar(
            radius: 32,
            backgroundColor: colors.primaryContainer,
            foregroundColor: colors.onPrimaryContainer,
            child: const Icon(Icons.route_outlined, size: 32),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
