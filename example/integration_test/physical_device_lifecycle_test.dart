import 'dart:math' as math;

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('enhanced fusion follows the native capture lifecycle', (
    _,
  ) async {
    const owner = TrackingOwner(
      userId: 'physical-qualification',
      organizationId: 'local-device-lab',
    );
    final tracking = await TrackingClient.open(
      owner: owner,
      configuration: const TrackingConfiguration(
        recordRetentionPolicy: TrackRecordRetentionPolicy.keepLatestOnly,
        defaultTrackingConfig: TrackingConfig(
          accuracy: TrackingAccuracy.high,
          captureIntent: RouteCaptureIntent.walking,
          motionFusionMode: MotionFusionMode.enhancedSensorFusion,
          sensorProbeDuration: Duration(seconds: 4),
          sensorProbeCooldown: Duration(seconds: 15),
          sensorProbeMaximumDurationPerHour: Duration(seconds: 60),
        ),
      ),
    );
    addTearDown(() async {
      final track = tracking.currentSession.currentTrack;
      if (track != null &&
          track.status != TrackStatus.completed &&
          track.status != TrackStatus.failed) {
        await tracking.completeCurrentTrack(reason: 'test_cleanup');
      }
      await tracking.dispose();
    });

    final readiness = await _waitForReadiness(
      tracking,
      timeout: const Duration(seconds: 45),
    );
    expect(
      readiness.canStart,
      isTrue,
      reason:
          'Grant every permission reported by readiness before running '
          'this physical-device test: ${readiness.nextAction}',
    );

    final start = await tracking.startNewTrack(
      const TrackStartRequest(
        owner: owner,
        routeId: 'physical lifecycle qualification',
        config: TrackingConfig(
          accuracy: TrackingAccuracy.high,
          captureIntent: RouteCaptureIntent.walking,
          motionFusionMode: MotionFusionMode.enhancedSensorFusion,
          sensorProbeDuration: Duration(seconds: 4),
          sensorProbeCooldown: Duration(seconds: 15),
          sensorProbeMaximumDurationPerHour: Duration(seconds: 60),
        ),
      ),
    );
    await _waitForLifecycle(
      tracking,
      TrackerLifecycle.tracking,
      timeout: const Duration(seconds: 20),
    );
    // Keep this phase long enough for an external `dumpsys sensorservice`
    // snapshot to confirm the package owns only the expected listeners.
    // ignore: avoid_print
    print('FBL_QUALIFICATION_PHASE=active');
    await Future<void>.delayed(const Duration(seconds: 45));

    await tracking.pauseCurrentTrack(reason: 'qualification_pause');
    expect(tracking.currentSession.status.lifecycle, TrackerLifecycle.paused);
    // ignore: avoid_print
    print('FBL_QUALIFICATION_PHASE=paused');
    await Future<void>.delayed(const Duration(seconds: 20));

    await tracking.resumeCurrentTrack();
    await _waitForLifecycle(
      tracking,
      TrackerLifecycle.tracking,
      timeout: const Duration(seconds: 20),
    );
    // ignore: avoid_print
    print('FBL_QUALIFICATION_PHASE=resumed');
    await Future<void>.delayed(const Duration(seconds: 45));

    await tracking.completeCurrentTrack(reason: 'qualification_completed');
    await _waitForLifecycle(
      tracking,
      TrackerLifecycle.idle,
      timeout: const Duration(seconds: 20),
    );
    // ignore: avoid_print
    print('FBL_QUALIFICATION_PHASE=completed');
    final bundle = await tracking.loadTrackBundle(start.trackId);
    final geometryDistance = _acceptedGeometryDistance(bundle);
    expect(
      bundle.track.totalDistanceMeters,
      moreOrLessEquals(geometryDistance, epsilon: 0.5),
      reason: 'Stored distance must equal accepted same-segment geometry.',
    );
    // Aggregate-only evidence: never print coordinates or owner/route IDs.
    // ignore: avoid_print
    print(
      'FBL_QUALIFICATION_AGGREGATE='
      'accepted:${bundle.track.acceptedPointCount},'
      'rejected:${bundle.track.rejectedPointCount},'
      'segments:${bundle.track.segmentCount},'
      'storedDistanceM:${bundle.track.totalDistanceMeters.toStringAsFixed(2)},'
      'geometryDistanceM:${geometryDistance.toStringAsFixed(2)}',
    );
    await Future<void>.delayed(const Duration(seconds: 5));
  }, timeout: const Timeout(Duration(minutes: 4)));
}

double _acceptedGeometryDistance(TrackBundle bundle) {
  var total = 0.0;
  for (final segment in bundle.segments) {
    final points = segment.points.where((point) => point.accepted).toList();
    for (var index = 1; index < points.length; index += 1) {
      total += _distanceMeters(points[index - 1], points[index]);
    }
  }
  return total;
}

double _distanceMeters(TrackPoint from, TrackPoint to) {
  const radius = 6371000.0;
  final latitudeDelta = _radians(to.latitude - from.latitude);
  final longitudeDelta = _radians(to.longitude - from.longitude);
  final fromLatitude = _radians(from.latitude);
  final toLatitude = _radians(to.latitude);
  final haversine =
      math.sin(latitudeDelta / 2) * math.sin(latitudeDelta / 2) +
      math.cos(fromLatitude) *
          math.cos(toLatitude) *
          math.sin(longitudeDelta / 2) *
          math.sin(longitudeDelta / 2);
  return radius *
      2 *
      math.atan2(math.sqrt(haversine), math.sqrt(1 - haversine));
}

double _radians(double degrees) => degrees * math.pi / 180;

Future<TrackingReadiness> _waitForReadiness(
  TrackingController tracking, {
  required Duration timeout,
}) async {
  var readiness = await tracking.checkReadiness();
  if (readiness.canStart) return readiness;
  // `flutter test integration_test` can reinstall the APK and therefore reset
  // runtime grants. This marker gives a device owner or host-side ADB command
  // a bounded opportunity to grant the permissions required by the protocol.
  // ignore: avoid_print
  print('FBL_QUALIFICATION_PHASE=waiting_for_permissions');
  final deadline = DateTime.now().add(timeout);
  while (!readiness.canStart && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(seconds: 1));
    readiness = await tracking.checkReadiness();
  }
  return readiness;
}

Future<void> _waitForLifecycle(
  TrackingController tracking,
  TrackerLifecycle expected, {
  required Duration timeout,
}) async {
  if (tracking.currentSession.status.lifecycle == expected) return;
  await tracking.sessionStream
      .firstWhere((session) => session.status.lifecycle == expected)
      .timeout(timeout);
}
