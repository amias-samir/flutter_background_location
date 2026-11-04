import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';

import 'recorded_trips_section.dart';
import 'route_totals.dart';

/// The loaded history the home page keeps: Trips when the facade records
/// multi-day Trips, else routes.
final class RecordedHistory {
  const RecordedHistory({
    this.tripMode = false,
    this.trips = const <RecordedTripSummary>[],
    this.tracks = const <Track>[],
    this.totals = const <String, RouteTotals>{},
    this.hasMore = false,
    this.busy = false,
  });

  final bool tripMode;
  final List<RecordedTripSummary> trips;
  final List<Track> tracks;

  /// Stored totals of [tracks], by track ID.
  final Map<String, RouteTotals> totals;
  final bool hasMore;

  /// Whether a command runs; actions wait for it.
  final bool busy;

  String get title => tripMode ? 'Recorded Trips' : 'Recorded routes';

  /// How many are loaded, "25+" when more are stored.
  String get countLabel {
    final count = tripMode ? trips.length : tracks.length;
    return hasMore ? '$count+' : '$count';
  }

  /// The newest one's name; null when nothing is recorded.
  String? get latestName => tripMode
      ? switch (trips) {
          [final first, ...] => first.trip.routeId ?? first.trip.id,
          _ => null,
        }
      : switch (tracks) {
          [final first, ...] => first.routeId ?? first.id,
          _ => null,
        };

  RecordedHistory copyWith({
    bool? tripMode,
    List<RecordedTripSummary>? trips,
    List<Track>? tracks,
    Map<String, RouteTotals>? totals,
    bool? hasMore,
    bool? busy,
  }) => RecordedHistory(
    tripMode: tripMode ?? this.tripMode,
    trips: trips ?? this.trips,
    tracks: tracks ?? this.tracks,
    totals: totals ?? this.totals,
    hasMore: hasMore ?? this.hasMore,
    busy: busy ?? this.busy,
  );
}

/// The home page's way into the history: its count and newest entry.
class RecordedHistoryTile extends StatelessWidget {
  const RecordedHistoryTile({
    super.key,
    required this.history,
    required this.onTap,
  });

  final RecordedHistory history;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final latest = history.latestName;
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                radius: 18,
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.onPrimaryContainer,
                child: Icon(
                  history.tripMode
                      ? Icons.hiking_rounded
                      : Icons.history_rounded,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '${history.title} · ${history.countLabel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      latest == null
                          ? 'Nothing recorded yet'
                          : 'Latest: $latest',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// The recorded Trips or routes on their own screen; [listBuilder] draws
/// them from the home page's current [history].
class RecordedHistoryPage extends StatelessWidget {
  const RecordedHistoryPage({
    super.key,
    required this.history,
    required this.onRefresh,
    required this.listBuilder,
  });

  final ValueListenable<RecordedHistory> history;
  final Future<void> Function() onRefresh;
  final Widget Function(BuildContext context, RecordedHistory history)
  listBuilder;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<RecordedHistory>(
    valueListenable: history,
    builder: (context, value, _) => Scaffold(
      appBar: AppBar(
        title: Text(value.title),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh',
            onPressed: value.busy ? null : onRefresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: value.busy
              ? const LinearProgressIndicator(minHeight: 2)
              : const SizedBox(height: 2),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: RefreshIndicator(
              onRefresh: onRefresh,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                physics: const AlwaysScrollableScrollPhysics(),
                children: <Widget>[listBuilder(context, value)],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
