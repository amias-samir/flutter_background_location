import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('corrects a supported straight-route spike and preserves endpoints', () {
    final points = <TrackPoint>[
      _point(1, 0, 0),
      _point(2, 0.0015, 0.001),
      _point(3, 0, 0.002),
    ];
    final result = const UncertaintyWeightedRouteSmoother().smooth(points);
    expect(result.first.latitude, points.first.latitude);
    expect(result.last.latitude, points.last.latitude);
    expect(result[1].latitude.abs(), lessThan(0.00001));
    expect(result[1].id, points[1].id);
  });

  test('retains a genuine right-angle walking corner', () {
    final points = <TrackPoint>[
      _point(1, 0, 0),
      _point(2, 0, 0.001),
      _point(3, 0.001, 0.001),
    ];
    final assessment = const UncertaintyAwareSpikeClassifier().assess(
      points[0],
      points[1],
      points[2],
    );
    expect(assessment.isSupportedSpike, isFalse);
    expect(const UncertaintyWeightedRouteSmoother().smooth(points)[1].longitude,
        points[1].longitude);
  });
}

TrackPoint _point(int sequence, double latitude, double longitude) =>
    TrackPoint(
      id: 'point-$sequence',
      trackId: 'track',
      segmentId: 'segment',
      sequence: sequence,
      latitude: latitude,
      longitude: longitude,
      horizontalAccuracy: 3,
      capturedAt: DateTime.utc(2026, 8, 31, 8, 0, sequence * 10),
      persistedAt: DateTime.utc(2026, 8, 31, 8, 0, sequence * 10),
      activityType: TrackingActivityType.walking,
      activityConfidence: 90,
      motionState: MotionState.moving,
      isMocked: false,
      mockDetectionAvailable: true,
      accepted: true,
      qualityFlags: TrackPointQualityFlag.none,
    );
