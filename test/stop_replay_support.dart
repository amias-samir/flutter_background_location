import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_background_location_tracker/src/domain/track_geodesy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_support.dart';

// Shared replay helpers for the stop-hold and stop-site pipeline tests. Every
// coordinate is generated around a synthetic origin.

const syntheticMetersPerDegree = 111195.07973436875;
const syntheticOrigin = SyntheticTrackingRoute.syntheticOrigin;
const syntheticOwner = TrackingOwner(
  userId: 'synthetic-user',
  organizationId: 'synthetic-organization',
);

double metersFromSyntheticOrigin(TrackPoint point) =>
    TrackGeodesy.sphericalHaversineMeters(
      syntheticOrigin.latitude,
      syntheticOrigin.longitude,
      point.latitude,
      point.longitude,
    );

/// A straight walk east along the synthetic origin's latitude, from [from] to
/// [to] metres, at 1.2 m/s with a fix and a walking reading every 5 s.
SyntheticTrackingRoute syntheticWalk({
  required String trackId,
  required double from,
  required double to,
  required DateTime startedAt,
  required String eventPrefix,
  bool enterTransition = false,
}) {
  final steps = ((to - from).abs() / 6).round();
  final activities = <ActivitySnapshot>[
    if (enterTransition)
      ActivitySnapshot(
        type: TrackingActivityType.walking,
        confidence: 100,
        recordedAt: startedAt.subtract(const Duration(seconds: 1)),
        source: 'android_activity_transition',
        rawType: 'walking',
      ),
  ];
  final locations = <LocationSample>[];
  for (var step = 0; step <= steps; step += 1) {
    final at = startedAt.add(Duration(seconds: step * 5));
    final reading = ActivitySnapshot(
      type: TrackingActivityType.walking,
      confidence: 90,
      recordedAt: at.subtract(const Duration(milliseconds: 500)),
      source: 'android_activity_recognition',
      rawType: 'onFoot',
    );
    activities.add(reading);
    final east = from + (to - from) * step / steps;
    locations.add(
      LocationSample(
        latitude: syntheticOrigin.latitude,
        longitude: syntheticOrigin.longitude +
            east /
                (syntheticMetersPerDegree *
                    math.cos(syntheticOrigin.latitude * math.pi / 180)),
        capturedAt: at,
        horizontalAccuracy: 5,
        verticalAccuracy: 3,
        speed: 1.2,
        speedAccuracy: 0.2,
        provider: 'fused',
        eventId: '$eventPrefix-$step',
        trackId: trackId,
        capturedActivity: reading,
        nativeReceivedAt: at.add(const Duration(milliseconds: 100)),
        providerTimeDeltaMsAtReceipt: 100,
        captureGenerationId: 'synthetic-generation',
        nativeLifecycle: TrackerLifecycle.tracking,
        mockDetectionAvailable: true,
      ),
    );
  }
  return SyntheticTrackingRoute(locations, activities);
}

LocationSample syntheticJitterFix({
  required String trackId,
  required DateTime at,
  required double eastMeters,
  required double northMeters,
  required String eventId,
}) {
  final reading = ActivitySnapshot(
    type: TrackingActivityType.unknown,
    confidence: 40,
    recordedAt: at.subtract(const Duration(seconds: 1)),
    source: 'android_activity_recognition',
    rawType: 'unknown',
  );
  return LocationSample(
    latitude: syntheticOrigin.latitude + northMeters / syntheticMetersPerDegree,
    longitude: syntheticOrigin.longitude +
        eastMeters /
            (syntheticMetersPerDegree *
                math.cos(syntheticOrigin.latitude * math.pi / 180)),
    capturedAt: at,
    horizontalAccuracy: 3,
    verticalAccuracy: 3,
    speed: 0,
    speedAccuracy: 2.5,
    provider: 'fused',
    eventId: eventId,
    trackId: trackId,
    capturedActivity: reading,
    nativeReceivedAt: at.add(const Duration(milliseconds: 100)),
    providerTimeDeltaMsAtReceipt: 100,
    captureGenerationId: 'synthetic-generation',
    nativeLifecycle: TrackerLifecycle.tracking,
    mockDetectionAvailable: true,
  );
}

/// Emits [route] to [adapter] and returns every stored point of [trackId]
/// once all of the route's fixes are stored.
Future<List<TrackPoint>> emitAndWait(
  RepositoryHarness harness,
  FakeTrackerAdapter adapter,
  String trackId,
  SyntheticTrackingRoute route,
) async {
  final before = await harness.repository.getTrack(trackId);
  final expected = (before?.acceptedPointCount ?? 0) +
      (before?.rejectedPointCount ?? 0) +
      route.locations.length;
  route.emitChronologicallyTo(adapter);
  for (var attempt = 0; attempt < 1000; attempt += 1) {
    final track = await harness.repository.getTrack(trackId);
    if (track != null &&
        track.acceptedPointCount + track.rejectedPointCount >= expected) {
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final bundle = await harness.repository.loadTrackBundle(trackId);
  final points = <TrackPoint>[
    for (final segment in bundle.segments) ...segment.points,
  ]..sort((a, b) => a.sequence.compareTo(b.sequence));
  expect(points, hasLength(expected), reason: 'every fix is stored');
  return points;
}

final class StopReplay {
  StopReplay(
    this.harness,
    this.adapter,
    this.client,
    this.trackId, {
    this.databasePath,
  });

  final RepositoryHarness harness;
  final FakeTrackerAdapter adapter;
  final TrackingController client;
  final String trackId;

  /// The route database file, when the route is pinned to a quality policy.
  final String? databasePath;

  /// Starts a route; with [qualityPolicy], its epoch is pinned to that
  /// quality policy version, as for a route recorded by an older build, and
  /// to [continuityPolicy], by default the continuity policy such a build
  /// shipped with.
  static Future<StopReplay> start(
    DateTime t0, {
    required TrackingConfig config,
    int? qualityPolicy,
    int? continuityPolicy,
  }) async {
    final pinnedContinuity = continuityPolicy ??
        (qualityPolicy != null && qualityPolicy < 5 ? 3 : null);
    String? path;
    if (qualityPolicy != null) {
      final directory = await Directory.systemTemp.createTemp('fbl-stop-');
      addTearDown(() => directory.delete(recursive: true));
      path = '${directory.path}/route.sqlite';
    }
    final harness = RepositoryHarness(config: config, path: path)..now = t0;
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
      TripStartRequest(
        requestedTripId: 'synthetic_stop_hold',
        routeId: 'synthetic_stop_hold',
        config: config,
      ),
    );
    if (path != null) {
      final raw = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      // Epochs are immutable; lift the guard only to recreate an epoch an
      // older build wrote.
      final guards = await raw.rawQuery(
        "SELECT name, sql FROM sqlite_master WHERE type = 'trigger' "
        "AND tbl_name = 'tracking_configuration_epochs'",
      );
      for (final guard in guards) {
        await raw.execute('DROP TRIGGER ${guard['name']}');
      }
      await raw.rawUpdate(
        'UPDATE tracking_configuration_epochs SET quality_policy_version = ? '
        'WHERE track_id = ?',
        <Object?>[qualityPolicy, started.leg.trackId],
      );
      if (pinnedContinuity != null) {
        await raw.rawUpdate(
          'UPDATE tracking_configuration_epochs '
          'SET continuity_policy_version = ? WHERE track_id = ?',
          <Object?>[pinnedContinuity, started.leg.trackId],
        );
      }
      for (final guard in guards) {
        await raw.execute(guard['sql']! as String);
      }
      await raw.close();
    }
    addTearDown(() async {
      final trip = await client.getTrip(started.trip.id);
      if (trip != null && trip.status != TripStatus.completed) {
        await client.completeTrip(trip.id, reason: 'synthetic_test_cleanup');
      }
      await client.dispose();
    });
    return StopReplay(
      harness,
      adapter,
      client,
      started.leg.trackId,
      databasePath: path,
    );
  }

  /// Emits [route] as a live device would and returns every stored point.
  Future<List<TrackPoint>> replay(SyntheticTrackingRoute route) =>
      emitAndWait(harness, adapter, trackId, route);
}
