import 'dart:collection';

import 'track_point.dart';

/// Kind of immutable, post-capture geometry requested by a host application.
enum DerivedRouteMode {
  /// Deterministic local correction that keeps every raw point as provenance.
  smoothed,

  /// Optional host-provided road or footpath alignment.
  mapMatched,
}

/// One raw anchor supplied to an opt-in geometry processor.
final class RouteGeometryProcessorPoint {
  /// Creates a processor input linked to one raw point.
  const RouteGeometryProcessorPoint({
    required this.sourcePointId,
    required this.segmentId,
    required this.sequence,
    required this.latitude,
    required this.longitude,
    required this.capturedAt,
    this.horizontalAccuracy,
  });

  /// Copies the coordinate and provenance needed by a processor.
  factory RouteGeometryProcessorPoint.fromTrackPoint(TrackPoint point) =>
      RouteGeometryProcessorPoint(
        sourcePointId: point.id,
        segmentId: point.segmentId,
        sequence: point.sequence,
        latitude: point.latitude,
        longitude: point.longitude,
        capturedAt: point.capturedAt,
        horizontalAccuracy: point.horizontalAccuracy,
      );

  /// Immutable source point identifier.
  final String sourcePointId;

  /// Canonical source segment identifier.
  final String segmentId;

  /// Route-global raw sequence.
  final int sequence;

  /// Raw latitude supplied only after the host opts into processing.
  final double latitude;

  /// Raw longitude supplied only after the host opts into processing.
  final double longitude;

  /// Provider timestamp for this raw anchor.
  final DateTime capturedAt;

  /// Reported horizontal uncertainty radius in metres.
  final double? horizontalAccuracy;
}

/// Bounded page passed to a host-supplied route processor.
final class RouteGeometryProcessorRequest {
  /// Creates one bounded, optionally overlapping processor request.
  RouteGeometryProcessorRequest({
    required this.trackId,
    required this.mode,
    required Iterable<RouteGeometryProcessorPoint> points,
    required this.pageNumber,
    required this.isFinalPage,
    this.overlapPointCount = 0,
  }) : points = UnmodifiableListView<RouteGeometryProcessorPoint>(
          List<RouteGeometryProcessorPoint>.of(points),
        );

  /// Track being processed.
  final String trackId;

  /// Requested derivation kind.
  final DerivedRouteMode mode;

  /// Ordered raw anchors in this page.
  final UnmodifiableListView<RouteGeometryProcessorPoint> points;

  /// One-based page number across the processing run.
  final int pageNumber;

  /// Whether this is the last page in the current source segment.
  final bool isFinalPage;

  /// Leading points repeated from the preceding page.
  final int overlapPointCount;
}

/// A processor coordinate linked to an immutable raw source point.
final class ProcessedRoutePoint {
  /// Creates one candidate result for an existing raw anchor.
  const ProcessedRoutePoint({
    required this.sourcePointId,
    required this.latitude,
    required this.longitude,
    required this.confidence,
    this.matched = true,
  });

  /// Raw source anchor receiving this candidate coordinate.
  final String sourcePointId;

  /// Candidate latitude.
  final double latitude;

  /// Candidate longitude.
  final double longitude;

  /// Processor-specific confidence normalized to 0–1.
  final double confidence;

  /// False asks the package to retain the raw coordinate for this anchor.
  final bool matched;
}

/// Result of one bounded processor page.
final class RouteGeometryProcessorResult {
  /// Creates a page result; missing source points use raw fallback.
  RouteGeometryProcessorResult({
    required Iterable<ProcessedRoutePoint> points,
    this.warning,
  }) : points = UnmodifiableListView<ProcessedRoutePoint>(
          List<ProcessedRoutePoint>.of(points),
        );

  /// Candidate results keyed by [ProcessedRoutePoint.sourcePointId].
  final UnmodifiableListView<ProcessedRoutePoint> points;

  /// Sanitized, coordinate-free warning for diagnostics.
  final String? warning;
}

/// Vendor-neutral opt-in contract for road/footpath alignment.
///
/// The host owns credentials, network consent, map licensing, timeouts, and
/// cancellation. Returning no/low-confidence match preserves raw geometry.
abstract interface class RouteGeometryProcessor {
  /// Stable processor/vendor name stored in immutable provenance.
  String get name;

  /// Stable processor algorithm or map-data version.
  String get version;

  /// Processes one bounded page without modifying canonical route points.
  Future<RouteGeometryProcessorResult> process(
    RouteGeometryProcessorRequest request,
  );
}
