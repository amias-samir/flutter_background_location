import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final epoch = DateTime.utc(2026, 8, 31, 8);

  ActivitySnapshot activity(
    TrackingActivityType type,
    int confidence,
    DateTime at,
  ) =>
      ActivitySnapshot(
        type: type,
        confidence: confidence,
        recordedAt: at,
        source: 'fixture',
      );

  test('fresh steps recover pocket walking from unknown activity', () {
    final reducer = MotionEvidenceReducer(
      const TrackingConfig(
        motionFusionMode: MotionFusionMode.lowPowerSensorFusion,
      ),
    );

    final result = reducer.add(
      MotionEvidenceObservation(
        observedAt: epoch,
        activity: activity(TrackingActivityType.unknown, 40, epoch),
        stepDetected: true,
      ),
    );

    expect(result.state, FusedMotionState.moving);
    expect(result.confidence, 95);
    expect(result.supportingSources, contains(MotionEvidenceSource.step));
  });

  test('rotate-in-place is not classified as movement', () {
    final reducer = MotionEvidenceReducer(
      const TrackingConfig(
        motionFusionMode: MotionFusionMode.enhancedSensorFusion,
      ),
    );

    final result = reducer.add(
      MotionEvidenceObservation(
        observedAt: epoch,
        activity: activity(TrackingActivityType.unknown, 40, epoch),
        accelerationMotionEnergy: 0.02,
        rotationEnergy: 0.9,
        compassAvailable: true,
        sensorProbeUsed: true,
      ),
    );

    expect(result.state, FusedMotionState.unknown);
    expect(result.conflictingSources, contains(MotionEvidenceSource.gyroscope));
    expect(result.conflictingSources, contains(MotionEvidenceSource.compass));
  });

  test('stationary requires the configured corroboration duration', () {
    final reducer = MotionEvidenceReducer(
      const TrackingConfig(
        motionFusionMode: MotionFusionMode.enhancedSensorFusion,
        stationaryConfirmationDuration: Duration(seconds: 20),
      ),
    );
    final first = reducer.add(
      MotionEvidenceObservation(
        observedAt: epoch,
        activity: activity(TrackingActivityType.stationary, 90, epoch),
        gpsDisplacementMeters: 1,
        gpsUncertaintyMeters: 5,
        accelerationMotionEnergy: 0.02,
        rotationEnergy: 0.02,
        sensorProbeUsed: true,
      ),
    );
    final confirmedAt = epoch.add(const Duration(seconds: 20));
    final confirmed = reducer.add(
      MotionEvidenceObservation(
        observedAt: confirmedAt,
        activity: activity(TrackingActivityType.stationary, 90, confirmedAt),
        gpsDisplacementMeters: 1,
        gpsUncertaintyMeters: 5,
        accelerationMotionEnergy: 0.02,
        rotationEnergy: 0.02,
        sensorProbeUsed: true,
      ),
    );

    expect(first.state, FusedMotionState.unknown);
    expect(confirmed.state, FusedMotionState.stationary);
  });

  test('platform-only mode ignores optional step evidence', () {
    final reducer = MotionEvidenceReducer(const TrackingConfig());
    final result = reducer.add(
      MotionEvidenceObservation(
        observedAt: epoch,
        activity: activity(TrackingActivityType.unknown, 40, epoch),
        stepDetected: true,
      ),
    );

    expect(result.state, FusedMotionState.unknown);
  });

  test('stale events and an older generation cannot replace current evidence',
      () {
    final reducer = MotionEvidenceReducer(
      const TrackingConfig(
        motionFusionMode: MotionFusionMode.lowPowerSensorFusion,
      ),
    );
    final moving = reducer.add(
      MotionEvidenceObservation(
        observedAt: epoch,
        stepDetected: true,
        generation: 2,
      ),
    );
    final ignored = reducer.add(
      MotionEvidenceObservation(
        observedAt: epoch.subtract(const Duration(seconds: 1)),
        activity: activity(
          TrackingActivityType.stationary,
          100,
          epoch.subtract(const Duration(seconds: 1)),
        ),
        generation: 1,
      ),
    );

    expect(identical(ignored, moving), isTrue);
  });

  test('vehicle vibration without corroboration remains conflicting', () {
    final reducer = MotionEvidenceReducer(
      const TrackingConfig(
        motionFusionMode: MotionFusionMode.enhancedSensorFusion,
      ),
    );
    final result = reducer.add(
      MotionEvidenceObservation(
        observedAt: epoch,
        accelerationMotionEnergy: 0.8,
        rotationEnergy: 0.7,
        sensorProbeUsed: true,
      ),
    );

    expect(result.state, FusedMotionState.unknown);
    expect(result.supportingSources, isEmpty);
  });
}
