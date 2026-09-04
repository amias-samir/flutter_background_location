import 'dart:math' as math;

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

  final double minimumDeviationMeters;
  final double minimumDetourRatio;

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
      uncertainty * 1.25,
    );
    final inboundSeconds = candidate.capturedAt
            .difference(before.capturedAt)
            .inMilliseconds
            .abs() /
        1000;
    final outboundSeconds =
        after.capturedAt.difference(candidate.capturedAt).inMilliseconds.abs() /
            1000;
    final plausible = (inboundSeconds == 0 || inbound / inboundSeconds <= 70) &&
        (outboundSeconds == 0 || outbound / outboundSeconds <= 70);
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
  final meanLat = (start.latitude + end.latitude) * math.pi / 360;
  final scaleX = math.cos(meanLat);
  final ax = start.longitude * scaleX;
  final ay = start.latitude;
  final bx = end.longitude * scaleX;
  final by = end.latitude;
  final px = point.longitude * scaleX;
  final py = point.latitude;
  final dx = bx - ax;
  final dy = by - ay;
  final lengthSquared = dx * dx + dy * dy;
  final t = lengthSquared == 0
      ? 0.0
      : (((px - ax) * dx + (py - ay) * dy) / lengthSquared).clamp(0.0, 1.0);
  return (ay + dy * t, (ax + dx * t) / scaleX);
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
  const radius = 6371008.8;
  final lat1 = latitude1 * math.pi / 180;
  final lat2 = latitude2 * math.pi / 180;
  final dLat = (latitude2 - latitude1) * math.pi / 180;
  final dLon = (longitude2 - longitude1) * math.pi / 180;
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1) * math.cos(lat2) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return radius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
