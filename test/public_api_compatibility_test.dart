import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_advanced.dart'
    as advanced;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy public API entrypoints remain source-compatible', () {
    final Tracking tracking = TrackingClient(
      configuration: const TrackingConfiguration(),
    );

    expect(tracking, isA<TrackingClient>());
  });

  test('advanced barrel keeps extension contracts available', () {
    expect(advanced.NativeTrackingCapabilities.pagedJournal, 'paged_journal');
    expect(
      advanced.NativeTrackingCapabilities.stagedPermissionRequests,
      'staged_permission_requests',
    );
  });

  test('stored-route actions are separate from live-session actions', () {
    final track = Track(
      id: 'track',
      userId: 'user',
      organizationId: 'org',
      routeId: 'route',
      status: TrackStatus.completed,
      startedAt: DateTime.utc(2026),
      endedAt: DateTime.utc(2026, 1, 1, 1),
      segmentCount: 1,
      nextSequence: 4,
      acceptedPointCount: 2,
      rejectedPointCount: 1,
      totalDistanceMeters: 10,
      config: const TrackingConfig(),
    );

    final actions = availableActionsFor(track);

    expect(actions.canView, isTrue);
    expect(actions.canExport, isTrue);
    expect(actions.canDelete, isTrue);
  });

  test('stop records are additive', () async {
    final stop = TrackStop(
      id: 'stop',
      trackId: 'track',
      segmentId: 'segment',
      kind: TrackStopKind.dwell,
      latitude: 0.5,
      longitude: 0.5,
      centreSigmaMeters: 2,
      radiusMeters: 25,
      startedAt: DateTime.utc(2026),
      lastSeenAt: DateTime.utc(2026, 1, 1, 0, 9),
      endedAt: DateTime.utc(2026, 1, 1, 0, 10),
      evidenceCount: 40,
      qualityPolicyVersion: 3,
    );
    expect(stop.isOpen, isFalse);
    expect(stop.duration, const Duration(minutes: 10));
    expect(TrackStopKind.still, 'still');

    // Existing bundles and export options compile unchanged.
    final bundle = TrackBundle(
      track: Track(
        id: 'track',
        userId: 'user',
        organizationId: 'org',
        routeId: 'route',
        status: TrackStatus.completed,
        startedAt: DateTime.utc(2026),
        segmentCount: 0,
        nextSequence: 1,
        acceptedPointCount: 0,
        rejectedPointCount: 0,
        totalDistanceMeters: 0,
        config: const TrackingConfig(),
      ),
      segments: const <TrackSegmentWithPoints>[],
    );
    expect(bundle.stops, isEmpty);
    expect(const TrackExportOptions().includeStops, isTrue);
    expect(const TrackExportOptions(includeStops: false).includeStops, isFalse);

    final TrackingStopController controller = _HostStops(<TrackStop>[stop]);
    expect(await controller.listTripStops('trip'), <TrackStop>[stop]);
    expect(advanced.TrackStopRepository, isNotNull);
  });

  test(
      'turn capture, the riding envelope and stop-evidence counts are '
      'additive', () {
    expect(const TrackingConfig().turnCaptureDegrees, 45);
    expect(
      const TrackingConfig(turnCaptureDegrees: 0).turnCaptureDegrees,
      0,
    );
    expect(
      TrackingConfig.defaultMaximumAcceptedAccuracyMeters(
        TrackingAccuracy.high,
        RouteCaptureIntent.vehicle,
      ),
      35,
    );
    expect(FixQualityPolicy.ridingSpeedMetersPerSecond, 5);
    const summary = TrackingQualitySummary(
      rawCallbackCount: 3,
      acceptedPointCount: 1,
      rejectedPointCount: 2,
      qualityRunCount: 1,
      visibleQualityRunCount: 0,
      continuityGapCount: 0,
      lifecycleBoundaryCount: 0,
      staleActivityCount: 0,
    );
    expect(summary.stopEvidenceRunCount, 0);
  });

  test('route summaries and step counts are additive', () async {
    final summary = RouteSummary(
      trackId: 'track',
      startedAt: DateTime.utc(2026),
      endedAt: DateTime.utc(2026, 1, 1, 2),
      distanceMeters: 7200,
      acceptedPointCount: 100,
      rejectedPointCount: 4,
      segmentCount: 2,
      recording: const Duration(minutes: 90),
      moving: const Duration(minutes: 60),
      stopped: const Duration(minutes: 30),
      stopCount: 2,
      qualityEventCount: 1,
      visibleGapCount: 0,
      stopEvidenceRunCount: 3,
      stopsSource: TrackStopSource.recorded,
      updatedAt: DateTime.utc(2026, 1, 1, 2),
    );
    expect(summary.paused, const Duration(minutes: 30));
    expect(summary.averageMovingSpeedMetersPerSecond, 2);
    expect(summary.stepCount, isNull);
    expect(TrackStopSource.derived, 'derived');

    // Existing bundles, events and points compile unchanged.
    expect(
      TripBundle(
        trip: Trip(
          id: 'trip',
          organizationId: 'org',
          userId: 'user',
          status: TripStatus.completed,
          startedAt: DateTime.utc(2026),
          legCount: 0,
          acceptedPointCount: 0,
          rejectedPointCount: 0,
          measuredDistanceMeters: 0,
          lifecycleRevision: 1,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
        legs: const <TripLeg>[],
        gaps: const <TrackingContinuityGap>[],
      ).summary,
      isNull,
    );
    expect(const TrackerStatus(lifecycle: TrackerLifecycle.idle).stepCount,
        isNull);
    expect(advanced.NativeTrackingCapabilities.stepCount, 'step_count');

    final TrackingSummaryController controller = _HostSummaries(summary);
    expect((await controller.routeSummary('track')).stopCount, 2);
    expect(advanced.RouteSummaryRepository, isNotNull);
  });
}

/// A host implementation of the optional summary capability.
final class _HostSummaries implements TrackingSummaryController {
  _HostSummaries(this._summary);

  final RouteSummary _summary;

  @override
  Future<RouteSummary> routeSummary(String trackId) async => _summary;

  @override
  Future<TripSummary> tripSummary(String tripId) => throw UnimplementedError();

  @override
  Future<DerivedGeometryRun> currentCleanedGeometry(String trackId) =>
      throw UnimplementedError();
}

/// A host implementation of the optional stop capability.
final class _HostStops implements TrackingStopController {
  _HostStops(this._stops);

  final List<TrackStop> _stops;

  @override
  Future<List<TrackStop>> listTrackStops(String trackId) async =>
      _stops.where((stop) => stop.trackId == trackId).toList();

  @override
  Future<List<TrackStop>> listTripStops(String tripId) async => _stops;
}
