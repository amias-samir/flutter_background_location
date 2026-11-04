import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

/// Visible quality runs mark holes in the route, not stops or one dropped
/// fix; stop-only runs are counted apart.
void main() {
  final t0 = DateTime.utc(2026, 10, 20, 3);
  const owner = TrackingOwner(userId: 'user-1', organizationId: 'org-1');
  late RepositoryHarness harness;
  late String trackId;

  setUp(() async {
    harness = RepositoryHarness()..now = t0;
    await harness.initialize();
    trackId = await harness.createActiveTrack(trackId: 'visibility');
  });

  tearDown(() => harness.repository.close());

  PointWriteRequest fix(
    int second, {
    bool accepted = true,
    double north = 0,
    double accuracy = 4,
    double? speed,
    String? reason,
    int flags = TrackPointQualityFlag.none,
    int policy = 3,
  }) =>
      PointWriteRequest(
        trackId: trackId,
        sample: LocationSample(
          latitude: 0.5 + north / 111195,
          longitude: 0.5,
          capturedAt: t0.add(Duration(seconds: second)),
          horizontalAccuracy: accuracy,
          speed: speed,
          provider: 'fused',
          eventId: 'fix-$second',
          trackId: trackId,
        ),
        activity: const ActivitySnapshot.unknown(),
        motionState: MotionState.unknown,
        accepted: accepted,
        qualityFlags: flags,
        rejectionReason: reason,
        qualityPolicyVersion: policy,
      );

  PointWriteRequest poor(int second, {double? speed, int policy = 3}) => fix(
        second,
        accepted: false,
        accuracy: 120,
        speed: speed,
        reason: 'poor_accuracy',
        flags: TrackPointQualityFlag.poorAccuracy,
        policy: policy,
      );

  Future<TrackingQualitySummary> summary() =>
      harness.repository.trackQualitySummary(owner: owner, trackId: trackId);

  test('one dropped fix is not a visible gap from quality policy 3', () async {
    final repository = harness.repository;
    await repository.appendPoint(fix(0));
    await repository.appendPoint(poor(5, speed: 9));
    await repository.appendPoint(fix(10, north: 90));
    await repository.appendPoint(poor(15, speed: 9, policy: 2));
    await repository.appendPoint(fix(20, north: 180, policy: 2));
    final quality = await summary();
    expect(quality.qualityRunCount, 2);
    expect(quality.visibleQualityRunCount, 1,
        reason: 'only the quality policy 2 run is visible');
  });

  test('poor fixes while riding stay a visible gap', () async {
    final repository = harness.repository;
    await repository.appendPoint(fix(0));
    for (final second in <int>[5, 10, 15]) {
      await repository.appendPoint(poor(second, speed: 9));
    }
    await repository.appendPoint(fix(20, north: 180));
    expect((await summary()).visibleQualityRunCount, 1);
  });

  group('at a recorded stop', () {
    Future<void> stayWithPoorArrival({double? poorSpeed}) async {
      final repository = harness.repository;
      await repository.appendPoint(fix(0));
      for (final second in <int>[20, 40, 60]) {
        await repository.appendPoint(poor(second, speed: poorSpeed));
      }
      await repository.appendPointWithStop(
        fix(
          200,
          accepted: false,
          reason: FixQualityIssue.stationaryHold,
          flags: TrackPointQualityFlag.duringStop,
        ),
        null,
        TrackStopOpen(
          kind: TrackStopKind.dwell,
          latitude: 0.5,
          longitude: 0.5,
          centreSigmaMeters: 3,
          radiusMeters: 25,
          startedAt: t0.add(const Duration(seconds: 70)),
          qualityPolicyVersion: 3,
        ),
      );
      await repository.appendPointWithStop(
        fix(500, north: 60),
        null,
        const TrackStopClose(departure: true),
      );
    }

    test('poor fixes arriving at the place are stop evidence', () async {
      await stayWithPoorArrival(poorSpeed: 0.2);
      final quality = await summary();
      expect(quality.qualityRunCount, 1);
      expect(quality.visibleQualityRunCount, 0);
      expect(quality.stopEvidenceRunCount, 0,
          reason: 'the run also holds poor fixes');
    });

    test('poor fixes that show travel stay visible', () async {
      await stayWithPoorArrival(poorSpeed: 8);
      expect((await summary()).visibleQualityRunCount, 1);
    });
  });

  test('runs of stop holds only are counted as stop evidence', () async {
    final repository = harness.repository;
    await repository.appendPoint(fix(0));
    for (final second in <int>[10, 20, 30, 40]) {
      await repository.appendPoint(
        fix(
          second,
          accepted: false,
          reason: FixQualityIssue.stationaryHold,
          flags: TrackPointQualityFlag.duringStop,
        ),
      );
    }
    await repository.appendPoint(fix(50, north: 60));
    for (final second in <int>[55, 60, 65]) {
      await repository.appendPoint(poor(second, speed: 9));
    }
    await repository.appendPoint(fix(70, north: 240));
    final quality = await summary();
    expect(quality.qualityRunCount, 2);
    expect(quality.stopEvidenceRunCount, 1);
    expect(quality.visibleQualityRunCount, 1);
  });
}
