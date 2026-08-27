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
  Widget build(BuildContext context) => Card(
    elevation: 0,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.history_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Recorded routes',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${tracks.length} route${tracks.length == 1 ? '' : 's'} loaded',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh routes',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (tracks.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: <Widget>[
                  Icon(
                    Icons.route_outlined,
                    size: 36,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 8),
                  const Text('No routes recorded yet'),
                  const SizedBox(height: 2),
                  Text(
                    'Start tracking to create your first route.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
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
      ),
    ),
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
    return Card.outlined(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        leading: CircleAvatar(
          backgroundColor: statusColor.withValues(alpha: 0.14),
          foregroundColor: statusColor,
          child: Icon(_statusIcon(track.status)),
        ),
        title: Text(
          track.routeId ?? track.id,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              _RouteDetail(
                icon: Icons.circle,
                label: track.status.name,
                color: statusColor,
              ),
              _RouteDetail(
                icon: Icons.pin_drop_outlined,
                label: '${track.acceptedPointCount} points',
              ),
              _RouteDetail(
                icon: Icons.straighten_rounded,
                label:
                    '${(track.totalDistanceMeters / 1000).toStringAsFixed(2)} km',
              ),
              _RouteDetail(
                icon: Icons.polyline_outlined,
                label:
                    '${track.segmentCount} segment${track.segmentCount == 1 ? '' : 's'}',
              ),
            ],
          ),
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

  static IconData _statusIcon(TrackStatus status) => switch (status) {
    TrackStatus.active => Icons.navigation_rounded,
    TrackStatus.paused => Icons.pause_rounded,
    TrackStatus.completed => Icons.check_rounded,
    TrackStatus.interrupted => Icons.portable_wifi_off_rounded,
    TrackStatus.failed => Icons.error_outline,
    TrackStatus.starting => Icons.hourglass_top_rounded,
    TrackStatus.stopping => Icons.hourglass_bottom_rounded,
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

class _RouteDetail extends StatelessWidget {
  const _RouteDetail({required this.icon, required this.label, this.color});

  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 11, color: foreground),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: foreground)),
        ],
      ),
    );
  }
}
