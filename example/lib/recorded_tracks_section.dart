import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';

import 'route_totals.dart';
import 'ui_kit.dart';

enum RecordedTrackAction {
  exportGeoJson,
  exportKml,
  exportGpx,
  viewMap,
  delete,
}

class RecordedTracksSection extends StatelessWidget {
  const RecordedTracksSection({
    super.key,
    required this.tracks,
    required this.hasMore,
    required this.onLoadMore,
    required this.onViewMap,
    required this.onExport,
    required this.onDelete,
    this.totals = const <String, RouteTotals>{},
    this.showDiagnostics = true,
  });

  final List<Track> tracks;

  /// Stored totals by track ID; a track without an entry shows none.
  final Map<String, RouteTotals> totals;

  /// Whether the cards show quality events and visible gaps.
  final bool showDiagnostics;
  final bool hasMore;
  final Future<void> Function()? onLoadMore;

  /// Opens the route's map; a tap on its card does the same.
  final Future<void> Function(Track track)? onViewMap;
  final Future<void> Function(String trackId, TrackExportFormat format)?
  onExport;
  final Future<void> Function(Track track)? onDelete;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      if (tracks.isEmpty)
        const EmptyHistory(
          title: 'No routes recorded yet',
          message: 'Start tracking to create your first route.',
        )
      else
        ...tracks.map((track) => _routeCard(context, track)),
      if (hasMore)
        Center(
          child: TextButton.icon(
            onPressed: onLoadMore,
            icon: const Icon(Icons.expand_more),
            label: const Text('Load more'),
          ),
        ),
    ],
  );

  Widget _routeCard(BuildContext context, Track track) {
    final actions = availableActionsFor(track);
    final colors = Theme.of(context).colorScheme;
    final statusColor = switch (track.status) {
      TrackStatus.active => colors.primary,
      TrackStatus.paused => colors.tertiary,
      TrackStatus.completed => const Color(0xFF2E7D32),
      TrackStatus.interrupted || TrackStatus.failed => colors.error,
      _ => colors.secondary,
    };
    final canView = actions.canView && onViewMap != null;
    final stored = totals[track.id];
    return RouteHistoryCard(
      title: track.routeId ?? track.id,
      statusLabel: _statusLabel(track.status),
      statusColor: statusColor,
      when: recordedPeriod(track.startedAt, track.endedAt),
      // The corrected distance once the route was reviewed. The point count
      // is a sampling statistic and stays on the map.
      stats: routeHistoryStats(
        stored?.displayDistanceMeters ?? track.totalDistanceMeters,
        stored,
      ),
      details: routeHistoryDetails(stored, showDiagnostics: showDiagnostics),
      onTap: canView
          ? () => _perform(RecordedTrackAction.viewMap, track)
          : null,
      menu: PopupMenuButton<RecordedTrackAction>(
        tooltip: 'Route actions',
        onSelected: (action) => _perform(action, track),
        itemBuilder: (context) => <PopupMenuEntry<RecordedTrackAction>>[
          historyMenuItem(
            RecordedTrackAction.viewMap,
            Icons.map_outlined,
            'View on map',
            canView,
          ),
          const PopupMenuDivider(),
          historyMenuItem(
            RecordedTrackAction.exportGeoJson,
            Icons.data_object,
            'Export GeoJSON',
            actions.canExport && onExport != null,
          ),
          historyMenuItem(
            RecordedTrackAction.exportKml,
            Icons.language,
            'Export KML',
            actions.canExport && onExport != null,
          ),
          historyMenuItem(
            RecordedTrackAction.exportGpx,
            Icons.route,
            'Export GPX',
            actions.canExport && onExport != null,
          ),
          const PopupMenuDivider(),
          historyMenuItem(
            RecordedTrackAction.delete,
            Icons.delete_outline,
            'Delete',
            actions.canDelete && onDelete != null,
            destructive: true,
          ),
        ],
      ),
    );
  }

  static String _statusLabel(TrackStatus status) => switch (status) {
    TrackStatus.active => 'Active',
    TrackStatus.paused => 'Paused',
    TrackStatus.completed => 'Completed',
    TrackStatus.interrupted => 'Interrupted',
    TrackStatus.failed => 'Failed',
    TrackStatus.starting => 'Starting',
    TrackStatus.stopping => 'Stopping',
  };

  void _perform(RecordedTrackAction action, Track track) {
    switch (action) {
      case RecordedTrackAction.exportGeoJson:
        unawaited(onExport?.call(track.id, TrackExportFormat.geoJson));
      case RecordedTrackAction.exportKml:
        unawaited(onExport?.call(track.id, TrackExportFormat.kml));
      case RecordedTrackAction.exportGpx:
        unawaited(onExport?.call(track.id, TrackExportFormat.gpx));
      case RecordedTrackAction.viewMap:
        unawaited(onViewMap?.call(track));
      case RecordedTrackAction.delete:
        unawaited(onDelete?.call(track));
    }
  }
}
