import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stop_replay_support.dart';

/// D39/D53: quality policy 5 decides only from the evidence stored with each
/// fix, so a route received live and the same route drained from the native
/// journal hours later, with no activity events while Dart was detached, are
/// decided alike.
void main() {
  final t0 = DateTime.utc(2026, 10, 24, 4);

  LocationSample withReadings(
    LocationSample sample,
    List<ActivitySnapshot> readings,
  ) =>
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
        capturedActivity: readings.isEmpty ? null : readings.last,
        nativeReceivedAt: sample.nativeReceivedAt,
        providerTimeDeltaMsAtReceipt: sample.providerTimeDeltaMsAtReceipt,
        captureGenerationId: sample.captureGenerationId,
        nativeLifecycle: sample.nativeLifecycle,
        mockDetectionAvailable: true,
        activityReadings: readings,
      );

  /// Each fix carrying the readings received since the previous one, as
  /// natives with `journaled_decision_inputs` journal them.
  List<LocationSample> journaled(SyntheticTrackingRoute route) {
    final readings = route.activities.toList()
      ..sort((a, b) => a.recordedAt!.compareTo(b.recordedAt!));
    final fixes = <LocationSample>[];
    var next = 0;
    ActivitySnapshot? latest;
    for (final fix in route.locations) {
      final since = <ActivitySnapshot>[];
      while (next < readings.length &&
          !readings[next].recordedAt!.isAfter(fix.capturedAt)) {
        since.add(readings[next]);
        latest = readings[next];
        next += 1;
      }
      fixes.add(
        withReadings(
          fix,
          since.isEmpty && latest != null ? <ActivitySnapshot>[] : since,
        ),
      );
    }
    return fixes;
  }

  SyntheticTrackingRoute scenario(String trackId) {
    final arrive = syntheticWalk(
      trackId: trackId,
      from: -120,
      to: 0,
      startedAt: t0,
      eventPrefix: 'arrive',
    );
    final stopAt = arrive.locations.last.capturedAt.add(
      const Duration(seconds: 5),
    );
    final stop = SyntheticTrackingRoute.pocketStop(
      duration: const Duration(minutes: 5),
      startedAt: stopAt,
      trackId: trackId,
    );
    final leave = syntheticWalk(
      trackId: trackId,
      from: 0,
      to: 120,
      startedAt: stopAt.add(const Duration(minutes: 5, seconds: 5)),
      eventPrefix: 'leave',
      enterTransition: true,
    );
    return arrive.followedBy(stop).followedBy(leave);
  }

  String decisions(List<TrackPoint> points) => points
      .map((point) => '${point.nativeEventId}:${point.accepted}:'
          '${point.rejectionReason}')
      .join(',');

  test('a route drained from the journal is decided as it was live', () async {
    // Live: fixes arrive as captured, and the activity channel also delivers
    // readings the journal never kept.
    // Each run has its own database file (quality policy 5 is the default).
    final live = await StopReplay.start(
      t0,
      config: const TrackingConfig(),
      qualityPolicy: 5,
    );
    final liveFixes = journaled(scenario(live.trackId));
    for (final fix in liveFixes) {
      live.adapter
        ..emitActivity(
          ActivitySnapshot(
            type: TrackingActivityType.inVehicle,
            confidence: 95,
            recordedAt: fix.capturedAt.subtract(const Duration(seconds: 1)),
            source: 'android_activity_recognition',
          ),
        )
        ..emitLocation(fix);
    }
    final liveTrack = live.harness.repository;
    for (var attempt = 0; attempt < 1000; attempt += 1) {
      final track = await liveTrack.getTrack(live.trackId);
      if (track!.acceptedPointCount + track.rejectedPointCount >=
          liveFixes.length) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    // Drained: Dart was detached; the fixes wait in the journal and are
    // drained when the route pauses, with no activity events at all.
    final drained = await StopReplay.start(
      t0,
      config: const TrackingConfig(),
      qualityPolicy: 5,
    );
    final drainedFixes = journaled(scenario(drained.trackId));
    drained.adapter.pending.addAll(drainedFixes);
    await drained.client.pauseCurrentTrack(reason: 'synthetic_detached');

    List<TrackPoint> stored(TrackBundle bundle) => <TrackPoint>[
          for (final segment in bundle.segments) ...segment.points,
        ]..sort((a, b) => a.sequence.compareTo(b.sequence));
    final livePoints =
        stored(await live.harness.repository.loadTrackBundle(live.trackId));
    final drainedPoints = stored(
      await drained.harness.repository.loadTrackBundle(drained.trackId),
    );
    expect(livePoints, hasLength(liveFixes.length));
    expect(decisions(drainedPoints), decisions(livePoints));
    final liveStops = await live.harness.repository.listTrackStops(
      live.trackId,
    );
    final drainedStops = await drained.harness.repository.listTrackStops(
      drained.trackId,
    );
    expect(liveStops, hasLength(1));
    expect(
      drainedStops.map((stop) => stop.startedAt),
      liveStops.map((stop) => stop.startedAt),
    );
    expect(
      (await drained.harness.repository.getTrack(drained.trackId))!
          .totalDistanceMeters,
      closeTo(
        (await live.harness.repository.getTrack(live.trackId))!
            .totalDistanceMeters,
        1e-6,
      ),
    );
  });
}
