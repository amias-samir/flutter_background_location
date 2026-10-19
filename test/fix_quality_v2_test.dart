import 'dart:math' as math;

import 'package:flutter_background_location_tracker/src/domain/activity_snapshot.dart';
import 'package:flutter_background_location_tracker/src/domain/fix_quality.dart';
import 'package:flutter_background_location_tracker/src/domain/location_sample.dart';
import 'package:flutter_background_location_tracker/src/domain/motion_policy.dart';
import 'package:flutter_background_location_tracker/src/domain/track_point.dart';
import 'package:flutter_background_location_tracker/src/domain/tracker_status.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Synthetic origin; offsets are metres north of it.
  const originLatitude = 0.5;
  const originLongitude = 0.5;
  const metersPerDegree = 111195.07973436875;
  final t0 = DateTime.utc(2026, 10, 18, 13);
  final now = t0.add(const Duration(hours: 4));

  final anchor = TrackPoint(
    id: 'anchor',
    trackId: 'track',
    segmentId: 'segment',
    sequence: 1,
    latitude: originLatitude,
    longitude: originLongitude,
    capturedAt: t0,
    persistedAt: t0,
    activityType: TrackingActivityType.stationary,
    activityConfidence: 100,
    motionState: MotionState.moving,
    isMocked: false,
    mockDetectionAvailable: true,
    accepted: true,
    qualityFlags: TrackPointQualityFlag.none,
    horizontalAccuracy: 3,
    verticalAccuracy: 3,
    speedAccuracy: 2,
  );

  LocationSample fixNorth(
    double meters, {
    int seconds = 60,
    double accuracy = 3,
    double? speed = 0,
    double? speedAccuracy = 2.5,
  }) =>
      LocationSample(
        latitude: originLatitude + meters / metersPerDegree,
        longitude: originLongitude,
        capturedAt: t0.add(Duration(seconds: seconds)),
        horizontalAccuracy: accuracy,
        verticalAccuracy: 3,
        speed: speed,
        speedAccuracy: speedAccuracy,
        provider: 'fused',
        mockDetectionAvailable: true,
        mockEvidence: null,
      );

  const stop = StopContext(stillEpisodeActive: true);
  const config = TrackingConfig();
  const policy = FixQualityPolicy(config, version: 2);

  FixQualityDecision decide(LocationSample sample, {StopContext? context}) =>
      policy.evaluate(
        sample: sample,
        previous: anchor,
        now: now,
        stop: context ?? stop,
      );

  test('the hold radius has a 25 m floor and scales with uncertainty', () {
    expect(
      MotionPolicyV2.holdRadiusMeters(
        anchorSigmaMeters: 2,
        fixSigmaMeters: 2,
      ),
      25,
    );
    final sigma = 13 / 1.51 * 1.2;
    expect(
      MotionPolicyV2.holdRadiusMeters(
        anchorSigmaMeters: sigma,
        fixSigmaMeters: sigma,
      ),
      closeTo(math.sqrt(9.21 * 2 * sigma * sigma), 1e-9),
    );
  });

  test('inside the radius while still: stationary_hold', () {
    final decision = decide(fixNorth(12));
    expect(decision.acceptedForGeometry, isFalse);
    expect(decision.rejectionReason, FixQualityIssue.stationaryHold);
    expect(decision.issues, contains(FixQualityIssue.stationaryHold));
    expect(decision.policyVersion, 2);
  });

  test('outside the radius without confirmation: stationary_outlier', () {
    final decision = decide(fixNorth(60));
    expect(decision.acceptedForGeometry, isFalse);
    expect(decision.rejectionReason, FixQualityIssue.stationaryOutlier);
  });

  test('a clearly measured Doppler speed confirms a departure', () {
    final decision = decide(fixNorth(60, speed: 3.4, speedAccuracy: 1.2));
    expect(decision.acceptedForGeometry, isTrue);
    expect(decision.rejectionReason, isNull);
  });

  test('an indoor Doppler speed with a wide accuracy proves nothing', () {
    // 0 ± 5.9 and 1.7 ± 5.9 m/s, as during the field test's GNSS burst.
    for (final speed in <double>[0, 1.7]) {
      final decision = decide(fixNorth(60, speed: speed, speedAccuracy: 5.9));
      expect(decision.rejectionReason, FixQualityIssue.stationaryOutlier);
    }
    expect(
      MotionPolicyV2.dopplerConfirmsDeparture(speed: 1.1, speedAccuracy: 0.2),
      isFalse,
      reason: 'below 1.2 m/s',
    );
    expect(
      MotionPolicyV2.dopplerConfirmsDeparture(speed: 1.2, speedAccuracy: 0.2),
      isTrue,
    );
  });

  test('sixty seconds outside, moving farther and two radii away departs', () {
    final run = StopContext(
      stillEpisodeActive: true,
      outsideRunStartedAt: t0.add(const Duration(seconds: 60)),
      outsideRunFarthestMeters: 45,
    );
    expect(
      decide(fixNorth(55, seconds: 120), context: run).acceptedForGeometry,
      isTrue,
    );
  });

  test('the departure rules reject the alternatives that let bursts through',
      () {
    // Fewer than 60 s outside.
    final young = StopContext(
      stillEpisodeActive: true,
      outsideRunStartedAt: t0.add(const Duration(seconds: 70)),
      outsideRunFarthestMeters: 45,
    );
    expect(
      decide(fixNorth(55, seconds: 120), context: young).rejectionReason,
      FixQualityIssue.stationaryOutlier,
    );
    // Sixty seconds outside but closer than the run's farthest fix: a burst
    // that is wandering back.
    final returning = StopContext(
      stillEpisodeActive: true,
      outsideRunStartedAt: t0.add(const Duration(seconds: 30)),
      outsideRunFarthestMeters: 100,
    );
    expect(
      decide(fixNorth(60, seconds: 120), context: returning).rejectionReason,
      FixQualityIssue.stationaryOutlier,
    );
    // Sixty seconds outside but within two radii.
    final near = StopContext(
      stillEpisodeActive: true,
      outsideRunStartedAt: t0.add(const Duration(seconds: 30)),
      outsideRunFarthestMeters: 30,
    );
    expect(
      decide(fixNorth(40, seconds: 120), context: near).rejectionReason,
      FixQualityIssue.stationaryOutlier,
    );
  });

  test('without a current episode, quality policy 2 decides like version 1',
      () {
    const v1 = FixQualityPolicy(config, version: 1);
    for (final meters in <double>[12, 60]) {
      final sample = fixNorth(meters);
      final reference = v1.evaluate(sample: sample, previous: anchor, now: now);
      for (final context in <StopContext?>[
        null,
        const StopContext(stillEpisodeActive: false),
      ]) {
        final decision = policy.evaluate(
          sample: sample,
          previous: anchor,
          now: now,
          stop: context,
        );
        expect(decision.acceptedForGeometry, reference.acceptedForGeometry);
        expect(decision.rejectionReason, reference.rejectionReason);
        expect(decision.issues, reference.issues);
        expect(decision.qualityFlags, reference.qualityFlags);
        expect(decision.policyVersion, 2);
      }
    }
  });

  test('explicit capture intents are never held', () {
    for (final intent in <RouteCaptureIntent>[
      RouteCaptureIntent.walking,
      RouteCaptureIntent.cycling,
      RouteCaptureIntent.vehicle,
    ]) {
      final explicit = FixQualityPolicy(
        TrackingConfig(captureIntent: intent),
        version: 2,
      );
      final decision = explicit.evaluate(
        sample: fixNorth(12),
        previous: anchor,
        now: now,
        stop: stop,
      );
      expect(decision.acceptedForGeometry, isTrue, reason: intent.name);
    }
  });

  test('a fix version 1 rejects keeps its version 1 reason', () {
    final decision = decide(fixNorth(12, accuracy: 25));
    expect(decision.rejectionReason, 'poor_accuracy');
  });

  test('the first fix of a segment has no anchor and is accepted', () {
    final decision = policy.evaluate(
      sample: fixNorth(12),
      previous: null,
      now: now,
      stop: stop,
    );
    expect(decision.acceptedForGeometry, isTrue);
  });

  test('quality policy 1 ignores the stop context', () {
    const v1 = FixQualityPolicy(config, version: 1);
    final decision = v1.evaluate(
      sample: fixNorth(12),
      previous: anchor,
      now: now,
      stop: stop,
    );
    expect(decision.acceptedForGeometry, isTrue);
    expect(decision.policyVersion, 1);
  });
}
