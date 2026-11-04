import 'dart:math' as math;

import '../domain/track_geodesy.dart';
import '../domain/track_point.dart';

/// Evidence returned for the middle anchor of a three-point route window.
final class RouteSpikeAssessment {
  const RouteSpikeAssessment({
    required this.isSupportedSpike,
    required this.lateralDeviationMeters,
    required this.detourRatio,
    required this.reason,
  });

  final bool isSupportedSpike;
  final double lateralDeviationMeters;
  final double detourRatio;
  final String reason;
}

/// Conservative three-anchor classifier that uses uncertainty and kinematics.
final class UncertaintyAwareSpikeClassifier {
  const UncertaintyAwareSpikeClassifier({
    this.minimumDeviationMeters = 8,
    this.minimumDetourRatio = 1.6,
  });

  /// Reported uncertainty is scaled by this before it can support a spike.
  static const uncertaintyMultiplier = 1.25;

  /// Inbound or outbound speeds above this make a spike implausible.
  static const maximumSpeedMetersPerSecond = 70.0;

  final double minimumDeviationMeters;
  final double minimumDetourRatio;

  /// Thresholds recorded in the provenance of each run that uses them.
  Map<String, Object?> get configuration => <String, Object?>{
        'minimumDeviationMeters': minimumDeviationMeters,
        'minimumDetourRatio': minimumDetourRatio,
        'uncertaintyMultiplier': uncertaintyMultiplier,
        'maximumSpeedMetersPerSecond': maximumSpeedMetersPerSecond,
      };

  RouteSpikeAssessment assess(
    TrackPoint before,
    TrackPoint candidate,
    TrackPoint after,
  ) {
    final direct = _distance(before, after);
    final inbound = _distance(before, candidate);
    final outbound = _distance(candidate, after);
    final detourRatio = direct <= 0.5 ? 1.0 : (inbound + outbound) / direct;
    final deviation = _pointToChordMeters(before, candidate, after);
    final uncertainty = <double>[
      before.horizontalAccuracy ?? 0,
      candidate.horizontalAccuracy ?? 0,
      after.horizontalAccuracy ?? 0,
    ].reduce(math.max);
    final requiredDeviation = math.max(
      minimumDeviationMeters,
      uncertainty * uncertaintyMultiplier,
    );
    final inboundSeconds = candidate.capturedAt
            .difference(before.capturedAt)
            .inMilliseconds
            .abs() /
        1000;
    final outboundSeconds =
        after.capturedAt.difference(candidate.capturedAt).inMilliseconds.abs() /
            1000;
    final plausible = (inboundSeconds == 0 ||
            inbound / inboundSeconds <= maximumSpeedMetersPerSecond) &&
        (outboundSeconds == 0 ||
            outbound / outboundSeconds <= maximumSpeedMetersPerSecond);
    final supported = deviation >= requiredDeviation &&
        detourRatio >= minimumDetourRatio &&
        plausible;
    return RouteSpikeAssessment(
      isSupportedSpike: supported,
      lateralDeviationMeters: deviation,
      detourRatio: detourRatio,
      reason: supported
          ? 'uncertainty_supported_lateral_spike'
          : 'retain_raw_anchor',
    );
  }
}

/// Deterministic smoother that corrects only supported middle-point spikes.
///
/// Endpoints and raw points remain unchanged in storage. The returned list is
/// a presentation-only coordinate view with one item per raw source point.
final class UncertaintyWeightedRouteSmoother {
  const UncertaintyWeightedRouteSmoother({
    this.classifier = const UncertaintyAwareSpikeClassifier(),
  });

  final UncertaintyAwareSpikeClassifier classifier;

  List<TrackPoint> smooth(List<TrackPoint> points) {
    if (points.length < 3) return List<TrackPoint>.of(points);
    final result = <TrackPoint>[points.first];
    for (var index = 1; index < points.length - 1; index += 1) {
      final before = points[index - 1];
      final candidate = points[index];
      final after = points[index + 1];
      final assessment = classifier.assess(before, candidate, after);
      if (!assessment.isSupportedSpike) {
        result.add(candidate);
        continue;
      }
      final projected = _projectOntoChord(before, candidate, after);
      result.add(
        candidate.withCoordinates(
          latitude: projected.$1,
          longitude: projected.$2,
        ),
      );
    }
    result.add(points.last);
    return result;
  }
}

(double, double) _projectOntoChord(
  TrackPoint start,
  TrackPoint point,
  TrackPoint end,
) {
  // Project in one longitude frame across the antimeridian.
  final pointLongitude =
      TrackGeodesy.unwrapLongitude(start.longitude, point.longitude);
  final endLongitude =
      TrackGeodesy.unwrapLongitude(start.longitude, end.longitude);
  final meanLat = (start.latitude + end.latitude) * math.pi / 360;
  final scaleX = math.cos(meanLat);
  final ax = start.longitude * scaleX;
  final ay = start.latitude;
  final bx = endLongitude * scaleX;
  final by = end.latitude;
  final px = pointLongitude * scaleX;
  final py = point.latitude;
  final dx = bx - ax;
  final dy = by - ay;
  final lengthSquared = dx * dx + dy * dy;
  final t = lengthSquared == 0
      ? 0.0
      : (((px - ax) * dx + (py - ay) * dy) / lengthSquared).clamp(0.0, 1.0);
  return (ay + dy * t, TrackGeodesy.wrapLongitude((ax + dx * t) / scaleX));
}

double _pointToChordMeters(
  TrackPoint start,
  TrackPoint point,
  TrackPoint end,
) {
  final projected = _projectOntoChord(start, point, end);
  return _distanceCoordinates(
    point.latitude,
    point.longitude,
    projected.$1,
    projected.$2,
  );
}

double _distance(TrackPoint left, TrackPoint right) => _distanceCoordinates(
      left.latitude,
      left.longitude,
      right.latitude,
      right.longitude,
    );

double _distanceCoordinates(
  double latitude1,
  double longitude1,
  double latitude2,
  double longitude2,
) {
  return TrackGeodesy.sphericalHaversineMeters(
    latitude1,
    longitude1,
    latitude2,
    longitude2,
  );
}
