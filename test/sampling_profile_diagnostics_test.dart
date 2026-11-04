import 'dart:convert';
import 'dart:io';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_support.dart';

/// LBO-00B: native moving/stationary switches are recorded, with their
/// reason, so a field test can show how long a stop stayed stationary and why
/// it left.
void main() {
  group('TrackerStatus.profileTransitionReason', () {
    TrackerStatus decode(Object? reason, {bool present = true}) =>
        TrackerStatus.fromMap(<Object?, Object?>{
          'state': 'tracking',
          'samplingProfile': 'stationary',
          if (present) 'profileTransitionReason': reason,
        });

    test('is decoded when the native side reports it', () {
      expect(
        decode('entry_without_fixes').profileTransitionReason,
        'entry_without_fixes',
      );
    });

    test('is null when absent, blank or malformed', () {
      expect(decode(null, present: false).profileTransitionReason, isNull);
      expect(decode(null).profileTransitionReason, isNull);
      expect(decode('  ').profileTransitionReason, isNull);
      expect(decode(7).profileTransitionReason, isNull);
    });
  });

  test('each native profile switch becomes a health event', () async {
    final directory = await Directory.systemTemp.createTemp('fbl-profile-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/route.sqlite';
    final t0 = DateTime.utc(2026, 10, 19, 5);
    final harness = RepositoryHarness(path: path)..now = t0;
    await harness.initialize();
    final adapter = FakeTrackerAdapter();
    final client = await TrackingClient.openWithTrips(
      owner: const TrackingOwner(
        userId: 'synthetic-user',
        organizationId: 'synthetic-organization',
      ),
      repository: harness.repository,
      trackerAdapter: adapter,
      exportFileWriter: FakeExportFileWriter(),
      clock: () => t0,
    );
    final started = await client.startTrip(
      const TripStartRequest(
        requestedTripId: 'synthetic_profiles',
        routeId: 'synthetic_profiles',
        config: TrackingConfig(),
      ),
    );
    addTearDown(() async {
      await client.completeTrip(
        started.trip.id,
        reason: 'synthetic_test_cleanup',
      );
      await client.dispose();
    });
    final trackId = started.leg.trackId;

    void status(SamplingProfile profile, [String? reason]) =>
        adapter.emitStatus(
          TrackerStatus(
            lifecycle: TrackerLifecycle.tracking,
            trackId: trackId,
            samplingProfile: profile,
            profileTransitionReason: reason,
          ),
        );
    status(SamplingProfile.moving);
    status(SamplingProfile.stationary, 'entry_without_fixes');
    status(SamplingProfile.stationary, 'entry_without_fixes');
    status(SamplingProfile.moving, 'doppler');

    final raw = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(raw.close);
    var rows = <Map<String, Object?>>[];
    for (var attempt = 0; attempt < 200 && rows.length < 2; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      rows = await raw.query(
        'tracking_health_events',
        where: 'track_id = ? AND type = ?',
        whereArgs: <Object?>[trackId, 'sampling_profile_changed'],
        orderBy: 'id',
      );
    }
    final details = <Map<String, Object?>>[
      for (final row in rows)
        (jsonDecode(row['details_json']! as String) as Map)
            .cast<String, Object?>(),
    ];
    expect(details, hasLength(2), reason: 'repeats and the first are not');
    expect(
      details.map((detail) => (detail['profile'], detail['reason'])),
      containsAll(<(Object?, Object?)>[
        ('stationary', 'entry_without_fixes'),
        ('moving', 'doppler'),
      ]),
    );
    for (final detail in details) {
      expect(detail.keys.toSet(), <String>{'profile', 'reason'});
    }
  });

  test('journaled profile switches become health events once, at their time',
      () async {
    final directory = await Directory.systemTemp.createTemp('fbl-profile-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/route.sqlite';
    final t0 = DateTime.utc(2026, 10, 24, 5);
    final harness = RepositoryHarness(path: path)..now = t0;
    await harness.initialize();
    final adapter = FakeTrackerAdapter(
      protocol: NativeTrackingProtocol(
        version: 2,
        capabilityCodes: const <String>[
          NativeTrackingCapabilities.journaledDecisionInputs,
        ],
      ),
    );
    final client = await TrackingClient.openWithTrips(
      owner: const TrackingOwner(
        userId: 'synthetic-user',
        organizationId: 'synthetic-organization',
      ),
      repository: harness.repository,
      trackerAdapter: adapter,
      exportFileWriter: FakeExportFileWriter(),
      clock: () => t0,
    );
    final started = await client.startTrip(
      const TripStartRequest(
        requestedTripId: 'synthetic_journaled_profiles',
        routeId: 'synthetic_journaled_profiles',
        config: TrackingConfig(),
      ),
    );
    addTearDown(() async {
      await client.completeTrip(
        started.trip.id,
        reason: 'synthetic_test_cleanup',
      );
      await client.dispose();
    });
    final trackId = started.leg.trackId;
    final stillAt = t0.add(const Duration(seconds: 40));
    final movingAt = t0.add(const Duration(seconds: 160));
    LocationSample fix(int second, List<SamplingProfileTransition> switches) =>
        LocationSample(
          latitude: 0.5,
          longitude: 0.5 + second / 111195,
          capturedAt: t0.add(Duration(seconds: second)),
          horizontalAccuracy: 5,
          provider: 'fused',
          eventId: 'journaled-$second',
          trackId: trackId,
          captureGenerationId: 'generation-1',
          mockDetectionAvailable: true,
          profileTransitions: switches,
        );
    final switched = fix(170, <SamplingProfileTransition>[
      SamplingProfileTransition(
        sequence: 4,
        at: stillAt,
        from: SamplingProfile.moving,
        to: SamplingProfile.stationary,
        reason: 'still_episode',
      ),
      SamplingProfileTransition(
        sequence: 9,
        at: movingAt,
        from: SamplingProfile.stationary,
        to: SamplingProfile.moving,
        reason: 'doppler',
      ),
    ]);
    adapter
      ..emitLocation(switched)
      // The replay of a fix already committed.
      ..emitLocation(switched)
      // Status switches are journaled with the fixes and not recorded twice.
      ..emitStatus(
        TrackerStatus(
          lifecycle: TrackerLifecycle.tracking,
          trackId: trackId,
          samplingProfile: SamplingProfile.stationary,
          profileTransitionReason: 'still_episode',
        ),
      )
      ..emitStatus(
        TrackerStatus(
          lifecycle: TrackerLifecycle.tracking,
          trackId: trackId,
          samplingProfile: SamplingProfile.moving,
          profileTransitionReason: 'doppler',
        ),
      );

    final raw = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(raw.close);
    var rows = <Map<String, Object?>>[];
    for (var attempt = 0; attempt < 200 && rows.length < 2; attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      rows = await raw.query(
        'tracking_health_events',
        where: 'track_id = ? AND type = ?',
        whereArgs: <Object?>[trackId, 'sampling_profile_changed'],
        orderBy: 'occurred_at',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    rows = await raw.query(
      'tracking_health_events',
      where: 'track_id = ? AND type = ?',
      whereArgs: <Object?>[trackId, 'sampling_profile_changed'],
      orderBy: 'occurred_at',
    );
    expect(rows, hasLength(2));
    expect(
      rows.map((row) => DateTime.parse(row['occurred_at']! as String)),
      <DateTime>[stillAt, movingAt],
    );
    expect(
      rows.map(
        (row) => (jsonDecode(row['details_json']! as String) as Map)['reason'],
      ),
      <String>['still_episode', 'doppler'],
    );
  });
}
