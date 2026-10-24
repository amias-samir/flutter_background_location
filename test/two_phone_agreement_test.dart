import 'dart:math' as math;

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stop_replay_support.dart';

/// The 2026-10-24 two-phone field test as a regression test, with generated
/// coordinates: one walk recorded by two phones that differ the way the two
/// Xiaomi phones did. Quality policy 5 gives both the same stops and nearly
/// the same distance.
///
/// The truth: walk 300 m east, stop 4 minutes, walk 200 m, stop 3.5 minutes,
/// walk 200 m. Phone A samples every 10 s with a precise Doppler speed and
/// falls silent at the second stop until shortly after leaving it. Phone B
/// samples every 6 s, runs 5 m to one side, and after a 24 s silence on
/// arrival at the first stop reports three wrong fixes 100–140 m away.
void main() {
  final t0 = DateTime.utc(2026, 10, 24, 3);
  const walkSpeed = 1.25;

  /// Truth: where the person is at [second], in metres east.
  double eastAt(double second) {
    if (second <= 240) return -300 + walkSpeed * second;
    if (second <= 480) return 0;
    if (second <= 640) return walkSpeed * (second - 480);
    if (second <= 850) return 200;
    return 200 + walkSpeed * (second - 850);
  }

  bool walkingAt(double second) =>
      second < 240 || (second > 480 && second < 640) || second > 850;

  LocationSample fix(
    String trackId,
    String phone,
    int second, {
    required double east,
    double north = 0,
    required double accuracy,
    required double? speed,
    required double? speedAccuracy,
    required TrackingActivityType activity,
    int confidence = 90,
  }) {
    final at = t0.add(Duration(seconds: second));
    return LocationSample(
      latitude: syntheticOrigin.latitude + north / syntheticMetersPerDegree,
      longitude: syntheticOrigin.longitude +
          east /
              (syntheticMetersPerDegree *
                  math.cos(syntheticOrigin.latitude * math.pi / 180)),
      capturedAt: at,
      horizontalAccuracy: accuracy,
      verticalAccuracy: 3,
      speed: speed,
      speedAccuracy: speedAccuracy,
      provider: 'fused',
      eventId: '$phone-$second',
      trackId: trackId,
      capturedActivity: ActivitySnapshot(
        type: activity,
        confidence: confidence,
        recordedAt: at.subtract(const Duration(seconds: 1)),
        source: 'android_activity_recognition',
      ),
      nativeReceivedAt: at.add(const Duration(milliseconds: 200)),
      providerTimeDeltaMsAtReceipt: 200,
      captureGenerationId: '$phone-generation',
      nativeLifecycle: TrackerLifecycle.tracking,
      mockDetectionAvailable: true,
    );
  }

  /// Deterministic metre-scale wander for a still phone.
  double wander(int second, int phase) =>
      3 * math.sin((second + phase) / 23) * math.cos((second + 2 * phase) / 37);

  SyntheticTrackingRoute phoneA(String trackId) {
    final fixes = <LocationSample>[];
    for (var second = 0; second <= 1010; second += 10) {
      // Silent at the second stop after its first two fixes, until shortly
      // after leaving it.
      if (second > 660 && second < 870) continue;
      final walking = walkingAt(second.toDouble());
      fixes.add(
        fix(
          trackId,
          'a',
          second,
          east: eastAt(second.toDouble()) + (walking ? 0 : wander(second, 1)),
          north: walking ? 0 : wander(second, 7),
          accuracy: 7.5,
          speed: walking ? walkSpeed : 0.1,
          speedAccuracy: walking ? 0.3 : 0.2,
          activity: walking
              ? TrackingActivityType.walking
              : TrackingActivityType.unknown,
          confidence: walking ? 90 : 40,
        ),
      );
    }
    return SyntheticTrackingRoute(fixes, const <ActivitySnapshot>[]);
  }

  SyntheticTrackingRoute phoneB(String trackId) {
    const offset = 5.0;
    final fixes = <LocationSample>[];
    for (var second = 0; second <= 1008; second += 6) {
      // Silent for 24 s after its last moving fix before the first stop,
      // while its last walking reading is still fresh.
      if (second > 234 && second < 258) continue;
      if (second >= 258 && second <= 270) {
        // The wrong fixes after the silence, mutually consistent, with
        // degraded Doppler speeds.
        const wrong = <int, (double, double, double, double)>{
          258: (-93, 32, 0.51, 11.1),
          264: (-125, 35, 3.58, 7.1),
          270: (-133, 24, 2.81, 5.8),
        };
        final (east, north, speed, accuracy) = wrong[second]!;
        fixes.add(
          fix(trackId, 'b', second,
              east: east,
              north: north + offset,
              accuracy: 6.8,
              speed: speed,
              speedAccuracy: accuracy,
              activity: TrackingActivityType.unknown,
              confidence: 40),
        );
        continue;
      }
      final walking = walkingAt(second.toDouble());
      final secondStop = second > 640 && second <= 850;
      fixes.add(
        fix(
          trackId,
          'b',
          second,
          east: eastAt(second.toDouble()) + (walking ? 0 : wander(second, 3)),
          north: offset + (walking ? 0 : wander(second, 11)),
          accuracy: 5,
          speed: walking ? walkSpeed : 0.15,
          speedAccuracy: walking
              ? (second == 234 ? 1.6 : 0.5)
              : (second.isEven ? 2.9 : 1.8),
          activity: walking
              ? TrackingActivityType.walking
              : secondStop
                  ? TrackingActivityType.stationary
                  : TrackingActivityType.unknown,
          confidence: walking ? 90 : (secondStop ? 90 : 40),
        ),
      );
    }
    return SyntheticTrackingRoute(fixes, const <ActivitySnapshot>[]);
  }

  test(
      'two phones with different chipsets record the same stops and '
      'distance', () async {
    final a = await StopReplay.start(
      t0,
      config: const TrackingConfig(movingInterval: Duration(seconds: 10)),
      qualityPolicy: 5,
    );
    final b = await StopReplay.start(
      t0,
      config: const TrackingConfig(),
      qualityPolicy: 5,
    );
    await a.replay(phoneA(a.trackId));
    await b.replay(phoneB(b.trackId));
    for (final run in <StopReplay>[a, b]) {
      await (run.client as TrackingTripController)
          .endCurrentDay(operationId: 'agreement-end-day');
    }

    final stopsA = await a.harness.repository.listTrackStops(a.trackId);
    final stopsB = await b.harness.repository.listTrackStops(b.trackId);
    expect(stopsA, hasLength(2), reason: 'phone A');
    expect(stopsB, hasLength(2), reason: 'phone B');
    for (var index = 0; index < 2; index += 1) {
      expect(
        stopsA[index].startedAt.difference(stopsB[index].startedAt).abs(),
        lessThanOrEqualTo(const Duration(seconds: 60)),
        reason: 'stop ${index + 1} starts together',
      );
      expect(
        stopsA[index].endedAt!.difference(stopsB[index].endedAt!).abs(),
        lessThanOrEqualTo(const Duration(seconds: 60)),
        reason: 'stop ${index + 1} ends together',
      );
    }

    final distanceA =
        (await a.harness.repository.getTrack(a.trackId))!.totalDistanceMeters;
    final distanceB =
        (await b.harness.repository.getTrack(b.trackId))!.totalDistanceMeters;
    expect(distanceA, inInclusiveRange(700 * 0.97, 700 * 1.03));
    expect(distanceB, inInclusiveRange(700 * 0.97, 700 * 1.03));

    final summaryA = (await a.harness.repository.routeSummary(a.trackId))!;
    final summaryB = (await b.harness.repository.routeSummary(b.trackId))!;
    expect(summaryA.qualityEventCount, summaryB.qualityEventCount);
    expect(summaryA.visibleGapCount, summaryB.visibleGapCount);
  });
}
