import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/src/domain/track_geodesy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  group('FIX-23 shared geodesy', () {
    test('measures on the IUGG mean sphere', () {
      // One degree of arc on a 6 371 008.8 m sphere.
      expect(
        TrackGeodesy.sphericalHaversineMeters(0, 0, 1, 0),
        closeTo(111195.08, 0.01),
      );
      expect(
        TrackGeodesy.sphericalHaversineMeters(0, 179.9995, 0, -179.9995),
        closeTo(111.195, 0.001),
      );
      expect(TrackGeodesy.sphericalHaversineId,
          'spherical_haversine_r6371008_8_v1');
    });

    test('longitude helpers only change values across the antimeridian', () {
      expect(TrackGeodesy.longitudeDelta(179.9, -179.9), closeTo(0.2, 1e-9));
      expect(TrackGeodesy.longitudeDelta(-179.9, 179.9), closeTo(-0.2, 1e-9));
      expect(TrackGeodesy.unwrapLongitude(179.9, -179.9), closeTo(180.1, 1e-9));
      expect(TrackGeodesy.wrapLongitude(180.1), closeTo(-179.9, 1e-9));
      // Nearby values are returned bit for bit.
      const longitude = 85.3123456789;
      expect(TrackGeodesy.unwrapLongitude(85.3, longitude), longitude);
      expect(TrackGeodesy.wrapLongitude(longitude), longitude);
      expect(TrackGeodesy.longitudeDelta(85.3, longitude), longitude - 85.3);
    });
  });

  group('FIX-31 derived geometry across the antimeridian', () {
    late RepositoryHarness harness;
    const owner = TrackingOwner(userId: 'user-1', organizationId: 'org-1');

    setUp(() async {
      harness = RepositoryHarness();
      await harness.initialize();
    });

    tearDown(() => harness.repository.close());

    Future<String> crossingRoute() async {
      final trackId = await harness.createActiveTrack(trackId: 'dateline');
      for (final (index, longitude) in <double>[
        179.9990,
        179.9995,
        -179.9998,
        -179.9992,
      ].indexed) {
        await harness.append(
          trackId: trackId,
          latitude: 0.001,
          longitude: longitude,
          capturedAt: harness.now.add(Duration(seconds: index * 5)),
        );
      }
      await harness.repository.completeTrack(trackId, reason: 'done');
      return trackId;
    }

    test('the moving average blends the short way and stays in range',
        () async {
      final trackId = await crossingRoute();
      final service = DerivedGeometryService(harness.repository);

      final run = await service.derive(
        owner: owner,
        trackId: trackId,
        request: const DerivedGeometryRequest(smoothingFactor: 0.5),
      );
      final derived = await service.loadForMap(
        owner: owner,
        trackId: trackId,
        geometry: TrackGeometrySelection.derived(run.id),
      );
      final raw = await service.loadForMap(owner: owner, trackId: trackId);
      final pairs = [
        for (final (index, point) in derived.segments.single.points.indexed)
          (point, raw.segments.single.points[index]),
      ];

      for (final (smoothed, source) in pairs) {
        expect(smoothed.longitude, inInclusiveRange(-180, 180));
        expect(
          TrackGeodesy.sphericalHaversineMeters(
            smoothed.latitude,
            smoothed.longitude,
            source.latitude,
            source.longitude,
          ),
          lessThan(100),
          reason: 'a smoothed point stays near its source fix',
        );
      }
    });

    test('spike projection works in one longitude frame', () {
      TrackPoint point(int sequence, double latitude, double longitude) =>
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

      final smoothed = const UncertaintyWeightedRouteSmoother().smooth([
        point(1, 0, 179.999),
        point(2, 0.0015, 179.9999),
        point(3, 0, -179.9992),
      ]);

      expect(smoothed[1].latitude.abs(), lessThan(0.00001));
      expect(smoothed[1].longitude, inInclusiveRange(-180, 180));
      expect(
        TrackGeodesy.sphericalHaversineMeters(
            0, 179.9999, 0, smoothed[1].longitude),
        lessThan(20),
      );
    });

    test('uncertainty runs record the classifier thresholds they applied',
        () async {
      final trackId = await crossingRoute();
      final service = DerivedGeometryService(harness.repository);

      final run = await service.derive(
        owner: owner,
        trackId: trackId,
        request: const DerivedGeometryRequest(
          algorithm: 'uncertainty_weighted_smoothing',
        ),
      );

      expect(run.configuration, containsPair('minimumDeviationMeters', 8.0));
      expect(run.configuration, containsPair('minimumDetourRatio', 1.6));
      expect(run.configuration, containsPair('uncertaintyMultiplier', 1.25));
      expect(
        run.configuration,
        containsPair('maximumSpeedMetersPerSecond', 70.0),
      );
    });
  });
}
