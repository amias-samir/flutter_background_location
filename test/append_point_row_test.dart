import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stop_replay_support.dart';

// FLT-04: appendPoint returns the point built from the row it inserted
// instead of reading it back. It must equal the stored row in every field.

List<Object?> _fields(TrackPoint point) => <Object?>[
      point.id,
      point.trackId,
      point.segmentId,
      point.sequence,
      point.latitude,
      point.longitude,
      point.altitude,
      point.horizontalAccuracy,
      point.verticalAccuracy,
      point.speed,
      point.speedAccuracy,
      point.heading,
      point.headingAccuracy,
      point.capturedAt,
      point.persistedAt,
      point.activityType,
      point.activityConfidence,
      point.activitySource,
      point.activityRawType,
      point.activityEvidenceState,
      point.activityAge,
      point.activityRecordedAt,
      <Object?>[
        for (final reading in point.activityReadings) reading.toStoredMap(),
      ].toString(),
      point.activityProbabilities.toString(),
      point.nativeForegroundState,
      point.screenInteractive,
      point.batterySaverActive,
      point.motionEvidenceId,
      point.motionState,
      point.provider,
      point.isMocked,
      point.mockDetectionAvailable,
      point.mockEvidence,
      point.nativeEventId,
      point.configurationEpochId,
      point.nativeReceivedAt,
      point.providerTimeDeltaMsAtReceipt,
      point.monotonicFixNanos,
      point.monotonicReceivedNanos,
      point.monotonicDomainId,
      point.captureGenerationId,
      point.nativeSessionStartedAt,
      point.nativeLifecycle,
      point.samplingProfile,
      point.stepCount,
      point.qualityPolicyVersion,
      point.accepted,
      point.qualityFlags,
      point.rejectionReason,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('appended points equal their stored rows, accepted and held', () async {
    final t0 = DateTime.utc(2026, 11, 18, 6);
    final run = await StopReplay.start(t0, config: const TrackingConfig());
    final emitted = <TrackPoint>[];
    final subscription = run.client.pointStream.listen(emitted.add);

    // A walk, a stay with jittering fixes (held as rejected evidence) and a
    // walk away cover accepted, rejected, stop and segment fields.
    await run.replay(syntheticWalk(
      trackId: run.trackId,
      from: 0,
      to: 120,
      startedAt: t0,
      eventPrefix: 'arrive',
    ));
    final stayStart = t0.add(const Duration(seconds: 110));
    await run.replay(SyntheticTrackingRoute(<LocationSample>[
      for (var i = 0; i < 40; i += 1)
        syntheticJitterFix(
          trackId: run.trackId,
          at: stayStart.add(Duration(seconds: 5 * i)),
          eastMeters: 120 + (i.isEven ? 3 : -3),
          northMeters: i % 3 == 0 ? 2 : -2,
          eventId: 'stay-$i',
        ),
    ], const <ActivitySnapshot>[]));
    final stored = await run.replay(syntheticWalk(
      trackId: run.trackId,
      from: 120,
      to: 300,
      startedAt: stayStart.add(const Duration(seconds: 210)),
      eventPrefix: 'leave',
    ));
    // A point is emitted after its commit, so the store can be complete a
    // moment before the last emission arrives.
    for (var attempt = 0;
        attempt < 200 && emitted.length < stored.length;
        attempt += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await subscription.cancel();

    expect(emitted, hasLength(stored.length));
    expect(emitted.any((point) => !point.accepted), isTrue,
        reason: 'the stay holds rejected evidence');
    final byId = <String, TrackPoint>{
      for (final point in stored) point.id: point,
    };
    for (final point in emitted) {
      expect(_fields(point), _fields(byId[point.id]!),
          reason: 'point ${point.sequence}');
    }
  });
}
