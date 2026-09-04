import 'dart:math' as math;

import '../domain/route_geometry.dart';
import '../domain/track_point.dart';
import '../domain/track_segment.dart';
import '../domain/tracking_continuity.dart';

/// One bounded source segment supplied to [RouteGeometryAssembler].
final class RouteGeometrySourcePart {
  RouteGeometrySourcePart({
    required this.legNumber,
    required this.segment,
    required Iterable<TrackPoint> points,
    this.legacyAutomaticGapEligible = false,
  }) : points = List<TrackPoint>.unmodifiable(points);

  final int legNumber;
  final TrackSegment segment;
  final List<TrackPoint> points;

  /// Set only after checking the complete legacy safety rule, including the
  /// absence of interruption health/operation evidence.
  final bool legacyAutomaticGapEligible;
}

/// Shared decision for one presentation boundary between source segments.
///
/// Streaming exporters use this value without materializing either segment's
/// complete point list. The materialized assembler below uses the same method,
/// which keeps map, legacy export, and incremental export semantics aligned.
final class RouteGeometryBoundaryDecision {
  const RouteGeometryBoundaryDecision({
    required this.connect,
    required this.cause,
    required this.gapRepresented,
  });

  /// Whether the two source segments belong to one presentation part.
  final bool connect;

  /// Best available evidence for a presentation-only connector.
  final TrackingGapCause cause;

  /// Whether a durable gap row describes this exact segment boundary.
  final bool gapRepresented;
}

/// Shared pure topology assembler used by maps and all export paths.
final class RouteGeometryAssembler {
  const RouteGeometryAssembler();

  /// Resolves one boundary without requiring complete route geometry.
  RouteGeometryBoundaryDecision decideBoundary({
    required RouteGeometryContinuity continuity,
    TrackingContinuityGap? gap,
    bool legacyAutomaticGapEligible = false,
    bool crossesDailyLegBoundary = false,
  }) {
    final connect = switch (continuity) {
      RouteGeometryContinuity.preserveEvidenceSegments => false,
      RouteGeometryContinuity.mergeAutomaticCallbackGaps =>
        isAutomaticGap(gap) || legacyAutomaticGapEligible,
      RouteGeometryContinuity.connectDailyLegs => crossesDailyLegBoundary,
      RouteGeometryContinuity.connectAllChronologicalPoints => true,
    };
    return RouteGeometryBoundaryDecision(
      connect: connect,
      cause: gap?.cause ??
          (crossesDailyLegBoundary
              ? TrackingGapCause.overnightBoundary
              : TrackingGapCause.unknown),
      gapRepresented: gap != null,
    );
  }

  /// Builds auditable connector metadata from two existing captured anchors.
  InferredRouteConnector inferConnector({
    required TrackPoint before,
    required TrackPoint after,
    required int beforeLegNumber,
    required int afterLegNumber,
    TrackingContinuityGap? gap,
    TrackingGapCause? inferredCause,
  }) {
    final elapsed = after.capturedAt.difference(before.capturedAt);
    return InferredRouteConnector(
      beforePointId: before.id,
      afterPointId: after.id,
      beforeSegmentId: before.segmentId,
      afterSegmentId: after.segmentId,
      cause: gap?.cause ?? inferredCause ?? TrackingGapCause.unknown,
      duration: elapsed.isNegative ? Duration.zero : elapsed,
      straightLineDistanceMeters: gap?.straightLineDistanceMeters ??
          _distanceMeters(
            before.latitude,
            before.longitude,
            after.latitude,
            after.longitude,
          ),
      beforeLegNumber: beforeLegNumber,
      afterLegNumber: afterLegNumber,
    );
  }

  /// Whether typed evidence proves an automatic, non-user lifecycle gap.
  ///
  /// New healthy gaps normally remain inside one source segment. This method
  /// also handles schema-12 evidence imported from older split behavior. An
  /// explicit Pause/Resume, permission loss, or process boundary never matches.
  bool isAutomaticGap(TrackingContinuityGap? gap) {
    if (gap == null) return false;
    if (gap.treatment != TrackingGapTreatment.retainCurrentSegment) {
      return false;
    }
    return gap.cause == TrackingGapCause.acceptedFixRejectionRun ||
        gap.cause == TrackingGapCause.expectedStationarySuppression ||
        gap.cause == TrackingGapCause.providerBatching;
  }

  RouteGeometryReport assemble({
    required Iterable<RouteGeometrySourcePart> sourceParts,
    Iterable<TrackingContinuityGap> gaps = const <TrackingContinuityGap>[],
    RouteGeometryContinuity continuity =
        RouteGeometryContinuity.preserveEvidenceSegments,
  }) {
    final ordered = sourceParts.toList()
      ..sort((left, right) {
        final byLeg = left.legNumber.compareTo(right.legNumber);
        if (byLeg != 0) return byLeg;
        final bySegment = left.segment.segmentNumber.compareTo(
          right.segment.segmentNumber,
        );
        if (bySegment != 0) return bySegment;
        return left.segment.id.compareTo(right.segment.id);
      });
    final acceptedParts = <RouteGeometrySourcePart>[];
    for (final source in ordered) {
      final accepted = source.points.where((point) => point.accepted).toList()
        ..sort((left, right) => left.sequence.compareTo(right.sequence));
      if (accepted.isEmpty) continue;
      acceptedParts.add(
        RouteGeometrySourcePart(
          legNumber: source.legNumber,
          segment: source.segment,
          points: accepted,
          legacyAutomaticGapEligible: source.legacyAutomaticGapEligible,
        ),
      );
    }

    final gapList = gaps.toList(growable: false);
    final gapByBoundary = <String, TrackingContinuityGap>{
      for (final gap in gapList)
        _boundaryKey(gap.beforeSegmentId, gap.afterSegmentId): gap,
    };
    final resultParts = <RouteGeometryPart>[];
    final connectors = <InferredRouteConnector>[];
    var representedGapBoundaries = 0;
    var currentPoints = <TrackPoint>[];
    var currentSegmentIds = <String>[];
    var currentLegNumbers = <int>[];
    RouteGeometrySourcePart? previous;

    void commitPart() {
      if (currentPoints.isEmpty) return;
      resultParts.add(
        RouteGeometryPart(
          partNumber: resultParts.length + 1,
          points: currentPoints,
          sourceSegmentIds: currentSegmentIds,
          sourceLegNumbers: currentLegNumbers,
        ),
      );
      currentPoints = <TrackPoint>[];
      currentSegmentIds = <String>[];
      currentLegNumbers = <int>[];
    }

    for (final source in acceptedParts) {
      final prior = previous;
      if (prior == null) {
        currentPoints.addAll(source.points);
        currentSegmentIds.add(source.segment.id);
        currentLegNumbers.add(source.legNumber);
        previous = source;
        continue;
      }

      final gap =
          gapByBoundary[_boundaryKey(prior.segment.id, source.segment.id)];
      if (gap != null) representedGapBoundaries += 1;
      final decision = decideBoundary(
        continuity: continuity,
        gap: gap,
        legacyAutomaticGapEligible: source.legacyAutomaticGapEligible,
        crossesDailyLegBoundary: prior.legNumber != source.legNumber,
      );

      if (!decision.connect) {
        commitPart();
      } else {
        final before = prior.points.last;
        final after = source.points.first;
        connectors.add(
          inferConnector(
            before: before,
            after: after,
            beforeLegNumber: prior.legNumber,
            afterLegNumber: source.legNumber,
            gap: gap,
            inferredCause: decision.cause,
          ),
        );
      }
      currentPoints.addAll(source.points);
      currentSegmentIds.add(source.segment.id);
      if (!currentLegNumbers.contains(source.legNumber)) {
        currentLegNumbers.add(source.legNumber);
      }
      previous = source;
    }
    commitPart();

    final unrecordedBoundaries = math.max(
      0,
      acceptedParts.length - 1 - representedGapBoundaries,
    );
    return RouteGeometryReport(
      continuity: continuity,
      parts: resultParts,
      inferredConnectors: connectors,
      sourceSegmentCount: ordered.length,
      gapCount: gapList.length + unrecordedBoundaries,
      gaps: gapList,
    );
  }

  static String _boundaryKey(String before, String after) =>
      '$before\u0000$after';

  static double _distanceMeters(
    double latitude1,
    double longitude1,
    double latitude2,
    double longitude2,
  ) {
    const radius = 6371008.8;
    final lat1 = latitude1 * math.pi / 180;
    final lat2 = latitude2 * math.pi / 180;
    final deltaLatitude = (latitude2 - latitude1) * math.pi / 180;
    final deltaLongitude = (longitude2 - longitude1) * math.pi / 180;
    final a = math.sin(deltaLatitude / 2) * math.sin(deltaLatitude / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(deltaLongitude / 2) *
            math.sin(deltaLongitude / 2);
    return radius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}
