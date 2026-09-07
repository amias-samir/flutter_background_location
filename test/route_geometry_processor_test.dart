import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

final class _FakeProcessor implements RouteGeometryProcessor {
  @override
  String get name => 'fake-footpath-graph';

  @override
  String get version => '1';

  @override
  Future<RouteGeometryProcessorResult> process(
    RouteGeometryProcessorRequest request,
  ) async =>
      RouteGeometryProcessorResult(
        points: request.points.map(
          (point) => ProcessedRoutePoint(
            sourcePointId: point.sourcePointId,
            latitude: point.latitude + 0.00001,
            longitude: point.longitude,
            confidence: point.sequence == 2 ? 0.2 : 0.9,
          ),
        ),
      );
}

void main() {
  test('host processor is bounded and falls back for low confidence', () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    addTearDown(harness.repository.close);
    final trackId = await harness.createActiveTrack(trackId: 'processor-track');
    for (var index = 0; index < 3; index += 1) {
      await harness.append(
        trackId: trackId,
        latitude: 27 + index * 0.0001,
        longitude: 85,
      );
    }
    await harness.repository.completeTrack(trackId, reason: 'done');
    final service = DerivedGeometryService(harness.repository, pageSize: 3);
    final run = await service.deriveWithProcessor(
      owner: const TrackingOwner(userId: 'user-1', organizationId: 'org-1'),
      trackId: trackId,
      processor: _FakeProcessor(),
      overlapPointCount: 1,
    );
    expect(run.status, DerivedGeometryRunStatus.completed);
    expect(run.mapDataSource, 'fake-footpath-graph');
    final raw = await harness.repository.loadTrackBundle(trackId);
    final derived = await service.loadForMap(
      owner: const TrackingOwner(userId: 'user-1', organizationId: 'org-1'),
      trackId: trackId,
      geometry: TrackGeometrySelection.derived(run.id),
    );
    final rawPoints = raw.segments.single.points;
    final derivedPoints = derived.segments.single.points;
    expect(derivedPoints[0].latitude, greaterThan(rawPoints[0].latitude));
    expect(derivedPoints[1].latitude, rawPoints[1].latitude);
    expect(derivedPoints[2].latitude, greaterThan(rawPoints[2].latitude));
  });
}
