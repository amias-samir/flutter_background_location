import 'track_point.dart';
import 'tracking_continuity.dart';

/// Presentation topology applied without mutating canonical route evidence.
enum RouteGeometryContinuity {
  /// Preserve every recorded Track segment/Trip leg boundary.
  preserveEvidenceSegments,

  /// Join only typed or safely recognized legacy automatic callback gaps.
  mergeAutomaticCallbackGaps,

  /// Join all chronological points and report every inferred connector.
  connectAllChronologicalPoints,
}

/// One presentation part containing existing points in chronological order.
final class RouteGeometryPart {
  RouteGeometryPart({
    required this.partNumber,
    required Iterable<TrackPoint> points,
    required Iterable<String> sourceSegmentIds,
    required Iterable<int> sourceLegNumbers,
  })  : points = List<TrackPoint>.unmodifiable(points),
        sourceSegmentIds = List<String>.unmodifiable(sourceSegmentIds),
        sourceLegNumbers = List<int>.unmodifiable(sourceLegNumbers);

  final int partNumber;
  final List<TrackPoint> points;
  final List<String> sourceSegmentIds;
  final List<int> sourceLegNumbers;
}

/// Presentation-only straight connector between two captured anchors.
final class InferredRouteConnector {
  const InferredRouteConnector({
    required this.beforePointId,
    required this.afterPointId,
    required this.beforeSegmentId,
    required this.afterSegmentId,
    required this.cause,
    required this.duration,
    required this.straightLineDistanceMeters,
    required this.beforeLegNumber,
    required this.afterLegNumber,
  });

  final String beforePointId;
  final String afterPointId;
  final String beforeSegmentId;
  final String afterSegmentId;
  final TrackingGapCause cause;
  final Duration duration;
  final double straightLineDistanceMeters;
  final int beforeLegNumber;
  final int afterLegNumber;
}

/// Counts and materialized geometry produced by one shared assembly pass.
final class RouteGeometryReport {
  RouteGeometryReport({
    required this.continuity,
    required Iterable<RouteGeometryPart> parts,
    required Iterable<InferredRouteConnector> inferredConnectors,
    required this.sourceSegmentCount,
    required this.gapCount,
    Iterable<TrackingContinuityGap> gaps = const <TrackingContinuityGap>[],
  })  : parts = List<RouteGeometryPart>.unmodifiable(parts),
        inferredConnectors =
            List<InferredRouteConnector>.unmodifiable(inferredConnectors),
        gaps = List<TrackingContinuityGap>.unmodifiable(gaps);

  final RouteGeometryContinuity continuity;
  final List<RouteGeometryPart> parts;
  final List<InferredRouteConnector> inferredConnectors;
  final int sourceSegmentCount;
  final int gapCount;

  /// Durable, coordinate-free gap evidence used to label map/export topology.
  final List<TrackingContinuityGap> gaps;

  int get geometryPartCount => parts.length;
  int get inferredConnectorCount => inferredConnectors.length;
  int get pointCount =>
      parts.fold(0, (count, part) => count + part.points.length);
  bool get hasInferredConnectors => inferredConnectors.isNotEmpty;
}
