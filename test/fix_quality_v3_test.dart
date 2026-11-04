import 'package:flutter_background_location_tracker/src/domain/activity_snapshot.dart';
import 'package:flutter_background_location_tracker/src/domain/fix_quality.dart';
import 'package:flutter_background_location_tracker/src/domain/location_sample.dart';
import 'package:flutter_background_location_tracker/src/domain/stop_site.dart';
import 'package:flutter_background_location_tracker/src/domain/track_point.dart';
import 'package:flutter_background_location_tracker/src/domain/tracker_status.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Quality policy 3: a stop is a stay at a place. Decision table for one fix
/// against a current stop centre.
void main() {
  // Synthetic origin; offsets are metres north of it.
  const originLatitude = 0.5;
  const originLongitude = 0.5;
  const metersPerDegree = 111195.07973436875;
  final t0 = DateTime.utc(2026, 10, 19, 9);
  final now = t0.add(const Duration(hours: 4));

  // The last accepted point, 10 m south of the stop centre: version 3 holds
  // around the centre, not around this point.
  final previous = TrackPoint(
    id: 'previous',
    trackId: 'track',
    segmentId: 'segment',
    sequence: 1,
    latitude: originLatitude - 10 / metersPerDegree,
    longitude: originLongitude,
    capturedAt: t0,
    persistedAt: t0,
    activityType: TrackingActivityType.unknown,
    activityConfidence: 40,
    motionState: MotionState.moving,
    isMocked: false,
    mockDetectionAvailable: true,
    accepted: true,
    qualityFlags: TrackPointQualityFlag.none,
    horizontalAccuracy: 3,
    verticalAccuracy: 3,
    speedAccuracy: 0.3,
  );
  const centre = StopSiteAnchor(
    latitude: originLatitude,
    longitude: originLongitude,
    sigmaMeters: 2,
  );

  LocationSample fixNorth(
    double meters, {
    int seconds = 60,
    double accuracy = 3,
    double? speed = 0.8,
    double? speedAccuracy = 0.25,
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
      );

  const config = TrackingConfig();
  const policy = FixQualityPolicy(config, version: 3);

  FixQualityDecision decide(
    LocationSample sample, {
    StopContext stop =
        const StopContext(stillEpisodeActive: false, site: centre),
    FixQualityPolicy using = policy,
  }) =>
      using.evaluate(sample: sample, previous: previous, now: now, stop: stop);

  test('without a current stop, version 3 decides as version 1', () {
    final decision = decide(
      fixNorth(40),
      stop: const StopContext(stillEpisodeActive: false),
    );
    expect(decision.acceptedForGeometry, isTrue);
    expect(decision.policyVersion, 3);
    expect(decision.qualityFlags, TrackPointQualityFlag.none);
  });

  test('walking inside the radius is held, whatever the activity', () {
    // A precise walking Doppler speed 12 m from the centre: part of the stop.
    final decision = decide(fixNorth(12, speed: 0.9, speedAccuracy: 0.2));
    expect(decision.acceptedForGeometry, isFalse);
    expect(decision.rejectionReason, FixQualityIssue.stationaryHold);
    expect(
      decision.qualityFlags & TrackPointQualityFlag.duringStop,
      TrackPointQualityFlag.duringStop,
    );
    expect(decision.policyVersion, 3);
  });

  test('the radius is measured from the stop centre', () {
    // 30 m from the centre but only 20 m from the previous point would be
    // held under version 2; version 3 sees it outside the stop.
    final decision = decide(fixNorth(-30, speed: 0, speedAccuracy: 2));
    expect(decision.rejectionReason, FixQualityIssue.stationaryOutlier);
  });

  test('version 1 rejections during a stop are flagged as stop evidence', () {
    final decision = decide(fixNorth(3, accuracy: 120));
    expect(decision.acceptedForGeometry, isFalse);
    expect(decision.rejectionReason, 'poor_accuracy');
    expect(
      decision.qualityFlags &
          (TrackPointQualityFlag.duringStop |
              TrackPointQualityFlag.poorAccuracy),
      TrackPointQualityFlag.duringStop | TrackPointQualityFlag.poorAccuracy,
    );
  });

  test('a clearly measured Doppler speed outside the radius departs', () {
    final decision = decide(fixNorth(40, speed: 3.4, speedAccuracy: 1.2));
    expect(decision.acceptedForGeometry, isTrue);
    expect(decision.qualityFlags, TrackPointQualityFlag.none);
  });

  test('moving evidence departs on the second consecutive outside fix', () {
    final first = decide(
      fixNorth(30),
      stop: const StopContext(
        stillEpisodeActive: false,
        site: centre,
        movingEvidenceCurrent: true,
      ),
    );
    expect(first.rejectionReason, FixQualityIssue.stationaryOutlier);

    final second = decide(
      fixNorth(36, seconds: 65),
      stop: StopContext(
        stillEpisodeActive: false,
        site: centre,
        movingEvidenceCurrent: true,
        outsideRunCount: 1,
        outsideRunStartedAt: t0.add(const Duration(seconds: 60)),
        outsideRunFarthestMeters: 30,
      ),
    );
    expect(second.acceptedForGeometry, isTrue);

    // Without moving evidence, two outside fixes are not enough.
    final unconfirmed = decide(
      fixNorth(36, seconds: 65, speed: 0, speedAccuracy: 2),
      stop: StopContext(
        stillEpisodeActive: false,
        site: centre,
        outsideRunCount: 1,
        outsideRunStartedAt: t0.add(const Duration(seconds: 60)),
        outsideRunFarthestMeters: 30,
      ),
    );
    expect(unconfirmed.rejectionReason, FixQualityIssue.stationaryOutlier);
  });

  test('position alone departs only when sustained and moving away', () {
    StopContext outside(
            {required int startedSecondsAgo, double farthest = 0}) =>
        StopContext(
          stillEpisodeActive: false,
          site: centre,
          outsideRunCount: 3,
          outsideRunStartedAt:
              t0.add(Duration(seconds: 120 - startedSecondsAgo)),
          outsideRunFarthestMeters: farthest,
        );
    LocationSample at(double meters) =>
        fixNorth(meters, seconds: 120, speed: 0, speedAccuracy: 3);

    expect(
      decide(at(60), stop: outside(startedSecondsAgo: 60)).acceptedForGeometry,
      isTrue,
    );
    expect(
      decide(at(60), stop: outside(startedSecondsAgo: 30)).rejectionReason,
      FixQualityIssue.stationaryOutlier,
      reason: 'not outside for long enough',
    );
    expect(
      decide(at(60), stop: outside(startedSecondsAgo: 60, farthest: 80))
          .rejectionReason,
      FixQualityIssue.stationaryOutlier,
      reason: 'not the farthest fix of its run',
    );
    expect(
      decide(at(40), stop: outside(startedSecondsAgo: 60)).rejectionReason,
      FixQualityIssue.stationaryOutlier,
      reason: 'less than two hold radii out',
    );
  });

  group('a pause, a stay not yet a stop', () {
    const pause = StopContext(
      stillEpisodeActive: false,
      site: centre,
      stopRecognized: false,
    );

    test('a quiet fix is held inside the radius', () {
      final decision =
          decide(fixNorth(8, speed: 0, speedAccuracy: 2), stop: pause);
      expect(decision.rejectionReason, FixQualityIssue.stationaryHold);
      expect(
        decision.qualityFlags & TrackPointQualityFlag.duringStop,
        TrackPointQualityFlag.duringStop,
      );
    });

    test('a quiet fix outside the radius is an outlier', () {
      final decision =
          decide(fixNorth(40, speed: 0, speedAccuracy: 2), stop: pause);
      expect(decision.rejectionReason, FixQualityIssue.stationaryOutlier);
      expect(
        decision.qualityFlags & TrackPointQualityFlag.duringStop,
        TrackPointQualityFlag.duringStop,
      );
    });

    test('a recent moving reading ends the pause at once', () {
      final decision = decide(
        fixNorth(5, speed: 0, speedAccuracy: 2),
        stop: const StopContext(
          stillEpisodeActive: false,
          site: centre,
          stopRecognized: false,
          recentMovingReading: true,
        ),
      );
      expect(decision.acceptedForGeometry, isTrue);
      expect(decision.qualityFlags, TrackPointQualityFlag.none);
    });

    test('a walking Doppler speed ends the pause, but not a stop', () {
      final walkingFix = fixNorth(5, speed: 1.2, speedAccuracy: 0.3);
      expect(decide(walkingFix, stop: pause).acceptedForGeometry, isTrue);
      expect(
        decide(walkingFix).rejectionReason,
        FixQualityIssue.stationaryHold,
        reason: 'walking inside a place is part of its stop',
      );
    });

    test('moving evidence since the stay began does not end it alone', () {
      final decision = decide(
        fixNorth(36, seconds: 65, speed: 0, speedAccuracy: 2),
        stop: StopContext(
          stillEpisodeActive: false,
          site: centre,
          stopRecognized: false,
          movingEvidenceCurrent: true,
          outsideRunCount: 1,
          outsideRunStartedAt: t0.add(const Duration(seconds: 60)),
          outsideRunFarthestMeters: 30,
        ),
      );
      expect(decision.rejectionReason, FixQualityIssue.stationaryOutlier);
    });

    test('a sustained departure ends the pause', () {
      final decision = decide(
        fixNorth(60, seconds: 120, speed: 0, speedAccuracy: 3),
        stop: StopContext(
          stillEpisodeActive: false,
          site: centre,
          stopRecognized: false,
          outsideRunCount: 3,
          outsideRunStartedAt: t0.add(const Duration(seconds: 60)),
        ),
      );
      expect(decision.acceptedForGeometry, isTrue);
    });
  });

  test('a stop centre known only roughly widens the radius', () {
    const rough = StopSiteAnchor(
      latitude: originLatitude,
      longitude: originLongitude,
      sigmaMeters: 12,
    );
    final decision = decide(
      fixNorth(30, speed: 0, speedAccuracy: 2),
      stop: const StopContext(stillEpisodeActive: false, site: rough),
    );
    expect(decision.rejectionReason, FixQualityIssue.stationaryHold);
  });

  test('explicit capture intents ignore the stop', () {
    const walking = FixQualityPolicy(
      TrackingConfig(captureIntent: RouteCaptureIntent.walking),
      version: 3,
    );
    final decision = decide(fixNorth(5), using: walking);
    expect(decision.acceptedForGeometry, isTrue);
    expect(decision.qualityFlags, TrackPointQualityFlag.none);
  });

  test('version 2 ignores the stop centre and anchors on the previous point',
      () {
    const version2 = FixQualityPolicy(config, version: 2);
    final decision = version2.evaluate(
      sample: fixNorth(12, speed: 0, speedAccuracy: 2),
      previous: previous,
      now: now,
      stop: const StopContext(stillEpisodeActive: true, site: centre),
    );
    // 22 m from the previous point: inside its 25 m radius.
    expect(decision.rejectionReason, FixQualityIssue.stationaryHold);
    expect(decision.policyVersion, 2);
    expect(decision.qualityFlags & TrackPointQualityFlag.duringStop, 0);
  });
}
