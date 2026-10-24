import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stop_replay_support.dart';

/// Every route's details are stored: stops derived once for routes recorded
/// without live stop records, and the cleaned view's distance.
void main() {
  final t0 = DateTime.utc(2026, 10, 20, 6);

  Future<StopReplay> walkStopWalk({int? qualityPolicy}) async {
    final run = await StopReplay.start(
      t0,
      config: const TrackingConfig(),
      qualityPolicy: qualityPolicy,
    );
    final arrive = syntheticWalk(
      trackId: run.trackId,
      from: -150,
      to: 0,
      startedAt: t0,
      eventPrefix: 'arrive',
    );
    final stopAt = arrive.locations.last.capturedAt.add(
      const Duration(seconds: 5),
    );
    final stop = SyntheticTrackingRoute.pocketStop(
      duration: const Duration(minutes: 6),
      startedAt: stopAt,
      trackId: run.trackId,
    );
    final leave = syntheticWalk(
      trackId: run.trackId,
      from: 0,
      to: 150,
      startedAt: stopAt.add(const Duration(minutes: 6, seconds: 5)),
      eventPrefix: 'leave',
      enterTransition: true,
    );
    await run.replay(arrive.followedBy(stop).followedBy(leave));
    return run;
  }

  Future<String> completeTrip(StopReplay run) async {
    final trips = run.client as MultiDayTripController;
    final trip = (await trips.listTripPage(
      const TripQuery(owner: syntheticOwner, limit: 1),
    ))
        .items
        .single;
    await trips.completeTrip(trip.id, reason: 'synthetic_done');
    return trip.id;
  }

  test('a route recorded without live stops gets them once it completes',
      () async {
    final run = await walkStopWalk(qualityPolicy: 2);
    final controller = run.client as TrackingSummaryController;
    final pending = await controller.routeSummary(run.trackId);
    expect(pending.stopsSource, TrackStopSource.pending,
        reason: 'derived only once the route completes');
    expect(pending.stopCount, 0);

    await completeTrip(run);
    final derived = await controller.routeSummary(run.trackId);
    expect(derived.stopsSource, TrackStopSource.derived);
    expect(derived.stopCount, 1);
    expect(derived.stopped, greaterThan(const Duration(minutes: 5)));
    final stops = await (run.client as TrackingStopController)
        .listTrackStops(run.trackId);
    expect(stops, hasLength(1));
    expect(stops.single.isOpen, isFalse);
    expect(stops.single.qualityPolicyVersion, 2);

    // Deriving again stores nothing new.
    await controller.routeSummary(run.trackId);
    expect(
      await (run.client as TrackingStopController).listTrackStops(run.trackId),
      hasLength(1),
    );
  });

  test('the cleaned view is reused while current and its distance stored',
      () async {
    final run = await walkStopWalk();
    final tripId = await completeTrip(run);
    final controller = run.client as TrackingSummaryController;
    final first = await controller.currentCleanedGeometry(run.trackId);
    final again = await controller.currentCleanedGeometry(run.trackId);
    expect(again.id, first.id);
    final geometry = run.client as TrackingGeometryController;
    expect(await geometry.listDerivedGeometry(run.trackId), hasLength(1));

    final summary = await controller.routeSummary(run.trackId);
    expect(summary.cleanedRunId, first.id);
    expect(summary.cleanedDistanceMeters, isNotNull);
    expect(summary.cleanedDistanceMeters, greaterThan(250));
    expect(
      summary.cleanedDistanceMeters,
      lessThanOrEqualTo(summary.distanceMeters + 1),
    );

    final trip = await controller.tripSummary(tripId);
    expect(trip.legCount, 1);
    expect(trip.stopCount, summary.stopCount);
    expect(trip.cleanedDistanceMeters, summary.cleanedDistanceMeters);
    expect(trip.distanceMeters, summary.distanceMeters);
  });
}
