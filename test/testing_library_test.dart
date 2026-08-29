import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('public fake supports the complete host lifecycle', () async {
    final now = DateTime.utc(2026, 8, 25, 10);
    final owner = TrackingOwner(userId: 'user', organizationId: 'org');
    final controller = FakeTrackingController(owner: owner, clock: () => now);

    expect((await controller.checkReadiness()).canStart, isTrue);
    final started = await controller.startNewTrack(
      TrackStartRequest(owner: owner, routeId: 'morning route'),
    );
    controller.emitPoint(latitude: 27.7172, longitude: 85.3240);
    expect(controller.currentSession.allowedActions.canPause, isTrue);

    await controller.pauseCurrentTrack();
    expect(controller.currentSession.allowedActions.canResume, isTrue);
    await controller.resumeCurrentTrack();
    await controller.completeCurrentTrack();

    final route = await controller.getTrack(started.trackId);
    expect(route?.status, TrackStatus.completed);
    expect((await controller.loadTrackBundle(started.trackId)).segments,
        isNotEmpty);
    expect(
      controller.calls.map((call) => call.method),
      containsAllInOrder(<String>[
        'checkReadiness',
        'startNewTrack',
        'pause',
        'resume',
        'complete',
      ]),
    );

    await controller.dispose();
  });

  test('fake adapter records read-only readiness without prompting', () async {
    final adapter = FakeTrackerAdapter();
    await adapter.initialize();
    await adapter.permissions();
    expect(
      adapter.calls
          .where((call) => call.method == 'permissions')
          .single
          .arguments,
      <String, Object?>{'request': false},
    );
    await adapter.dispose();
  });

  test('deterministic clock advances wall and monotonic time together', () {
    final clock = DeterministicTrackingClock(
      initialTime: DateTime.utc(2026),
      initialMonotonicNanos: 100,
    );

    clock.advance(const Duration(milliseconds: 2));

    expect(clock(), DateTime.utc(2026).add(const Duration(milliseconds: 2)));
    expect(clock.monotonicNanos(), 2000100);
  });

  test('synthetic producer and native fault schedule are deterministic',
      () async {
    final adapter = FakeTrackerAdapter();
    final locations = <LocationSample>[];
    final subscription = adapter.locationStream.listen(locations.add);
    SyntheticTrackingRoute.walking(pointCount: 3).emitTo(adapter);
    await Future<void>.delayed(Duration.zero);
    expect(locations.map((sample) => sample.eventId),
        <String>['synthetic-0', 'synthetic-1', 'synthetic-2']);

    adapter.failures['start'] = const TrackingNativeException(
      code: 'injected_start_failure',
      message: 'Injected by host test.',
    );
    await expectLater(
      adapter.start(trackId: 'track', config: const TrackingConfig()),
      throwsA(isA<TrackingNativeException>()),
    );
    await subscription.cancel();
    await adapter.dispose();
  });

  test('fake route bundle preserves separate pause/resume segments', () async {
    const owner = TrackingOwner(userId: 'user', organizationId: 'org');
    final controller = FakeTrackingController(owner: owner);
    final started = await controller.startNewTrack(
      const TrackStartRequest(owner: owner),
    );
    controller.emitPoint(latitude: 0, longitude: 0);
    await controller.pauseCurrentTrack();
    await controller.resumeCurrentTrack();
    controller.emitPoint(latitude: 10, longitude: 10);
    await controller.completeCurrentTrack();

    final bundle = await controller.loadTrackBundle(started.trackId);
    expect(bundle.segments, hasLength(2));
    expect(bundle.segments.first.points.single.latitude, 0);
    expect(bundle.segments.last.points.single.latitude, 10);
    await controller.dispose();
  });
}
