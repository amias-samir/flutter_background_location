import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';

import 'route_totals.dart';
import 'ui_kit.dart';

final class RecordedTripSummary {
  const RecordedTripSummary({required this.trip, this.totals});

  final Trip trip;

  /// The Trip's stored totals; null when the facade keeps none.
  final RouteTotals? totals;
}

enum RecordedTripAction {
  exportGeoJson,
  exportKml,
  exportGpx,
  exportCleanedGpx,
  exportDiagnostics,
  viewMap,
  continueTrip,
  delete,
}

class RecordedTripsSection extends StatelessWidget {
  const RecordedTripsSection({
    super.key,
    required this.trips,
    required this.hasMore,
    required this.onLoadMore,
    required this.onViewMap,
    required this.onContinue,
    required this.onExport,
    required this.onDelete,
    this.onExportDiagnostics,
    this.onExportCleaned,
    this.showDiagnostics = true,
  });

  /// Whether the cards show quality events and visible gaps and offer the
  /// diagnostic export. Off in a clean build ([RouteRecordingDetail.clean]),
  /// which records neither.
  final bool showDiagnostics;

  final List<RecordedTripSummary> trips;
  final bool hasMore;
  final Future<void> Function()? onLoadMore;

  /// Opens the Trip's map; a tap on its card does the same.
  final Future<void> Function(Trip trip)? onViewMap;
  final Future<void> Function(Trip trip)? onContinue;
  final Future<void> Function(String tripId, TrackExportFormat format)?
  onExport;
  final Future<void> Function(Trip trip)? onDelete;

  /// Exports GeoJSON with point features, rejected points and per-fix
  /// diagnostics, for explaining a field test.
  final Future<void> Function(String tripId)? onExportDiagnostics;

  /// Exports GPX of the cleaned route view, where each stop is one point.
  final Future<void> Function(Trip trip)? onExportCleaned;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      if (trips.isEmpty)
        const EmptyHistory(
          title: 'No Trips recorded yet',
          message: 'Start tracking to create your first multi-day Trip.',
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
    final canView = trip.acceptedPointCount > 0 && onViewMap != null;
    final totals = summary.totals;
    return RouteHistoryCard(
      title: trip.routeId ?? trip.id,
      statusLabel: _statusLabel(trip.status),
      statusColor: statusColor,
      when:
          '${recordedPeriod(trip.startedAt, trip.endedAt)} · '
          '${trip.legCount == 1 ? '1 day' : '${trip.legCount} days'}',
      // The corrected distance once a day was reviewed. The point count is
      // a sampling statistic and stays on the map.
      stats: routeHistoryStats(
        totals?.displayDistanceMeters ?? trip.measuredDistanceMeters,
        totals,
      ),
      details: routeHistoryDetails(totals, showDiagnostics: showDiagnostics),
      onTap: canView ? () => _perform(RecordedTripAction.viewMap, trip) : null,
      menu: PopupMenuButton<RecordedTripAction>(
        tooltip: 'Trip actions',
        onSelected: (action) => _perform(action, trip),
        itemBuilder: (context) => <PopupMenuEntry<RecordedTripAction>>[
          historyMenuItem(
            RecordedTripAction.viewMap,
            Icons.map_outlined,
            'View all days on map',
            canView,
          ),
          historyMenuItem(
            RecordedTripAction.continueTrip,
            Icons.add_road_rounded,
            trip.status == TripStatus.completed
                ? 'Continue completed Trip'
                : 'Start next day',
            canContinue && onContinue != null,
          ),
          const PopupMenuDivider(),
          historyMenuItem(
            RecordedTripAction.exportGeoJson,
            Icons.data_object,
            'Export GeoJSON',
            canExport && onExport != null,
          ),
          historyMenuItem(
            RecordedTripAction.exportKml,
            Icons.language,
            'Export KML',
            canExport && onExport != null,
          ),
          historyMenuItem(
            RecordedTripAction.exportGpx,
            Icons.route,
            'Export GPX',
            canExport && onExport != null,
          ),
          historyMenuItem(
            RecordedTripAction.exportCleanedGpx,
            Icons.auto_fix_high_outlined,
            'Export cleaned GPX',
            canExport && onExportCleaned != null,
          ),
          if (showDiagnostics)
            historyMenuItem(
              RecordedTripAction.exportDiagnostics,
              Icons.troubleshoot_outlined,
              'Export diagnostic GeoJSON',
              canExport && onExportDiagnostics != null,
            ),
          const PopupMenuDivider(),
          historyMenuItem(
            RecordedTripAction.delete,
            Icons.delete_outline,
            'Delete Trip',
            canDelete && onDelete != null,
            destructive: true,
          ),
        ],
      ),
    );
  }

  static String _statusLabel(TripStatus status) => switch (status) {
    TripStatus.active => 'Active',
    TripStatus.suspended => 'Suspended',
    TripStatus.completed => 'Completed',
    TripStatus.failed => 'Failed',
  };

  void _perform(RecordedTripAction action, Trip trip) {
    switch (action) {
      case RecordedTripAction.exportGeoJson:
        unawaited(onExport?.call(trip.id, TrackExportFormat.geoJson));
      case RecordedTripAction.exportKml:
        unawaited(onExport?.call(trip.id, TrackExportFormat.kml));
      case RecordedTripAction.exportGpx:
        unawaited(onExport?.call(trip.id, TrackExportFormat.gpx));
      case RecordedTripAction.exportCleanedGpx:
        unawaited(onExportCleaned?.call(trip));
      case RecordedTripAction.exportDiagnostics:
        unawaited(onExportDiagnostics?.call(trip.id));
      case RecordedTripAction.viewMap:
        unawaited(onViewMap?.call(trip));
      case RecordedTripAction.continueTrip:
        unawaited(onContinue?.call(trip));
      case RecordedTripAction.delete:
        unawaited(onDelete?.call(trip));
    }
  }
}
