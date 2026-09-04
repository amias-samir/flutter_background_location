import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  test('schema 13 persists bounded activity/motion evidence and quality runs',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    addTearDown(harness.repository.close);
    final trackId = await harness.createActiveTrack(trackId: 'quality-track');
    final start = DateTime.utc(2026, 8, 31, 8);

    Future<void> append(int sequence, {required bool accepted}) async {
      final capturedAt = start.add(Duration(seconds: sequence * 10));
      await harness.repository.appendPoint(
        PointWriteRequest(
          trackId: trackId,
          sample: LocationSample(
            latitude: 27 + sequence * 0.00001,
            longitude: 85,
            capturedAt: capturedAt,
            horizontalAccuracy: accepted ? 5 : 45,
            capturedMotionEvidence: MotionEvidenceSnapshot(
              state: FusedMotionState.moving,
              confidence: 95,
              observedAt: capturedAt,
              supportingSources: const <MotionEvidenceSource>{
                MotionEvidenceSource.step,
              },
              stepDetected: true,
              reason: 'fresh_step',
              generation: 1,
            ),
          ),
          activity: ActivitySnapshot(
            type: TrackingActivityType.unknown,
            confidence: 40,
            recordedAt: capturedAt.subtract(const Duration(minutes: 2)),
            source: 'android_activity_recognition',
            rawType: 'unknown',
            probabilities: const <TrackingActivityType, int>{
              TrackingActivityType.unknown: 40,
            },
          ),
          motionState: MotionState.moving,
          accepted: accepted,
          qualityFlags: accepted
              ? TrackPointQualityFlag.none
              : TrackPointQualityFlag.poorAccuracy,
          rejectionReason: accepted ? null : 'poor_accuracy',
        ),
      );
    }

    await append(0, accepted: true);
    await append(1, accepted: false);
    await append(2, accepted: false);
    await append(3, accepted: false);
    await append(4, accepted: true);

    final bundle = await harness.repository.loadTrackBundle(trackId);
    expect(bundle.segments.single.points.last.activityEvidenceState,
        ActivityEvidenceState.stale);
    expect(bundle.segments.single.points.last.motionEvidenceId, isNotNull);
    final summary = await harness.repository.trackQualitySummary(
      owner: const TrackingOwner(userId: 'user-1', organizationId: 'org-1'),
      trackId: trackId,
    );
    expect(summary.rawCallbackCount, 5);
    expect(summary.acceptedPointCount, 2);
    expect(summary.rejectedPointCount, 3);
    expect(summary.qualityRunCount, 1);
    expect(summary.visibleQualityRunCount, 1);
    expect(summary.staleActivityCount, 5);
    expect(summary.rejectedAccuracyP50Meters, 45);
  });
}
