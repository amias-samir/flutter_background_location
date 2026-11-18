import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'statement_log.dart';
import 'test_support.dart';

// FLT-25: a later cleaning run copies the closed segments the previous
// equivalent run covered and derives only the rest; the result equals a
// full derivation.

void main() {
  test('closed segments are copied and the result equals a full derivation',
      () async {
    final log = StatementLog();
    final harness = RepositoryHarness(databaseFactory: log.factory());
    await harness.initialize();
    const owner = TrackingOwner(userId: 'user-1', organizationId: 'org-1');
    final trackId = await harness.createActiveTrack(trackId: 'cleaned');
    var step = 0;
    Future<void> walk(int fixes) async {
      for (var i = 0; i < fixes; i += 1, step += 1) {
        harness.now = harness.now.add(const Duration(seconds: 5));
        await harness.append(
          trackId: trackId,
          latitude: 27 + step * 0.00005,
          longitude: 85 + (step.isEven ? 0.00001 : -0.00001),
          capturedAt: harness.now,
        );
      }
    }

    Future<void> pauseAndResume() async {
      await harness.repository.pauseTrack(trackId, reason: 'break');
      harness.now = harness.now.add(const Duration(minutes: 1));
      await harness.repository.prepareResume(trackId);
      await harness.repository.markTrackActive(trackId);
    }

    await walk(40);
    await pauseAndResume();
    await walk(40);
    await pauseAndResume();
    await walk(20);

    final service = DerivedGeometryService(harness.repository);
    const request = DerivedGeometryRequest(
      name: 'cleaned',
      algorithm: DerivedGeometryAlgorithm.stopAwareRouteCleaning,
      algorithmVersion: DerivedGeometryAlgorithm.stopAwareRouteCleaningVersion,
    );
    final first =
        await service.derive(owner: owner, trackId: trackId, request: request);

    // More points in the open segment, then a later cleaning run.
    harness.now = harness.now.add(const Duration(minutes: 1));
    await walk(30);
    log.clear();
    final second =
        await service.derive(owner: owner, trackId: trackId, request: request);
    final copies = log.statements
        .where(
            (statement) => statement.$1.contains('SELECT ?, source_point_id'))
        .length;
    expect(copies, 2, reason: 'the two closed segments are copied');

    // A full derivation of the same points, with no run to copy from.
    for (final run in <DerivedGeometryRun>[first, second]) {
      if (run.id == second.id) continue;
      await harness.repository.deleteDerivedGeometryRun(
        owner: owner,
        trackId: trackId,
        runId: run.id,
      );
    }
    final incremental = await _points(service, owner, trackId, second.id);
    await harness.repository.deleteDerivedGeometryRun(
      owner: owner,
      trackId: trackId,
      runId: second.id,
    );
    final full =
        await service.derive(owner: owner, trackId: trackId, request: request);
    expect(incremental, await _points(service, owner, trackId, full.id));
    expect(second.pointCount, full.pointCount);
    await harness.repository.close();
  });
}

Future<List<(int, double, double)>> _points(
  DerivedGeometryService service,
  TrackingOwner owner,
  String trackId,
  String runId,
) async {
  final view = await service.loadForMap(
    owner: owner,
    trackId: trackId,
    geometry: TrackGeometrySelection.derived(runId),
  );
  return <(int, double, double)>[
    for (final segment in view.segments)
      for (final point in segment.points)
        (point.sequence, point.latitude, point.longitude),
  ];
}
