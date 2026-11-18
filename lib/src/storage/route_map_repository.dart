import '../domain/derived_geometry.dart';
import '../domain/route_summary.dart';
import '../domain/track.dart';
import '../domain/track_point.dart';
import '../domain/track_segment.dart';
import '../domain/track_stop.dart';
import '../domain/tracking_continuity.dart';
import '../domain/tracking_start.dart';
import '../domain/trip.dart';

/// Internal, read-only storage for map views ([RouteMapReader]): bounded,
/// lean reads that never write or take the database write lock. Not
/// exported; repositories without it are read through their public
/// contracts.
abstract interface class RouteMapRepository {
  /// What a map needs of [trackId] besides its points, read as one
  /// consistent set: points up to [RouteMapLegSource.upperSequence] belong
  /// to it. Throws `owner_scope_conflict` when [owner] does not own it.
  Future<RouteMapLegSource> routeMapLeg(TrackingOwner owner, String trackId);

  /// Up to [limit] of [trackId]'s map points after [afterSequence], up to
  /// [upperSequence], in sequence order: accepted points with their
  /// [cleanedRunId] coordinates when given, or, with [reviewRunId], the
  /// fixes that review keeps, accepted or not. Only the fields a map draws
  /// are read; journaled readings and activity probabilities are not.
  Future<List<RouteMapPointRow>> routeMapPointPage({
    required String trackId,
    required int afterSequence,
    required int upperSequence,
    required int limit,
    String? cleanedRunId,
    String? reviewRunId,
  });

  /// [tripId]'s Trip, legs and current gaps, with totals computed without
  /// writing. Throws `owner_scope_conflict` outside [owner].
  Future<RouteMapTripSource> routeMapTrip(TrackingOwner owner, String tripId);
}

/// Length of a derived run's stored path, read in bounded pages.
abstract interface class DerivedPathRepository {
  /// Sum of [runId]'s coordinate-to-coordinate distances within each of its
  /// segments, in sequence order.
  Future<double> derivedPathMeters(String runId);
}

/// One route's map inputs besides its points.
final class RouteMapLegSource {
  RouteMapLegSource({
    required this.track,
    required Iterable<TrackSegment> segments,
    required Iterable<TrackStop> stops,
    required Iterable<TrackingContinuityGap> gaps,
    required Set<String> legacyAutomaticAfterSegmentIds,
    required this.upperSequence,
    this.summary,
    this.reviewRunId,
    this.cleanedRun,
    this.awaitsReview = false,
  })  : segments = List<TrackSegment>.unmodifiable(segments),
        stops = List<TrackStop>.unmodifiable(stops),
        gaps = List<TrackingContinuityGap>.unmodifiable(gaps),
        legacyAutomaticAfterSegmentIds =
            Set<String>.unmodifiable(legacyAutomaticAfterSegmentIds);

  final Track track;
  final List<TrackSegment> segments;

  /// Current stored stops: the review's when the route has one.
  final List<TrackStop> stops;

  /// Current stored gaps: the review's when the route has one.
  final List<TrackingContinuityGap> gaps;
  final Set<String> legacyAutomaticAfterSegmentIds;

  /// The newest point sequence read with this source.
  final int upperSequence;
  final RouteSummary? summary;

  /// The route's current review run, if any.
  final String? reviewRunId;

  /// The newest completed stop-aware cleaning run under the current
  /// cleaning version, if any. It may end before [upperSequence].
  final DerivedGeometryRun? cleanedRun;

  /// Whether the route still waits for a review under the current rules.
  final bool awaitsReview;

  /// Whether the route's stops are still to be derived.
  bool get stopsPending => summary?.stopsSource == TrackStopSource.pending;
}

/// A map point and, for a cleaned view, its cleaned coordinates.
final class RouteMapPointRow {
  const RouteMapPointRow(
    this.point, {
    this.cleanedLatitude,
    this.cleanedLongitude,
  });

  final TrackPoint point;
  final double? cleanedLatitude;
  final double? cleanedLongitude;

  bool get hasCleaned => cleanedLatitude != null && cleanedLongitude != null;
}

/// A Trip's map inputs besides its legs' own.
final class RouteMapTripSource {
  RouteMapTripSource({
    required this.trip,
    required Iterable<TripLeg> legs,
    required Iterable<TrackingContinuityGap> gaps,
    this.summary,
  })  : legs = List<TripLeg>.unmodifiable(legs),
        gaps = List<TrackingContinuityGap>.unmodifiable(gaps);

  final Trip trip;
  final List<TripLeg> legs;
  final List<TrackingContinuityGap> gaps;
  final TripSummary? summary;
}
