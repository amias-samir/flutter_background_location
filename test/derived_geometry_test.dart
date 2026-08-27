import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  late RepositoryHarness harness;

  setUp(() async {
    harness = RepositoryHarness();
    await harness.initialize();
  });

  tearDown(() => harness.repository.close());

  test('Q1-05 derives per segment and deletion preserves raw coordinates',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'derived-route');
    await harness.append(trackId: trackId, latitude: 27, longitude: 85);
    await harness.append(trackId: trackId, latitude: 29, longitude: 87);
    await harness.repository.pauseTrack(trackId, reason: 'break');
    await harness.repository.prepareResume(trackId);
    await harness.repository.markTrackActive(trackId);
    await harness.append(trackId: trackId, latitude: 40, longitude: 70);
    await harness.append(trackId: trackId, latitude: 42, longitude: 72);
    await harness.repository.completeTrack(trackId, reason: 'done');

    const owner = TrackingOwner(userId: 'user-1', organizationId: 'org-1');
    final service = DerivedGeometryService(harness.repository);
    final before = await service.loadForMap(owner: owner, trackId: trackId);
    final run = await service.derive(
      owner: owner,
      trackId: trackId,
      request: const DerivedGeometryRequest(smoothingFactor: 0.5),
    );

    expect(run.status, DerivedGeometryRunStatus.completed);
    expect(run.pointCount, 4);
    final derived = await service.loadForMap(
      owner: owner,
      trackId: trackId,
      geometry: TrackGeometrySelection.derived(run.id),
    );
    expect(derived.segments, hasLength(2));
    expect(derived.segments.first.points.last.latitude, 28);
    expect(derived.segments.last.points.first.latitude, 40,
        reason: 'smoothing must restart after a pause');

    await harness.repository.deleteDerivedGeometryRun(
      owner: owner,
      trackId: trackId,
      runId: run.id,
    );
    final after = await service.loadForMap(owner: owner, trackId: trackId);
    expect(
      after.segments
          .expand((segment) => segment.points)
          .map((point) => (point.latitude, point.longitude)),
      before.segments
          .expand((segment) => segment.points)
          .map((point) => (point.latitude, point.longitude)),
    );
    expect(
      await harness.repository.listDerivedGeometryRuns(
        owner: owner,
        trackId: trackId,
      ),
      isEmpty,
    );
  });

  test('Q1-05 algorithm versions create separate immutable runs', () async {
    final trackId = await harness.createActiveTrack(trackId: 'versions');
    await harness.append(trackId: trackId, latitude: 27, longitude: 85);
    await harness.repository.completeTrack(trackId, reason: 'done');
    const owner = TrackingOwner(userId: 'user-1', organizationId: 'org-1');
    final service = DerivedGeometryService(harness.repository);

    final first = await service.derive(owner: owner, trackId: trackId);
    final second = await service.derive(
      owner: owner,
      trackId: trackId,
      request: const DerivedGeometryRequest(algorithmVersion: '2'),
    );

    expect(first.id, isNot(second.id));
    expect(first.algorithmVersion, '1');
    expect(second.algorithmVersion, '2');
    expect(
      await harness.repository.listDerivedGeometryRuns(
        owner: owner,
        trackId: trackId,
      ),
      hasLength(2),
    );
  });
}
