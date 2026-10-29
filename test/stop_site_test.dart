import 'dart:math' as math;

import 'package:flutter_background_location_tracker/src/domain/activity_snapshot.dart';
import 'package:flutter_background_location_tracker/src/domain/stop_site.dart';
import 'package:flutter_test/flutter_test.dart';

/// Quality policy 3's dwell rule: fixes that stay within the hold radius for
/// five minutes with no net progress make a stop.
void main() {
  const metersPerDegree = 111195.07973436875;
  const originLatitude = 0.5;
  const originLongitude = 0.5;
  final t0 = DateTime.utc(2026, 10, 19, 9);

  DwellFix fix(double east, double north, int seconds, {double sigma = 2}) =>
      DwellFix(
        latitude: originLatitude + north / metersPerDegree,
        longitude: originLongitude +
            east / (metersPerDegree * math.cos(originLatitude * math.pi / 180)),
        sigmaMeters: sigma,
        capturedAt: t0.add(Duration(seconds: seconds)),
      );

  test('fixes confined for five minutes without progress are a dwell', () {
    final run = DwellRun();
    final random = math.Random(1);
    for (var second = 0; second < 300; second += 10) {
      run.add(fix((random.nextDouble() - 0.5) * 20,
          (random.nextDouble() - 0.5) * 20, second));
      expect(run.dwellAnchor(), isNull, reason: 'at $second s');
    }
    run.add(fix(3, -2, 300));
    final anchor = run.dwellAnchor();
    expect(anchor, isNotNull);
    expect(
      (anchor!.latitude - originLatitude).abs() * metersPerDegree,
      lessThan(8),
    );
  });

  test('silence counts toward the dwell time', () {
    final run = DwellRun()
      ..add(fix(0, 0, 0))
      ..add(fix(4, 3, 8));
    expect(run.dwellAnchor(), isNull);
    run.add(fix(-3, 2, 300));
    expect(run.dwellAnchor(), isNotNull);
  });

  test('a slow walk with net progress never becomes a dwell', () {
    // 0.2 m/s along a straight line stays within 25 m for two minutes.
    final run = DwellRun();
    for (var second = 0; second <= 240; second += 10) {
      run.add(fix(second * 0.2, 0, second));
      expect(run.dwellAnchor(), isNull, reason: 'at $second s');
    }
    expect(
      DwellRun.trendSpeedMetersPerSecond(run.fixes),
      closeTo(0.2, 0.01),
    );
  });

  test('a fix outside the radius trims the run from the front', () {
    final run = DwellRun()
      ..add(fix(0, 0, 0))
      ..add(fix(3, 0, 10))
      ..add(fix(60, 0, 20));
    expect(run.fixes, hasLength(1), reason: 'only the far fix remains');
    expect(run.fixes.single.capturedAt, t0.add(const Duration(seconds: 20)));
  });

  test('moving evidence drops the fixes before it', () {
    final run = DwellRun()
      ..add(fix(0, 0, 0))
      ..add(fix(2, 0, 30))
      ..add(fix(1, 1, 60));
    run.dropThrough(t0.add(const Duration(seconds: 30)));
    expect(run.fixes, hasLength(1));
  });

  test('walking Doppler speeds count only when precisely measured', () {
    expect(
      StopSitePolicy.dopplerShowsMovement(speed: 0.9, speedAccuracy: 0.25),
      isTrue,
    );
    expect(
      StopSitePolicy.dopplerShowsMovement(speed: 0.9, speedAccuracy: 1.5),
      isFalse,
      reason: 'indoor speed accuracy proves nothing',
    );
    expect(
      StopSitePolicy.dopplerShowsMovement(speed: 0.2, speedAccuracy: 0.15),
      isFalse,
      reason: 'standing still',
    );
    expect(
      StopSitePolicy.dopplerShowsMovement(speed: null, speedAccuracy: 0.2),
      isFalse,
    );
  });

  test('moving evidence includes transitions out of still', () {
    ActivitySnapshot reading(
      TrackingActivityType type,
      int confidence, {
      String source = 'android_activity_recognition',
    }) =>
        ActivitySnapshot(
          type: type,
          confidence: confidence,
          recordedAt: t0,
          source: source,
        );
    bool moving(ActivitySnapshot activity) => StopSitePolicy.isMovingEvidence(
          activity,
          movingConfidenceThreshold: 60,
        );

    expect(moving(reading(TrackingActivityType.walking, 86)), isTrue);
    expect(moving(reading(TrackingActivityType.inVehicle, 71)), isFalse);
    expect(moving(reading(TrackingActivityType.unknown, 40)), isFalse);
    expect(
      moving(reading(
        TrackingActivityType.stationary,
        0,
        source: 'android_activity_transition',
      )),
      isTrue,
      reason: 'EXIT STILL',
    );
    expect(
      moving(reading(
        TrackingActivityType.stationary,
        100,
        source: 'android_activity_transition',
      )),
      isFalse,
      reason: 'ENTER STILL',
    );
  });
}
