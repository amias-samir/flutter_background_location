import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_background_location_tracker/src/application/point_ingest.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'stop_replay_support.dart';

// FLT-02/07: fixes that queue up (a journal page, a delivery burst) are
// stored in one transaction with one acknowledgement. Every stored row must
// equal what storing them one by one produces.

final _t0 = DateTime.utc(2026, 11, 18, 6);

/// Each fix carries the readings since the previous one, as journaled.
List<LocationSample> _journaled(SyntheticTrackingRoute route) {
  final readings = route.activities.toList()
    ..sort((a, b) => a.recordedAt!.compareTo(b.recordedAt!));
  final fixes = <LocationSample>[];
  var next = 0;
  for (final (index, fix) in route.locations.indexed) {
    final since = <ActivitySnapshot>[];
    while (next < readings.length &&
        !readings[next].recordedAt!.isAfter(fix.capturedAt)) {
      since.add(readings[next]);
      next += 1;
    }
    fixes.add(LocationSample(
      latitude: fix.latitude,
      longitude: fix.longitude,
      capturedAt: fix.capturedAt,
      horizontalAccuracy: fix.horizontalAccuracy,
      verticalAccuracy: fix.verticalAccuracy,
      speed: fix.speed,
      speedAccuracy: fix.speedAccuracy,
      provider: fix.provider,
      eventId: fix.eventId,
      trackId: fix.trackId,
      capturedActivity: since.isEmpty ? fix.capturedActivity : since.last,
      nativeReceivedAt: fix.nativeReceivedAt,
      providerTimeDeltaMsAtReceipt: fix.providerTimeDeltaMsAtReceipt,
      captureGenerationId: fix.captureGenerationId,
      nativeLifecycle: fix.nativeLifecycle,
      mockDetectionAvailable: true,
      activityReadings: since,
      stepCount: 100 + index * 7,
    ));
  }
  return fixes;
}

/// Arrive, stay six minutes (held fixes and a stop), walk on.
List<LocationSample> _route(String trackId) {
  final arrive = syntheticWalk(
    trackId: trackId,
    from: -150,
    to: 0,
    startedAt: _t0,
    eventPrefix: 'arrive',
  );
  final stopAt = arrive.locations.last.capturedAt.add(
    const Duration(seconds: 5),
  );
  final stop = SyntheticTrackingRoute.pocketStop(
    duration: const Duration(minutes: 6),
    startedAt: stopAt,
    trackId: trackId,
  );
  final leave = syntheticWalk(
    trackId: trackId,
    from: 0,
    to: 180,
    startedAt: stopAt.add(const Duration(minutes: 6, seconds: 5)),
    eventPrefix: 'leave',
    enterTransition: true,
  );
  return _journaled(arrive.followedBy(stop).followedBy(leave));
}

/// Everything stored for the route, without generated row IDs.
Future<Map<String, Object?>> _stored(StopReplay run) async {
  final repository = run.harness.repository;
  final bundle = await repository.loadTrackBundle(run.trackId);
  final segmentNumbers = <String, int>{
    for (final segment in bundle.segments)
      segment.segment.id: segment.segment.segmentNumber,
  };
  final points = <TrackPoint>[
    for (final segment in bundle.segments) ...segment.points,
  ]..sort((a, b) => a.sequence.compareTo(b.sequence));
  final summary = (await repository.routeSummary(run.trackId))!;
  return <String, Object?>{
    'points': <String>[
      for (final point in points)
        '${point.nativeEventId}|${point.sequence}|'
            '${segmentNumbers[point.segmentId]}|${point.accepted}|'
            '${point.rejectionReason}|${point.qualityFlags}|'
            '${point.qualityPolicyVersion}|${point.latitude}|'
            '${point.longitude}|${point.stepCount}',
    ],
    'gaps': <String>[
      for (final gap in await repository.listContinuityGaps(run.trackId))
        '${gap.cause.name}|${gap.treatment.name}|'
            '${gap.continuityPolicyVersion}',
    ],
    'stops': <String>[
      for (final stop in await repository.listTrackStops(run.trackId))
        '${stop.kind}|${stop.startedAt}|${stop.lastSeenAt}|${stop.endedAt}|'
            '${stop.firstSequence}|${stop.lastSequence}|${stop.evidenceCount}|'
            '${stop.latitude}|${stop.longitude}',
    ],
    'summary': <Object?>[
      summary.distanceMeters,
      summary.acceptedPointCount,
      summary.rejectedPointCount,
      summary.segmentCount,
      summary.recording,
      summary.moving,
      summary.stopped,
      summary.stopCount,
      summary.maxSpeedMetersPerSecond,
      summary.stepCount,
      summary.qualityEventCount,
      summary.stopEvidenceRunCount,
      summary.visibleGapCount,
      summary.firstFixAt,
      summary.lastFixAt,
    ],
  };
}

int _acknowledgementCalls(FakeTrackerAdapter adapter) =>
    adapter.calls.where((call) => call.method == 'acknowledgeLocations').length;

/// Records the route live: every fix is delivered at once, as a provider
/// batch or a burst after a pause in delivery would.
Future<(Map<String, Object?>, int)> _live({int? batchLimit}) async {
  pointBatchLimit = batchLimit;
  final run = await StopReplay.start(
    _t0,
    config: const TrackingConfig(),
    qualityPolicy: 5,
  );
  final fixes = _route(run.trackId);
  // The first fix warms the route's epoch; the rest arrive together.
  final emitted = <String>[];
  final subscription = run.client.pointStream.listen(
    (point) => emitted.add(point.nativeEventId!),
  );
  run.adapter.emitLocation(fixes.first);
  await _until(() => emitted.length == 1);
  for (final fix in fixes.skip(1)) {
    run.adapter.emitLocation(fix);
  }
  await _until(() => emitted.length == fixes.length);
  await subscription.cancel();
  expect(emitted, fixes.map((fix) => fix.eventId), reason: 'in order');
  final calls = _acknowledgementCalls(run.adapter);
  return (await _stored(run), calls);
}

/// Replays the route from the native journal, as after a detached engine.
Future<Map<String, Object?>> _drained({int? batchLimit}) async {
  pointBatchLimit = batchLimit;
  final run = await StopReplay.start(
    _t0,
    config: const TrackingConfig(),
    qualityPolicy: 5,
  );
  run.adapter.pending.addAll(_route(run.trackId));
  await run.client.pauseCurrentTrack(reason: 'synthetic_detached');
  expect(run.adapter.pending, isEmpty, reason: 'every fix acknowledged');
  return _stored(run);
}

Future<void> _until(bool Function() condition) async {
  for (var attempt = 0; attempt < 1000; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition was not reached.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => pointBatchLimit = null);

  test(
      'a live burst stores the same rows as fix by fix, acknowledged in '
      'batches', () async {
    final (perFix, perFixAcks) = await _live(batchLimit: 1);
    final (batched, batchedAcks) = await _live();
    expect(batched, perFix);
    final fixes = (perFix['points']! as List).length;
    expect(perFixAcks, fixes, reason: 'one acknowledgement per fix');
    // A fix or two go alone while the burst is still arriving; the rest are
    // stored and acknowledged 25 at a time.
    expect(batchedAcks, lessThanOrEqualTo(3 + fixes ~/ 25),
        reason: 'one acknowledgement per batch of up to 25');
  });

  test('a journal drain stores the same rows as fix by fix', () async {
    expect(await _drained(), await _drained(batchLimit: 1));
  });

  test('a fix that fails inside a batch leaves the same rows as fix by fix',
      () async {
    Future<Map<String, Object?>> withPoison({int? batchLimit}) async {
      pointBatchLimit = batchLimit;
      final run = await StopReplay.start(
        _t0,
        config: const TrackingConfig(),
        qualityPolicy: 5,
      );
      final fixes = _route(run.trackId);
      final poison = fixes[20];
      // The point insert of one fix always fails, mid-batch.
      final raw = await databaseFactoryFfi.openDatabase(
        run.databasePath!,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await raw.execute('''
        CREATE TRIGGER poison_fix BEFORE INSERT ON track_points
        WHEN NEW.native_event_id = '${poison.eventId}'
        BEGIN SELECT RAISE(ABORT, 'poison'); END
      ''');
      await raw.close();
      final emitted = <String>[];
      final subscription = run.client.pointStream.listen(
        (point) => emitted.add(point.nativeEventId!),
      );
      run.adapter.emitLocation(fixes.first);
      await _until(() => emitted.length == 1);
      for (final fix in fixes.skip(1)) {
        run.adapter.emitLocation(fix);
      }
      await _until(() => emitted.length == fixes.length - 1);
      await subscription.cancel();
      expect(emitted, isNot(contains(poison.eventId)));
      return _stored(run);
    }

    expect(await withPoison(), await withPoison(batchLimit: 1));
  });
}
