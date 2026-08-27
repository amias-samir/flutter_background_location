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
}
