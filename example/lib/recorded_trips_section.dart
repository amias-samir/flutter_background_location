import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';

final class RecordedTripSummary {
  const RecordedTripSummary({
    required this.trip,
    required this.segmentCount,
    required this.gapCount,
  });

  final Trip trip;
  final int segmentCount;
  final int gapCount;
}

enum RecordedTripAction {
  exportGeoJson,
  exportKml,
  exportGpx,
  viewMap,
  continueTrip,
  delete,
}

class RecordedTripsSection extends StatelessWidget {
  const RecordedTripsSection({
    super.key,
    required this.trips,
    required this.hasMore,
    required this.onRefresh,
    required this.onLoadMore,
    required this.onViewMap,
    required this.onContinue,
    required this.onExport,
    required this.onDelete,
  });

  final List<RecordedTripSummary> trips;
  final bool hasMore;
  final Future<void> Function()? onRefresh;
  final Future<void> Function()? onLoadMore;
  final Future<void> Function(Trip trip)? onViewMap;
  final Future<void> Function(Trip trip)? onContinue;
  final Future<void> Function(String tripId, TrackExportFormat format)?
  onExport;
  final Future<void> Function(Trip trip)? onDelete;

  @override
  Widget build(BuildContext context) => Card(
    elevation: 0,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(
              children: <Widget>[
                Icon(
                  Icons.hiking_rounded,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Recorded Trips',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${trips.length} journey${trips.length == 1 ? '' : 's'} loaded',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh Trips',
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (trips.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Column(
                children: <Widget>[
                  Icon(Icons.route_outlined, size: 36),
                  SizedBox(height: 8),
                  Text('No Trips recorded yet'),
                  SizedBox(height: 2),
                  Text('Start tracking to create your first multi-day Trip.'),
                ],
              ),
            )
          else
            ...trips.map((summary) => _tripCard(context, summary)),
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

  Widget _tripCard(BuildContext context, RecordedTripSummary summary) {
    final trip = summary.trip;
    final colors = Theme.of(context).colorScheme;
    final statusColor = switch (trip.status) {
      TripStatus.active => colors.primary,
      TripStatus.suspended => colors.tertiary,
      TripStatus.completed => const Color(0xFF2E7D32),
      TripStatus.failed => colors.error,
    };
    final canExport = trip.status == TripStatus.completed;
    final canContinue = trip.isContinuable;
    final canDelete = trip.status != TripStatus.active;
    return Card.outlined(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        leading: CircleAvatar(
          backgroundColor: statusColor.withValues(alpha: 0.14),
          foregroundColor: statusColor,
          child: Icon(_statusIcon(trip.status)),
        ),
        title: Text(
          trip.routeId ?? trip.id,
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
              _TripDetail(
                icon: Icons.circle,
                label: trip.status.name,
                color: statusColor,
              ),
              _TripDetail(
                icon: Icons.calendar_view_day,
                label: '${trip.legCount} day(s)',
              ),
              _TripDetail(
                icon: Icons.pin_drop_outlined,
                label: '${trip.acceptedPointCount} points',
              ),
              _TripDetail(
                icon: Icons.straighten_rounded,
                label:
                    '${(trip.measuredDistanceMeters / 1000).toStringAsFixed(2)} km',
              ),
              _TripDetail(
                icon: Icons.polyline_outlined,
                label: '${summary.segmentCount} segment(s)',
              ),
              _TripDetail(
                icon: Icons.warning_amber_rounded,
                label: '${summary.gapCount} gap(s)',
              ),
            ],
          ),
        ),
        trailing: PopupMenuButton<RecordedTripAction>(
          tooltip: 'Trip actions',
          onSelected: (action) => _perform(action, trip),
          itemBuilder: (context) => <PopupMenuEntry<RecordedTripAction>>[
            _item(
              RecordedTripAction.exportGeoJson,
              Icons.data_object,
              'Export GeoJSON',
              canExport && onExport != null,
            ),
            _item(
              RecordedTripAction.exportKml,
              Icons.language,
              'Export KML',
              canExport && onExport != null,
            ),
            _item(
              RecordedTripAction.exportGpx,
              Icons.route,
              'Export GPX',
              canExport && onExport != null,
            ),
            _item(
              RecordedTripAction.viewMap,
              Icons.map_outlined,
              'View all days on map',
              trip.acceptedPointCount > 0 && onViewMap != null,
            ),
            _item(
              RecordedTripAction.continueTrip,
              Icons.add_road_rounded,
              trip.status == TripStatus.completed
                  ? 'Continue completed Trip'
                  : 'Start next day',
              canContinue && onContinue != null,
            ),
            const PopupMenuDivider(),
            _item(
              RecordedTripAction.delete,
              Icons.delete_outline,
              'Delete Trip',
              canDelete && onDelete != null,
              destructive: true,
            ),
          ],
        ),
      ),
    );
  }

  static IconData _statusIcon(TripStatus status) => switch (status) {
    TripStatus.active => Icons.navigation_rounded,
    TripStatus.suspended => Icons.nightlight_round,
    TripStatus.completed => Icons.flag_rounded,
    TripStatus.failed => Icons.error_outline,
  };

  void _perform(RecordedTripAction action, Trip trip) {
    switch (action) {
      case RecordedTripAction.exportGeoJson:
        unawaited(onExport?.call(trip.id, TrackExportFormat.geoJson));
      case RecordedTripAction.exportKml:
        unawaited(onExport?.call(trip.id, TrackExportFormat.kml));
      case RecordedTripAction.exportGpx:
        unawaited(onExport?.call(trip.id, TrackExportFormat.gpx));
      case RecordedTripAction.viewMap:
        unawaited(onViewMap?.call(trip));
      case RecordedTripAction.continueTrip:
        unawaited(onContinue?.call(trip));
      case RecordedTripAction.delete:
        unawaited(onDelete?.call(trip));
    }
  }

  static PopupMenuItem<RecordedTripAction> _item(
    RecordedTripAction action,
    IconData icon,
    String label,
    bool enabled, {
    bool destructive = false,
  }) => PopupMenuItem<RecordedTripAction>(
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
}

class _TripDetail extends StatelessWidget {
  const _TripDetail({required this.icon, required this.label, this.color});

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
