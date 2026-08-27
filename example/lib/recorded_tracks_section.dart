import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';

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
    required this.onRefresh,
    required this.onLoadMore,
    required this.onViewMap,
    required this.onExport,
    required this.onDelete,
  });

  final List<Track> tracks;
  final bool hasMore;
  final Future<void> Function()? onRefresh;
  final Future<void> Function()? onLoadMore;
  final Future<void> Function(Track track)? onViewMap;
  final Future<void> Function(String trackId, TrackExportFormat format)?
  onExport;
  final Future<void> Function(Track track)? onDelete;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Row(
        children: <Widget>[
          Text(
            'Recorded routes',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Spacer(),
          IconButton(
            tooltip: 'Refresh routes',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      if (tracks.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('No routes have been recorded for this owner.'),
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
    return Card(
      child: ListTile(
        title: Text(track.routeId ?? track.id),
        subtitle: Text(
          '${track.status.name} • ${track.acceptedPointCount} points • '
          '${(track.totalDistanceMeters / 1000).toStringAsFixed(2)} km • '
          '${track.segmentCount} segment(s)',
        ),
        trailing: PopupMenuButton<RecordedTrackAction>(
          tooltip: 'Route actions',
          onSelected: (action) => _perform(action, track),
          itemBuilder: (context) => <PopupMenuEntry<RecordedTrackAction>>[
            _item(
              RecordedTrackAction.exportGeoJson,
              Icons.data_object,
              'Export GeoJSON',
              actions.canExport && onExport != null,
            ),
            _item(
              RecordedTrackAction.exportKml,
              Icons.language,
              'Export KML',
              actions.canExport && onExport != null,
            ),
            _item(
              RecordedTrackAction.exportGpx,
              Icons.route,
              'Export GPX',
              actions.canExport && onExport != null,
            ),
            _item(
              RecordedTrackAction.viewMap,
              Icons.map_outlined,
              'View on map',
              actions.canView && onViewMap != null,
            ),
            const PopupMenuDivider(),
            _item(
              RecordedTrackAction.delete,
              Icons.delete_outline,
              'Delete',
              actions.canDelete && onDelete != null,
              destructive: true,
            ),
          ],
        ),
      ),
    );
  }

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

  static PopupMenuItem<RecordedTrackAction> _item(
    RecordedTrackAction action,
    IconData icon,
    String label,
    bool enabled, {
    bool destructive = false,
  }) => PopupMenuItem<RecordedTrackAction>(
    value: action,
    enabled: enabled,
    child: Row(
      children: <Widget>[
        Icon(icon, color: destructive ? Colors.red : null),
        const SizedBox(width: 12),
        Text(
          label,
          style: destructive ? const TextStyle(color: Colors.red) : null,
        ),
      ],
    ),
  );
}
