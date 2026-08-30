import 'track.dart';
import 'export_models.dart';
import 'route_geometry.dart';
import 'tracker_status.dart';
import 'tracking_config.dart';
import 'tracking_continuity.dart';
import 'tracking_start.dart';

/// Lifecycle of one user-visible journey containing one or more Track legs.
enum TripStatus { active, suspended, completed, failed }

/// User-visible multi-day journey aggregate.
final class Trip {
  const Trip({
    required this.id,
    required this.organizationId,
    required this.userId,
    required this.status,
    required this.startedAt,
    required this.legCount,
    required this.acceptedPointCount,
    required this.rejectedPointCount,
    required this.measuredDistanceMeters,
    required this.lifecycleRevision,
    required this.createdAt,
    required this.updatedAt,
    this.routeId,
    this.suspendedAt,
    this.endedAt,
    this.currentLegTrackId,
  });

  final String id;
  final String organizationId;
  final String userId;
  final String? routeId;
  final TripStatus status;
  final DateTime startedAt;
  final DateTime? suspendedAt;
  final DateTime? endedAt;
  final String? currentLegTrackId;
  final int legCount;
  final int acceptedPointCount;
  final int rejectedPointCount;
  final double measuredDistanceMeters;
  final int lifecycleRevision;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isContinuable =>
      status == TripStatus.suspended || status == TripStatus.completed;

  bool ownedBy(TrackingOwner owner) =>
      owner.userId == userId && owner.organizationId == organizationId;

  factory Trip.fromDatabase(Map<String, Object?> row) => Trip(
        id: row['id']! as String,
        organizationId: row['organization_id']! as String,
        userId: row['user_id']! as String,
        routeId: row['route_id'] as String?,
        status: TripStatus.values.byName(row['status']! as String),
        startedAt: DateTime.parse(row['started_at']! as String).toUtc(),
        suspendedAt: _date(row['suspended_at']),
        endedAt: _date(row['ended_at']),
        currentLegTrackId: row['current_leg_track_id'] as String?,
        legCount: (row['leg_count']! as num).toInt(),
        acceptedPointCount: (row['accepted_point_count']! as num).toInt(),
        rejectedPointCount: (row['rejected_point_count']! as num).toInt(),
        measuredDistanceMeters: (row['measured_distance_m']! as num).toDouble(),
        lifecycleRevision: (row['lifecycle_revision']! as num).toInt(),
        createdAt: DateTime.parse(row['created_at']! as String).toUtc(),
        updatedAt: DateTime.parse(row['updated_at']! as String).toUtc(),
      );
}

/// Membership and daily lifecycle metadata for one internal Track leg.
final class TripLeg {
  const TripLeg({
    required this.tripId,
    required this.trackId,
    required this.legNumber,
    required this.startedAt,
    required this.trackStatus,
    this.endedAt,
    this.dayLabel,
  });

  final String tripId;
  final String trackId;
  final int legNumber;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String? dayLabel;
  final TrackStatus trackStatus;

  factory TripLeg.fromDatabase(Map<String, Object?> row) => TripLeg(
        tripId: row['trip_id']! as String,
        trackId: row['track_id']! as String,
        legNumber: (row['leg_number']! as num).toInt(),
        startedAt: DateTime.parse(row['started_at']! as String).toUtc(),
        endedAt: _date(row['ended_at']),
        dayLabel: row['day_label'] as String?,
        trackStatus: TrackStatus.values.byName(row['track_status']! as String),
      );
}

/// Bounded summary of a Trip and its ordered legs/gap evidence.
final class TripBundle {
  TripBundle({
    required this.trip,
    required Iterable<TripLeg> legs,
    required Iterable<TrackingContinuityGap> gaps,
  })  : legs = List<TripLeg>.unmodifiable(legs),
        gaps = List<TrackingContinuityGap>.unmodifiable(gaps);

  final Trip trip;
  final List<TripLeg> legs;
  final List<TrackingContinuityGap> gaps;
}

/// Request for a new user-visible journey and its first internal Track leg.
final class TripStartRequest {
  const TripStartRequest({
    this.routeId,
    this.config,
    this.requestedTripId,
    this.operationId,
    this.dayLabel,
  });

  final String? routeId;
  final TrackingConfig? config;
  final String? requestedTripId;
  final String? operationId;
  final String? dayLabel;
}

/// Result after the first Trip leg has entered native capture.
final class TripStartResult {
  const TripStartResult({required this.trip, required this.leg});
  final Trip trip;
  final TripLeg leg;
}

/// How an idempotent Continue operation resolved its next leg.
enum TripContinueDisposition {
  createdLeg,
  reusedActiveLeg,
  resumedInterruptedLeg,
}

/// Result after continuing a suspended or explicitly reopened Trip.
final class TripContinueResult {
  const TripContinueResult({
    required this.trip,
    required this.leg,
    required this.disposition,
  });
  final Trip trip;
  final TripLeg leg;
  final TripContinueDisposition disposition;
}

/// Result of End day or terminal Complete Trip.
final class TripLifecycleResult {
  const TripLifecycleResult({
    required this.trip,
    required this.leg,
    required this.status,
  });
  final Trip trip;
  final TripLeg leg;
  final TrackerStatus status;
}

/// One combined immutable export of every current Trip leg.
final class TripExportResult {
  const TripExportResult({
    required this.tripId,
    required this.lifecycleRevision,
    required this.format,
    required this.fileName,
    required this.mimeType,
    required this.path,
    required this.pointCount,
    required this.sourceSegmentCount,
    required this.geometryPartCount,
    required this.gapCount,
    required this.inferredConnectorCount,
    required this.geometryContinuity,
  });

  final String tripId;
  final int lifecycleRevision;
  final TrackExportFormat format;
  final String fileName;
  final String mimeType;
  final String path;
  final int pointCount;
  final int sourceSegmentCount;
  final int geometryPartCount;
  final int gapCount;
  final int inferredConnectorCount;
  final RouteGeometryContinuity geometryContinuity;
}

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.parse(value as String).toUtc();
