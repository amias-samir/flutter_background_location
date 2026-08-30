import 'dart:convert';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TrackingContinuityClassifier', () {
    test('uses positive capture evidence before fallback policy', () {
      const conservative = TrackingContinuityClassifier();

      expect(
        conservative
            .classify(
              const TrackingContinuityEvidence(
                currentAcceptedForGeometry: true,
                expectedTrackId: 'track-1',
                currentTrackId: 'track-1',
                previousCaptureGenerationId: 'generation-1',
                currentCaptureGenerationId: 'generation-1',
                nativeLifecycle: TrackerLifecycle.tracking,
                samplingProfile: SamplingProfile.stationary,
                serviceHealthy: true,
                permissionAndServiceAvailable: true,
              ),
            )
            .treatment,
        TrackingGapTreatment.retainCurrentSegment,
      );
      expect(
        conservative
            .classify(
              const TrackingContinuityEvidence(
                currentAcceptedForGeometry: true,
                expectedTrackId: 'track-1',
                currentTrackId: 'track-1',
                previousCaptureGenerationId: 'generation-1',
                currentCaptureGenerationId: 'generation-2',
                nativeLifecycle: TrackerLifecycle.tracking,
                serviceHealthy: true,
                permissionAndServiceAvailable: true,
              ),
            )
            .treatment,
        TrackingGapTreatment.startNewSegment,
      );
      expect(
        conservative
            .classify(
              const TrackingContinuityEvidence(
                currentAcceptedForGeometry: true,
                nativeLifecycle: TrackerLifecycle.tracking,
              ),
            )
            .treatment,
        TrackingGapTreatment.startNewSegment,
      );
      expect(
        const TrackingContinuityClassifier(
          policy: TrackingContinuityPolicy.preferContinuous,
        )
            .classify(
              const TrackingContinuityEvidence(
                currentAcceptedForGeometry: true,
                nativeLifecycle: TrackerLifecycle.tracking,
              ),
            )
            .treatment,
        TrackingGapTreatment.retainCurrentSegment,
      );
    });

    test('rejected fixes and explicit boundaries have different topology', () {
      const classifier = TrackingContinuityClassifier();
      final rejected = classifier.classify(
        const TrackingContinuityEvidence(
          currentAcceptedForGeometry: false,
          explicitBoundaryCause: TrackingGapCause.explicitPause,
        ),
      );
      final paused = classifier.classify(
        const TrackingContinuityEvidence(
          currentAcceptedForGeometry: true,
          explicitBoundaryCause: TrackingGapCause.explicitPause,
        ),
      );

      expect(rejected.treatment, TrackingGapTreatment.retainCurrentSegment);
      expect(rejected.cause, TrackingGapCause.acceptedFixRejectionRun);
      expect(paused.treatment, TrackingGapTreatment.startNewSegment);
      expect(paused.cause, TrackingGapCause.explicitPause);
    });

    test('automatic cause cannot override an explicit split treatment', () {
      final gap = TrackingContinuityGap(
        id: 'gap',
        trackId: 'track',
        beforePointId: 'before',
        afterPointId: 'after',
        beforeSegmentId: 'segment-1',
        afterSegmentId: 'segment-2',
        cause: TrackingGapCause.providerBatching,
        treatment: TrackingGapTreatment.startNewSegment,
        distanceTreatment: TrackingGapDistanceTreatment.excluded,
        continuityPolicyVersion: 1,
        createdAt: DateTime.utc(2026),
      );

      expect(
        const RouteGeometryAssembler()
            .decideBoundary(
              continuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
              gap: gap,
            )
            .connect,
        isFalse,
      );
    });
  });

  test(
      'shared assembler preserves lifecycle evidence unless connect-all is explicit',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    addTearDown(harness.repository.close);
    final trackId = await harness.createActiveTrack(trackId: 'topology-modes');
    await harness.append(trackId: trackId, latitude: 0, longitude: 0);
    await harness.append(trackId: trackId, latitude: 0, longitude: 0.001);
    await harness.repository.pauseTrack(trackId, reason: 'explicit_pause');
    await harness.repository.prepareResume(trackId);
    await harness.repository.markTrackActive(trackId);
    await harness.append(trackId: trackId, latitude: 1, longitude: 1);
    await harness.append(trackId: trackId, latitude: 1, longitude: 1.001);
    final bundle = await harness.repository.loadTrackBundle(trackId);
    final sources = bundle.segments.map(
      (segment) => RouteGeometrySourcePart(
        legNumber: 1,
        segment: segment.segment,
        points: segment.points,
      ),
    );
    const assembler = RouteGeometryAssembler();

    expect(
      assembler
          .assemble(
            sourceParts: sources,
            continuity: RouteGeometryContinuity.preserveEvidenceSegments,
          )
          .geometryPartCount,
      2,
    );
    expect(
      assembler
          .assemble(
            sourceParts: sources,
            continuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
          )
          .geometryPartCount,
      2,
    );
    final connected = assembler.assemble(
      sourceParts: sources,
      continuity: RouteGeometryContinuity.connectAllChronologicalPoints,
    );
    expect(connected.geometryPartCount, 1);
    expect(connected.inferredConnectorCount, 1);
  });

  test(
    '266 accepted and 53 rejected fixes across 6:25 stay one segment',
    () async {
      final fixture = jsonDecode(
        readFixture('stationary_rejection_gap_v1.json'),
      ) as Map<String, Object?>;
      expect(
        (fixture['privacy']!
            as Map<String, Object?>)['containsRealCoordinates'],
        isFalse,
      );
      expect(fixture.keys, isNot(contains('latitude')));
      expect(fixture.keys, isNot(contains('longitude')));

      final acceptedCount = fixture['acceptedPointCount']! as int;
      final rejectedCount = fixture['rejectedPointCount']! as int;
      final gap = Duration(seconds: fixture['acceptedGapSeconds']! as int);
      final clock = DeterministicTrackingClock(
        initialTime: DateTime.utc(2026, 8, 30, 12),
      );
      final harness = RepositoryHarness(
        config: const TrackingConfig(
          acceptedGeometryGapThreshold: Duration(minutes: 5),
          callbackHealthWarningThreshold: Duration(minutes: 2),
        ),
      );
      harness.now = clock();
      await harness.initialize();
      final adapter = FakeTrackerAdapter();
      final controller = await TrackingClient.openWithTrips(
        owner: const TrackingOwner(
          userId: 'synthetic-user',
          organizationId: 'synthetic-organization',
        ),
        repository: harness.repository,
        trackerAdapter: adapter,
        exportFileWriter: FakeExportFileWriter(),
        clock: () => clock().add(const Duration(hours: 1)),
      );

      final started = await controller.startTrip(
        const TripStartRequest(
          requestedTripId: 'synthetic_stationary_gap',
          routeId: 'synthetic_stationary_gap',
          config: TrackingConfig(
            acceptedGeometryGapThreshold: Duration(minutes: 5),
            callbackHealthWarningThreshold: Duration(minutes: 2),
          ),
        ),
      );
      addTearDown(() async {
        final trip = await controller.getTrip(started.trip.id);
        if (trip != null && trip.status != TripStatus.completed) {
          await controller.completeTrip(
            trip.id,
            reason: 'synthetic_test_cleanup',
          );
        }
        await controller.dispose();
      });
      final trackId = started.leg.trackId;
      const generation = 'synthetic-generation-1';
      const monotonicDomain = 'synthetic-domain-1';
      final initialAccepted = acceptedCount - 1;
      for (var index = 0; index < initialAccepted; index += 1) {
        final capturedAt = clock().add(Duration(seconds: index));
        adapter.emitLocation(
          _sample(
            trackId: trackId,
            eventId: 'accepted-$index',
            capturedAt: capturedAt,
            longitude: index * 0.0000001,
            accuracy: 5,
            generation: generation,
            monotonicDomain: monotonicDomain,
            profile: SamplingProfile.stationary,
          ),
        );
      }

      final previousAnchorAt = clock().add(
        Duration(seconds: initialAccepted - 1),
      );
      for (var index = 1; index <= rejectedCount; index += 1) {
        final offsetSeconds = index * gap.inSeconds ~/ (rejectedCount + 1);
        adapter.emitLocation(
          _sample(
            trackId: trackId,
            eventId: 'rejected-$index',
            capturedAt: previousAnchorAt.add(
              Duration(seconds: offsetSeconds),
            ),
            longitude: initialAccepted * 0.0000001,
            accuracy: 500,
            generation: generation,
            monotonicDomain: monotonicDomain,
            profile: SamplingProfile.stationary,
          ),
        );
      }
      adapter.emitLocation(
        _sample(
          trackId: trackId,
          eventId: 'accepted-after-gap',
          capturedAt: previousAnchorAt.add(gap),
          longitude: initialAccepted * 0.0000001 + 0.0001,
          accuracy: 5,
          generation: generation,
          monotonicDomain: monotonicDomain,
          profile: SamplingProfile.moving,
        ),
      );

      await _waitForTrackCounts(
        harness,
        trackId: trackId,
        accepted: acceptedCount,
        rejected: rejectedCount,
      );
      final bundle = await harness.repository.loadTrackBundle(trackId);
      final gaps = await harness.repository.listContinuityGaps(trackId);

      expect(bundle.track.acceptedPointCount, acceptedCount);
      expect(bundle.track.rejectedPointCount, rejectedCount);
      expect(
        bundle.segments,
        hasLength(fixture['expectedCanonicalSegmentCount']! as int),
      );
      expect(bundle.segments.single.points,
          hasLength(acceptedCount + rejectedCount));
      expect(gaps, isNotEmpty);
      expect(gaps.last.afterPointId, bundle.segments.single.points.last.id);
      expect(
        gaps.last.cause,
        TrackingGapCause.acceptedFixRejectionRun,
      );
      expect(
        gaps.last.treatment,
        TrackingGapTreatment.retainCurrentSegment,
      );
      expect(
        gaps.last.distanceTreatment,
        TrackingGapDistanceTreatment.excluded,
      );
    },
  );
}

LocationSample _sample({
  required String trackId,
  required String eventId,
  required DateTime capturedAt,
  required double longitude,
  required double accuracy,
  required String generation,
  required String monotonicDomain,
  required SamplingProfile profile,
}) =>
    LocationSample(
      latitude: 0,
      longitude: longitude,
      horizontalAccuracy: accuracy,
      capturedAt: capturedAt,
      provider: 'synthetic',
      eventId: eventId,
      trackId: trackId,
      nativeReceivedAt: capturedAt.add(const Duration(milliseconds: 100)),
      providerTimeDeltaMsAtReceipt: 100,
      monotonicReceivedNanos: capturedAt.microsecondsSinceEpoch * 1000,
      monotonicDomainId: monotonicDomain,
      captureGenerationId: generation,
      nativeSessionStartedAt: DateTime.utc(2026, 8, 30, 12),
      nativeLifecycle: TrackerLifecycle.tracking,
      samplingProfile: profile,
    );

Future<void> _waitForTrackCounts(
  RepositoryHarness harness, {
  required String trackId,
  required int accepted,
  required int rejected,
}) async {
  for (var attempt = 0; attempt < 500; attempt += 1) {
    final track = await harness.repository.getTrack(trackId);
    if (track?.acceptedPointCount == accepted &&
        track?.rejectedPointCount == rejected) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final track = await harness.repository.getTrack(trackId);
  fail(
    'Timed out waiting for $accepted/$rejected points; observed '
    '${track?.acceptedPointCount}/${track?.rejectedPointCount}.',
  );
}
