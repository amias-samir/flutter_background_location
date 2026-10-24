import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stop_replay_support.dart';
import 'test_support.dart';

/// Steps counted by the native step counter, kept with the route.
void main() {
  final t0 = DateTime.utc(2026, 10, 20, 7);

  group('payloads', () {
    Map<String, Object?> payload([Object? steps]) => <String, Object?>{
          'lat': 0.5,
          'lon': 0.5,
          'timestamp': t0.millisecondsSinceEpoch,
          'accuracy': 4.0,
          if (steps != null) 'stepCount': steps,
        };

    test('a whole, non-negative count is read', () {
      expect(LocationSample.fromMap(payload(1250)).stepCount, 1250);
      expect(LocationSample.fromMap(payload(12.0)).stepCount, 12);
    });

    test('absent, legacy and malformed counts are null', () {
      expect(LocationSample.fromMap(payload()).stepCount, isNull);
      for (final malformed in <Object>['12', -3, 4.5, double.nan, true]) {
        expect(
          LocationSample.fromMap(payload(malformed)).stepCount,
          isNull,
          reason: '$malformed',
        );
      }
    });

    test('status reports the count with its generation', () {
      final status = TrackerStatus.fromMap(<String, Object?>{
        'lifecycle': 'tracking',
        'trackId': 'track',
        'stepCount': 40,
        'captureGenerationId': 'generation-a',
      });
      expect(status.stepCount, 40);
      expect(status.captureGenerationId, 'generation-a');
      expect(
        TrackerStatus.fromMap(const <String, Object?>{'lifecycle': 'idle'})
            .stepCount,
        isNull,
      );
    });
  });

  test('segments add each generation once, and a final count from status',
      () async {
    final harness = RepositoryHarness()..now = t0;
    await harness.initialize();
    addTearDown(harness.repository.close);
    final trackId = await harness.createActiveTrack(trackId: 'steps');
    final repository = harness.repository;
    var second = 0;
    Future<void> fixWith(int steps, String generation) =>
        repository.appendPoint(
          PointWriteRequest(
            trackId: trackId,
            sample: LocationSample(
              latitude: 0.5 + second / 111195,
              longitude: 0.5,
              capturedAt: t0.add(Duration(seconds: second += 5)),
              horizontalAccuracy: 4,
              provider: 'fused',
              eventId: 'fix-$second',
              trackId: trackId,
              captureGenerationId: generation,
              stepCount: steps,
            ),
            activity: const ActivitySnapshot.unknown(),
            motionState: MotionState.unknown,
            accepted: true,
            qualityFlags: TrackPointQualityFlag.none,
          ),
        );
    Future<int?> steps() async =>
        (await repository.routeSummary(trackId))!.stepCount;

    expect(await steps(), isNull, reason: 'nothing counted yet');
    await fixWith(10, 'a');
    await fixWith(25, 'a');
    await fixWith(40, 'a');
    expect(await steps(), 40);
    // A new capture session counts from its own start.
    await fixWith(5, 'b');
    await fixWith(12, 'b');
    expect(await steps(), 52);
    // A replayed older count adds nothing.
    await fixWith(11, 'b');
    expect(await steps(), 52);
    // The final count read from status before capture stops...
    await repository.recordStepCount(
      trackId,
      captureGenerationId: 'b',
      stepCount: 20,
    );
    expect(await steps(), 60);
    // ...is not counted again by a fix journaled after it.
    await fixWith(18, 'b');
    expect(await steps(), 60);
    expect((await repository.tripSummary(trackId))!.stepCount, 60);
    final points = (await repository.loadTrackBundle(trackId))
        .segments
        .expand((segment) => segment.points);
    expect(points.map((point) => point.stepCount), contains(40));
  });

  test('pausing records the steps after the newest fix', () async {
    final run = await StopReplay.start(t0, config: const TrackingConfig());
    final walk = syntheticWalk(
      trackId: run.trackId,
      from: 0,
      to: 60,
      startedAt: t0,
      eventPrefix: 'walk',
    );
    final counted = SyntheticTrackingRoute(
      <LocationSample>[
        for (final (index, sample) in walk.locations.indexed)
          LocationSample(
            latitude: sample.latitude,
            longitude: sample.longitude,
            capturedAt: sample.capturedAt,
            horizontalAccuracy: sample.horizontalAccuracy,
            verticalAccuracy: sample.verticalAccuracy,
            speed: sample.speed,
            speedAccuracy: sample.speedAccuracy,
            provider: sample.provider,
            eventId: sample.eventId,
            trackId: sample.trackId,
            capturedActivity: sample.capturedActivity,
            captureGenerationId: sample.captureGenerationId,
            nativeLifecycle: sample.nativeLifecycle,
            mockDetectionAvailable: true,
            stepCount: index * 8,
          ),
      ],
      walk.activities,
    );
    await run.replay(counted);
    final lastFix = counted.locations.last;
    expect(
      (await run.harness.repository.routeSummary(run.trackId))!.stepCount,
      lastFix.stepCount,
    );
    run.adapter
      ..stepCount = lastFix.stepCount! + 30
      ..stepCaptureGenerationId = lastFix.captureGenerationId;
    await run.client.pauseCurrentTrack(reason: 'synthetic_pause');
    expect(
      (await (run.client as TrackingSummaryController)
              .routeSummary(run.trackId))
          .stepCount,
      lastFix.stepCount! + 30,
    );
  });
}
