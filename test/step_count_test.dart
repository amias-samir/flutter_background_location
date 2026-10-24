import 'dart:convert';
import 'dart:io';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_background_location_tracker/src/storage/route_review_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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

    test('coverage and finals are read from fixes and status', () {
      final coverage = <String, Object?>{
        'state': 'stalled',
        'countedThrough': t0.millisecondsSinceEpoch,
        'lastRiseAt': t0.millisecondsSinceEpoch - 60000,
        'uncountedMs': 120000,
        'sensor': 'step_counter_wakeup',
        'reregistrations': 2,
      };
      final fix =
          LocationSample.fromMap(payload(40)..['stepCoverage'] = coverage);
      expect(fix.stepCoverage!.state, StepCoverageState.stalled);
      expect(fix.stepCoverage!.stalled, isTrue);
      expect(fix.stepCoverage!.countedThrough, t0);
      expect(
        fix.stepCoverage!.lastRiseAt,
        t0.subtract(const Duration(minutes: 1)),
      );
      expect(fix.stepCoverage!.uncounted, const Duration(minutes: 2));
      expect(fix.stepCoverage!.sensor, 'step_counter_wakeup');
      expect(fix.stepCoverage!.reregistrations, 2);
      // Android journal rows carry nested values as JSON text.
      expect(
        LocationSample.fromMap(
                payload(40)..['stepCoverage'] = jsonEncode(coverage))
            .stepCoverage!
            .state,
        StepCoverageState.stalled,
      );
      final status = TrackerStatus.fromMap(<String, Object?>{
        'lifecycle': 'paused',
        'trackId': 'track',
        'stepFinal': <String, Object?>{
          'captureGenerationId': 'generation-a',
          'stepCount': 812,
          'stepCoverage': <String, Object?>{'state': 'ended_unflushed'},
        },
        'stepCoverage': <String, Object?>{'state': 'counting'},
      });
      expect(status.stepFinal!.captureGenerationId, 'generation-a');
      expect(status.stepFinal!.stepCount, 812);
      expect(
        status.stepFinal!.coverage!.state,
        StepCoverageState.endedUnflushed,
      );
      expect(status.stepCoverage!.state, StepCoverageState.counting);
    });

    test('absent, malformed and newer coverage values are handled', () {
      expect(LocationSample.fromMap(payload(40)).stepCoverage, isNull);
      for (final malformed in <Object>[
        'counting',
        7,
        <String, Object?>{'sensor': 'pedometer'},
        <String, Object?>{'state': ''},
      ]) {
        expect(
          LocationSample.fromMap(payload(40)..['stepCoverage'] = malformed)
              .stepCoverage,
          isNull,
          reason: '$malformed',
        );
      }
      final newer = StepCoverage.fromPayload(<String, Object?>{
        'state': 'recounting',
        'countedThrough': -5,
        'uncountedMs': 'x',
        'reregistrations': -1,
      })!;
      expect(newer.state.name, 'recounting', reason: 'kept, not an error');
      expect(newer.countedThrough, isNull);
      expect(newer.uncounted, Duration.zero);
      expect(newer.reregistrations, 0);
      expect(
        StepFinal.fromPayload(<String, Object?>{'stepCount': 4}),
        isNull,
        reason: 'a final without its generation',
      );
      expect(
        StepFinal.fromPayload(
          <String, Object?>{'captureGenerationId': 'g', 'stepCount': -4},
        ),
        isNull,
      );
    });

    test('profile transitions are read in order; malformed ones are skipped',
        () {
      final transitions = LocationSample.fromMap(
        payload(40)
          ..['profileTransitions'] = <Object?>[
            <String, Object?>{
              'seq': 3,
              'at': t0.millisecondsSinceEpoch,
              'from': 'moving',
              'to': 'stationary',
              'reason': 'still_episode',
            },
            <String, Object?>{'seq': 4, 'at': 0, 'from': 'x', 'to': 'moving'},
            jsonEncode(<String, Object?>{
              'seq': 5,
              'at': t0.millisecondsSinceEpoch + 1000,
              'from': 'stationary',
              'to': 'moving',
            }),
          ],
      ).profileTransitions;
      expect(transitions.map((transition) => transition.sequence), <int>[3, 5]);
      expect(transitions.first.to, SamplingProfile.stationary);
      expect(transitions.first.reason, 'still_episode');
      expect(transitions.last.reason, isNull);
      expect(LocationSample.fromMap(payload(40)).profileTransitions, isEmpty);
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

  group('generations', () {
    late RepositoryHarness harness;
    late String trackId;
    var second = 0;

    setUp(() async {
      second = 0;
      harness = RepositoryHarness()..now = t0;
      await harness.initialize();
      trackId = await harness.createActiveTrack(trackId: 'steps');
    });
    tearDown(() => harness.repository.close());

    Future<void> fixWith(
      int steps,
      String generation, {
      StepCoverage? coverage,
    }) =>
        harness.repository.appendPoint(
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
              stepCoverage: coverage,
            ),
            activity: const ActivitySnapshot.unknown(),
            motionState: MotionState.unknown,
            accepted: true,
            qualityFlags: TrackPointQualityFlag.none,
          ),
        );
    Future<RouteSummary> summary() async =>
        (await harness.repository.routeSummary(trackId))!;

    test('a generation counts once at its highest count, in any order',
        () async {
      await fixWith(10, 'a');
      await fixWith(25, 'a');
      await fixWith(5, 'b');
      await fixWith(12, 'b');
      // A late count of the earlier generation adds only its own increase.
      await fixWith(40, 'a');
      expect((await summary()).stepCount, 52);
      await harness.repository.recordStepCount(
        trackId,
        captureGenerationId: 'a',
        stepCount: 30,
      );
      expect((await summary()).stepCount, 52, reason: 'lower than recorded');
      await harness.repository.refreshRouteSummary(trackId);
      expect((await summary()).stepCount, 52, reason: 'refresh agrees');
    });

    test(
        'a stalled counter marks the count incomplete from its last rise, '
        'and counting again clears it', () async {
      final lastRise = t0.add(const Duration(seconds: 7));
      await fixWith(
        12,
        'a',
        coverage: const StepCoverage(state: StepCoverageState.counting),
      );
      await fixWith(
        15,
        'a',
        coverage: StepCoverage(
          state: StepCoverageState.suspect,
          lastRiseAt: lastRise,
        ),
      );
      expect((await summary()).stepCountStoppedAt, isNull);
      await fixWith(
        15,
        'a',
        coverage: StepCoverage(
          state: StepCoverageState.stalled,
          lastRiseAt: lastRise,
          uncounted: const Duration(minutes: 2),
          sensor: 'step_counter_wakeup',
        ),
      );
      expect((await summary()).stepCountStoppedAt, lastRise);
      await harness.repository.refreshRouteSummary(trackId);
      expect((await summary()).stepCountStoppedAt, lastRise);
      await fixWith(
        90,
        'a',
        coverage: StepCoverage(
          state: StepCoverageState.counting,
          lastRiseAt: t0.add(const Duration(minutes: 3)),
        ),
      );
      final recovered = await summary();
      expect(recovered.stepCount, 90, reason: 'the counter caught up');
      expect(recovered.stepCountStoppedAt, isNull);
    });

    test(
        'a generation that ended without a final flush is incomplete from its '
        'last count', () async {
      await fixWith(30, 'a');
      final through = t0.add(const Duration(seconds: 20));
      await harness.repository.recordStepCount(
        trackId,
        captureGenerationId: 'a',
        stepCount: 34,
        coverage: StepCoverage(
          state: StepCoverageState.endedUnflushed,
          countedThrough: through,
        ),
      );
      final ended = await summary();
      expect(ended.stepCount, 34);
      expect(ended.stepCountStoppedAt, through);
    });

    test('coverage changes leave count-free health events', () async {
      final directory = await Directory.systemTemp.createTemp('fbl-steps-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/route.sqlite';
      await harness.repository.close();
      final fileHarness = RepositoryHarness(path: path)..now = t0;
      await fileHarness.initialize();
      harness = fileHarness;
      trackId = await fileHarness.createActiveTrack(trackId: 'steps-file');
      await fixWith(
        10,
        'a',
        coverage: const StepCoverage(state: StepCoverageState.counting),
      );
      await fixWith(
        10,
        'a',
        coverage: const StepCoverage(state: StepCoverageState.suspect),
      );
      await fixWith(
        10,
        'a',
        coverage: const StepCoverage(
          state: StepCoverageState.stalled,
          sensor: 'step_counter',
          reregistrations: 3,
        ),
      );
      // A replayed fix (same event) adds nothing.
      second -= 5;
      await fixWith(
        10,
        'a',
        coverage: const StepCoverage(state: StepCoverageState.stalled),
      );
      await fixWith(
        44,
        'a',
        coverage: const StepCoverage(state: StepCoverageState.counting),
      );
      final raw = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(raw.close);
      final rows = await raw.query(
        'tracking_health_events',
        where: "track_id = ? AND type LIKE 'step_counter_%'",
        whereArgs: <Object?>[trackId],
        orderBy: 'occurred_at',
      );
      expect(rows.map((row) => row['type']), <String>[
        'step_counter_suspect',
        'step_counter_stalled',
        'step_counter_recovered',
      ]);
      for (final row in rows) {
        final details = (jsonDecode(row['details_json']! as String) as Map)
            .cast<String, Object?>();
        expect(details.keys, isNot(contains('stepCount')));
        expect(details.values, isNot(contains(10)));
        expect(details.values, isNot(contains(44)));
      }
      expect(
        jsonDecode(rows[1]['details_json']! as String),
        <String, Object?>{
          'state': 'stalled',
          'sensor': 'step_counter',
          'reregistrations': 3,
        },
      );
    });

    test(
        'a route recording across the schema 18 upgrade counts its newest '
        'generation once', () async {
      final directory = await Directory.systemTemp.createTemp('fbl-steps-');
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/route.sqlite';
      await harness.repository.close();
      final fileHarness = RepositoryHarness(path: path)..now = t0;
      await fileHarness.initialize();
      harness = fileHarness;
      trackId = await fileHarness.createActiveTrack(trackId: 'steps-file');
      await fixWith(10, 'a');
      await fixWith(40, 'a');
      // As a schema 17 database left it: the generation only in the summary.
      final database = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(database.close);
      await database.delete('track_step_generations');
      expect((await summary()).stepCount, 40);
      await fixWith(45, 'a');
      expect((await summary()).stepCount, 45, reason: 'from the summary row');
      // The upgrade turns the summary's generation into its live row.
      await database.delete('track_step_generations');
      await RouteReviewStore.seedLiveStepGenerations(database);
      final seeded = await database.query('track_step_generations');
      expect(seeded.single['capture_generation_id'], 'a');
      expect(seeded.single['step_count'], 45);
      await fixWith(50, 'a');
      expect((await summary()).stepCount, 50);
    });
  });

  test('a stopped generation\'s final count is recorded with its coverage',
      () async {
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
    final through = lastFix.capturedAt.add(const Duration(seconds: 30));
    run.adapter.stepFinal = StepFinal(
      captureGenerationId: lastFix.captureGenerationId!,
      stepCount: lastFix.stepCount! + 41,
      coverage: StepCoverage(
        state: StepCoverageState.endedUnflushed,
        countedThrough: through,
      ),
    );
    await run.client.pauseCurrentTrack(reason: 'synthetic_pause');
    final paused = await (run.client as TrackingSummaryController)
        .routeSummary(run.trackId);
    expect(paused.stepCount, lastFix.stepCount! + 41);
    expect(paused.stepCountStoppedAt, through);
  });

  test('the native step counter diagnostics are passed through', () async {
    final run = await StopReplay.start(t0, config: const TrackingConfig());
    run.adapter.stepCounterDiagnosticEntries.add(
      StepCounterDiagnostic(at: t0, event: 'flush', sensor: 'step_counter'),
    );
    final diagnostics = await (run.client as StepCounterDiagnosticsController)
        .stepCounterDiagnostics();
    expect(diagnostics.single.event, 'flush');
    expect(diagnostics.single.sensor, 'step_counter');
  });
}
