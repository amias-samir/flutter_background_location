import 'dart:async';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'statement_log.dart';
import 'stop_replay_support.dart';
import 'test_support.dart';

// FLT-15: the SQLite work one live fix costs. Every statement is a platform
// channel round trip on a device, inside the fsync'd append transaction or
// around it, so a regression here costs battery on every fix. The ceilings
// start at the measured cost and are lowered as the per-fix path is trimmed.

final _t0 = DateTime.utc(2026, 11, 18, 6);

final class _Pipeline {
  _Pipeline(this.log, this.harness, this.adapter, this.client, this.trackId);

  final StatementLog log;
  final RepositoryHarness harness;
  final FakeTrackerAdapter adapter;
  final TrackingTripController client;
  final String trackId;

  static Future<_Pipeline> open(RouteRecordingDetail detail) async {
    final log = StatementLog();
    final harness = RepositoryHarness(databaseFactory: log.factory())
      ..now = _t0;
    await harness.initialize();
    final adapter = FakeTrackerAdapter();
    final client = await TrackingClient.openWithTrips(
      owner: syntheticOwner,
      repository: harness.repository,
      trackerAdapter: adapter,
      exportFileWriter: FakeExportFileWriter(),
      configuration: TrackingConfiguration(recordingDetail: detail),
      clock: () => _t0.add(const Duration(hours: 6)),
    );
    final started = await client.startTrip(
      const TripStartRequest(
        requestedTripId: 'budget',
        routeId: 'budget',
        config: TrackingConfig(),
      ),
    );
    addTearDown(() async {
      await client.completeTrip(started.trip.id, reason: 'budget_cleanup');
      await client.dispose();
      await harness.repository.close();
    });
    return _Pipeline(log, harness, adapter, client, started.leg.trackId);
  }

  /// Emits [route] and waits, without touching the database, until the
  /// client has stored every fix and its trailing work has finished.
  Future<void> run(SyntheticTrackingRoute route) async {
    var stored = 0;
    final done = Completer<void>();
    final subscription = (client as TrackingController).pointStream.listen((_) {
      stored += 1;
      if (stored == route.locations.length && !done.isCompleted) {
        done.complete();
      }
    });
    route.emitChronologicallyTo(adapter);
    await done.future.timeout(const Duration(seconds: 30));
    await subscription.cancel();
    await _settle();
  }

  /// Waits until no statement has run for a few event-loop turns: session
  /// snapshots after a commit are published without being awaited.
  Future<void> _settle() async {
    var quiet = 0;
    var seen = log.roundTrips;
    while (quiet < 5) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (log.roundTrips == seen) {
        quiet += 1;
      } else {
        quiet = 0;
        seen = log.roundTrips;
      }
    }
  }
}

/// Statements and round trips per fix while [route] is recorded, after a
/// warm-up walk so caches, the decision engine and the summary rows exist.
Future<(double, double)> _perFix(
  RouteRecordingDetail detail,
  SyntheticTrackingRoute Function(String trackId) route, {
  bool steps = false,
}) async {
  final pipeline = await _Pipeline.open(detail);
  final warm = syntheticWalk(
    trackId: pipeline.trackId,
    from: 0,
    to: 60,
    startedAt: _t0,
    eventPrefix: 'warm',
  );
  await pipeline.run(steps ? _withSteps(warm, 0) : warm);
  pipeline.log.clear();
  final measured = route(pipeline.trackId);
  await pipeline.run(measured);
  final fixes = measured.locations.length;
  return (
    pipeline.log.totalStatements / fixes,
    pipeline.log.roundTrips / fixes,
  );
}

SyntheticTrackingRoute _steadyWalk(String trackId) => syntheticWalk(
      trackId: trackId,
      from: 66,
      to: 306,
      startedAt: _t0.add(const Duration(seconds: 55)),
      eventPrefix: 'steady',
    );

/// [route] with a cumulative step count on every fix, as devices with an
/// activity permission send: eight steps per five-second fix.
SyntheticTrackingRoute _withSteps(SyntheticTrackingRoute route, int first) =>
    SyntheticTrackingRoute(<LocationSample>[
      for (final (index, fix) in route.locations.indexed)
        LocationSample(
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
          capturedActivity: fix.capturedActivity,
          nativeReceivedAt: fix.nativeReceivedAt,
          providerTimeDeltaMsAtReceipt: fix.providerTimeDeltaMsAtReceipt,
          captureGenerationId: fix.captureGenerationId,
          nativeLifecycle: fix.nativeLifecycle,
          mockDetectionAvailable: fix.mockDetectionAvailable,
          stepCount: first + index * 8,
        ),
    ], route.activities);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (detail, statementCeiling, roundTripCeiling, stepStatementCeiling)
      in <(RouteRecordingDetail, double, double, double)>[
    // Before the statement diet (2026-11-18): 25 per steady fix, 35 with a
    // step count. Lower these as the per-fix path gets cheaper.
    (RouteRecordingDetail.clean, 18, 18, 24),
    (RouteRecordingDetail.full, 18, 18, 24),
  ]) {
    test('a steady walking fix stays within its SQLite budget (${detail.name})',
        () async {
      final (statements, roundTrips) = await _perFix(detail, _steadyWalk);
      // ignore: avoid_print
      print('FLT-15 ${detail.name}: ${statements.toStringAsFixed(1)} '
          'statements, ${roundTrips.toStringAsFixed(1)} round trips per fix');
      expect(statements, lessThanOrEqualTo(statementCeiling));
      expect(roundTrips, lessThanOrEqualTo(roundTripCeiling));
    });

    test(
        'a walking fix with a step count stays within its budget '
        '(${detail.name})', () async {
      final (statements, roundTrips) = await _perFix(
        detail,
        (trackId) => _withSteps(_steadyWalk(trackId), 100),
        steps: true,
      );
      // ignore: avoid_print
      print('FLT-15 ${detail.name} with steps: '
          '${statements.toStringAsFixed(1)} statements, '
          '${roundTrips.toStringAsFixed(1)} round trips per fix');
      expect(statements, lessThanOrEqualTo(stepStatementCeiling));
      expect(roundTrips, lessThanOrEqualTo(stepStatementCeiling));
    });
  }
}
