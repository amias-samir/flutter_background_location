import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stop_replay_support.dart';

/// Quality policy 4: a riding fix of an adaptive route is accepted up to the
/// vehicle accuracy envelope, as a pocketed phone on a motorbike reports.
void main() {
  final t0 = DateTime.utc(2026, 10, 20, 4);
  final now = t0.add(const Duration(minutes: 1));

  LocationSample fix({
    required double accuracy,
    double? speed,
    ActivitySnapshot? activity,
  }) =>
      LocationSample(
        latitude: 0.5,
        longitude: 0.5,
        capturedAt: t0,
        horizontalAccuracy: accuracy,
        speed: speed,
        speedAccuracy: speed == null ? null : 2,
        provider: 'fused',
        capturedActivity: activity,
        mockDetectionAvailable: true,
      );

  ActivitySnapshot reading(TrackingActivityType type, int confidence) =>
      ActivitySnapshot(
        type: type,
        confidence: confidence,
        recordedAt: t0.subtract(const Duration(seconds: 2)),
        source: 'android_activity_recognition',
      );

  FixQualityDecision decide(
    LocationSample sample, {
    TrackingConfig config = const TrackingConfig(),
    int version = 4,
  }) =>
      FixQualityPolicy(config, version: version)
          .evaluate(sample: sample, previous: null, now: now);

  test('a riding fix is accepted up to the vehicle envelope', () {
    final riding = fix(accuracy: 30, speed: 8);
    expect(decide(riding).acceptedForGeometry, isTrue);
    expect(decide(riding).policyVersion, 4);
    expect(decide(riding, version: 3).rejectionReason, 'poor_accuracy');
    expect(
      decide(fix(accuracy: 40, speed: 8)).rejectionReason,
      'poor_accuracy',
      reason: 'beyond the 35 m envelope at High',
    );
  });

  test('slow riding needs an in-vehicle or on-bicycle reading', () {
    final slow = fix(
      accuracy: 30,
      speed: 3,
      activity: reading(TrackingActivityType.inVehicle, 90),
    );
    expect(decide(slow).acceptedForGeometry, isTrue);
    expect(
      decide(
        fix(
          accuracy: 30,
          speed: 3,
          activity: reading(TrackingActivityType.onBicycle, 80),
        ),
      ).acceptedForGeometry,
      isTrue,
    );
    expect(
        decide(fix(accuracy: 30, speed: 3)).rejectionReason, 'poor_accuracy');
    expect(
      decide(
        fix(
          accuracy: 30,
          speed: 3,
          activity: reading(TrackingActivityType.inVehicle, 40),
        ),
      ).rejectionReason,
      'poor_accuracy',
      reason: 'below the moving confidence threshold',
    );
  });

  test('walking and standing keep the walking limit', () {
    expect(
        decide(fix(accuracy: 30, speed: 1.4)).rejectionReason, 'poor_accuracy');
    expect(
      decide(
        fix(
          accuracy: 30,
          speed: 0,
          activity: reading(TrackingActivityType.inVehicle, 95),
        ),
      ).rejectionReason,
      'poor_accuracy',
      reason: 'at a traffic light the walking limit applies',
    );
    expect(decide(fix(accuracy: 30)).rejectionReason, 'poor_accuracy');
  });

  test('the envelope follows the accuracy preset', () {
    const precised = TrackingConfig(accuracy: TrackingAccuracy.precised);
    expect(
      decide(fix(accuracy: 22, speed: 10), config: precised)
          .acceptedForGeometry,
      isTrue,
    );
    expect(
      decide(fix(accuracy: 30, speed: 10), config: precised).rejectionReason,
      'poor_accuracy',
    );
  });

  test('a host limit other than the preset still applies', () {
    const strict = TrackingConfig(maximumAcceptedAccuracyMeters: 18);
    expect(
      decide(fix(accuracy: 25, speed: 10), config: strict).rejectionReason,
      'poor_accuracy',
    );
  });

  test('explicit travel intents keep their own limits', () {
    const walking = TrackingConfig(captureIntent: RouteCaptureIntent.walking);
    expect(
      decide(fix(accuracy: 30, speed: 10), config: walking).rejectionReason,
      'poor_accuracy',
    );
  });

  test('a route recorded under quality policy 3 decides as before', () async {
    Future<List<TrackPoint>> ride({int? qualityPolicy}) async {
      final run = await StopReplay.start(
        t0,
        config: const TrackingConfig(),
        qualityPolicy: qualityPolicy,
      );
      final locations = <LocationSample>[
        for (var step = 0; step < 6; step += 1)
          LocationSample(
            latitude: syntheticOrigin.latitude + step * 50 / 111195,
            longitude: syntheticOrigin.longitude,
            capturedAt: t0.add(Duration(seconds: step * 5)),
            // Pocketed on a motorbike: fixes alternate between 8 and 30 m.
            horizontalAccuracy: step.isOdd ? 30 : 8,
            verticalAccuracy: 3,
            speed: 10,
            speedAccuracy: 1,
            provider: 'fused',
            eventId: 'ride-$step',
            trackId: run.trackId,
            mockDetectionAvailable: true,
          ),
      ];
      return run.replay(
        SyntheticTrackingRoute(locations, const <ActivitySnapshot>[]),
      );
    }

    final current = await ride();
    expect(current.every((point) => point.accepted), isTrue);
    expect(
      current.map((point) => point.qualityPolicyVersion).toSet(),
      {TrackingPolicyVersions.qualityPolicy},
    );
    final quality4 = await ride(qualityPolicy: 4);
    expect(quality4.every((point) => point.accepted), isTrue);
    expect(quality4.map((point) => point.qualityPolicyVersion).toSet(), {4});
    final recorded = await ride(qualityPolicy: 3);
    expect(
      recorded.where((point) => !point.accepted).map((p) => p.rejectionReason),
      everyElement('poor_accuracy'),
    );
    expect(recorded.where((point) => !point.accepted), hasLength(3));
  });

  test('the shared limits match every resolved preset', () {
    for (final accuracy in TrackingAccuracy.values) {
      for (final intent in RouteCaptureIntent.values) {
        expect(
          TrackingConfig.defaultMaximumAcceptedAccuracyMeters(
            accuracy,
            intent,
          ),
          TrackingConfig(accuracy: accuracy, captureIntent: intent)
              .maximumAcceptedAccuracyMeters,
          reason: '$accuracy/$intent',
        );
      }
    }
  });
}
