import 'dart:io';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'stop_replay_support.dart';
import 'test_support.dart';

// REL-14: a native event that fails the same way three times is committed to
// the quarantine table, then acknowledged, so it stops being replayed. Its
// evidence is kept; other fixes are unaffected.

Future<void> _waitFor(bool Function() condition) async {
  for (var attempt = 0; attempt < 300; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition was not reached.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a fix that can never be stored is quarantined, then acknowledged',
      () async {
    final t0 = DateTime.utc(2026, 11, 18, 6);
    final directory = await Directory.systemTemp.createTemp('fbl-quarantine-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/route.sqlite';
    final harness = RepositoryHarness(path: path)..now = t0;
    await harness.initialize();
    final adapter = FakeTrackerAdapter();
    final client = await TrackingClient.openWithTrips(
      owner: syntheticOwner,
      repository: harness.repository,
      trackerAdapter: adapter,
      exportFileWriter: FakeExportFileWriter(),
      clock: () => t0.add(const Duration(hours: 6)),
    );
    final started = await client.startTrip(
      const TripStartRequest(
        requestedTripId: 'quarantine',
        routeId: 'quarantine',
        config: TrackingConfig(),
      ),
    );
    final trackId = started.leg.trackId;
    final statuses = <TrackerStatus>[];
    final subscription =
        (client as TrackingController).statusStream.listen(statuses.add);

    // NaN reaches the point insert and fails its NOT NULL constraint the
    // same way every time.
    final poison = LocationSample(
      latitude: double.nan,
      longitude: 85,
      capturedAt: t0,
      horizontalAccuracy: 5,
      provider: 'fused',
      eventId: 'poison',
      trackId: trackId,
      nativeReceivedAt: t0,
    );
    int failures() => statuses
        .where((status) => status.message?.contains('persist') ?? false)
        .length;
    for (var attempt = 1; attempt <= 3; attempt += 1) {
      adapter.emitLocation(poison, durablePending: true);
      await _waitFor(() => failures() >= attempt);
      expect(statuses.last.lifecycle, isNot(TrackerLifecycle.failed));
    }
    await _waitFor(
      () => adapter.pending.every((sample) => sample.eventId != 'poison'),
    );

    // Later fixes are stored as usual.
    final walk = syntheticWalk(
      trackId: trackId,
      from: 0,
      to: 30,
      startedAt: t0.add(const Duration(seconds: 5)),
      eventPrefix: 'after',
    );
    await emitAndWait(harness, adapter, trackId, walk);
    await subscription.cancel();
    await client.completeTrip(started.trip.id, reason: 'done');
    await client.dispose();
    await harness.repository.close();

    final raw = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    final rows = await raw.query('quarantined_native_events');
    expect(rows, hasLength(1));
    expect(rows.single['event_id'], 'poison');
    expect(rows.single['track_id'], trackId);
    expect(rows.single['failure_count'], 3);
    expect(rows.single['payload_json'], contains('"longitude":85'));
    expect(rows.single['payload_json'], contains('"latitude":"NaN"'));
    final points = await raw.query(
      'track_points',
      where: 'native_event_id = ?',
      whereArgs: <Object?>['poison'],
    );
    expect(points, isEmpty, reason: 'the poison fix never became a point');
    await raw.close();
  });
}
