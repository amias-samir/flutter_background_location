import 'dart:math' as math;

import '../domain/activity_snapshot.dart';
import '../domain/motion_evidence.dart';
import '../domain/tracking_config.dart';

/// Pure, coordinate-free reducer shared by native fixture tests and Dart UI.
///
/// Native platforms may collect different sensor inputs, but must reduce them
/// to [MotionEvidenceObservation] semantics. No raw sensor vector or geographic
/// coordinate is accepted by this reducer.
final class MotionEvidenceReducer {
  MotionEvidenceReducer(this.config);

  static const int policyVersion = 1;

  final TrackingConfig config;
  DateTime? _lastObservedAt;
  DateTime? _stationarySince;
  int _generation = 0;
  MotionEvidenceSnapshot? _latest;

  MotionEvidenceSnapshot? get latest => _latest;

  MotionEvidenceSnapshot add(MotionEvidenceObservation observation) {
    final observedAt = observation.observedAt.toUtc();
    if (observation.generation < _generation ||
        (observation.generation == _generation &&
            _lastObservedAt != null &&
            observedAt.isBefore(_lastObservedAt!))) {
      return _latest ?? _unknown(observedAt, 'out_of_order_evidence');
    }
    if (observation.generation > _generation) {
      _generation = observation.generation;
      _stationarySince = null;
    }
    _lastObservedAt = observedAt;

    final activity = observation.activity?.evaluatedAt(
      observedAt,
      config.activityFreshnessThreshold,
    );
    final supporting = <MotionEvidenceSource>{};
    final conflicting = <MotionEvidenceSource>{};
    final activityFresh =
        activity?.evidenceState == ActivityEvidenceState.fresh;
    final activityMoving = activityFresh &&
        activity!.type.indicatesMovement &&
        activity.confidence >= config.movingConfidenceThreshold;
    final activityStationary = activityFresh &&
        activity!.type == TrackingActivityType.stationary &&
        activity.confidence >= config.stationaryConfidenceThreshold;

    final displacement = observation.gpsDisplacementMeters;
    final uncertainty = observation.gpsUncertaintyMeters;
    final gpsMoving = displacement != null &&
        displacement.isFinite &&
        displacement >= math.max(10, (uncertainty ?? 0) * 1.5);
    final gpsStill = displacement != null &&
        displacement.isFinite &&
        displacement <= math.max(3, uncertainty ?? 0);
    final accelerationQuiet = observation.accelerationMotionEnergy != null &&
        observation.accelerationMotionEnergy!.isFinite &&
        observation.accelerationMotionEnergy! < 0.18;
    final accelerationActive = observation.accelerationMotionEnergy != null &&
        observation.accelerationMotionEnergy!.isFinite &&
        observation.accelerationMotionEnergy! >= 0.35;
    final rotationQuiet = observation.rotationEnergy != null &&
        observation.rotationEnergy!.isFinite &&
        observation.rotationEnergy! < 0.20;
    final rotationActive = observation.rotationEnergy != null &&
        observation.rotationEnergy!.isFinite &&
        observation.rotationEnergy! >= 0.50;

    if (observation.stepDetected) supporting.add(MotionEvidenceSource.step);
    if (observation.significantMotionDetected) {
      supporting.add(MotionEvidenceSource.significantMotion);
    }
    if (activityMoving) supporting.add(MotionEvidenceSource.platformActivity);
    if (gpsMoving) supporting.add(MotionEvidenceSource.gpsDisplacement);

    final lowPowerEnabled =
        config.motionFusionMode != MotionFusionMode.platformActivityOnly;
    final stepMoving = lowPowerEnabled && observation.stepDetected;
    final significantMoving =
        lowPowerEnabled && observation.significantMotionDetected;
    if (stepMoving || significantMoving || activityMoving || gpsMoving) {
      _stationarySince = null;
      if (activityStationary) {
        conflicting.add(MotionEvidenceSource.platformActivity);
      }
      if (rotationActive) conflicting.add(MotionEvidenceSource.gyroscope);
      final confidence = stepMoving
          ? 95
          : significantMoving
              ? 85
              : activityMoving
                  ? activity.confidence
                  : 75;
      return _latest = MotionEvidenceSnapshot(
        state: FusedMotionState.moving,
        confidence: confidence,
        observedAt: observedAt,
        supportingSources: supporting,
        conflictingSources: conflicting,
        stepDetected: observation.stepDetected,
        significantMotionDetected: observation.significantMotionDetected,
        sensorProbeUsed: observation.sensorProbeUsed,
        policyVersion: policyVersion,
        reason: stepMoving
            ? 'fresh_step'
            : significantMoving
                ? 'significant_motion'
                : activityMoving
                    ? 'moving_activity'
                    : 'gps_displacement',
      );
    }

    final enhanced =
        config.motionFusionMode == MotionFusionMode.enhancedSensorFusion;
    final probeCorroboratesStill = !enhanced ||
        !observation.sensorProbeUsed ||
        (accelerationQuiet && rotationQuiet);
    if (activityStationary && !gpsMoving && probeCorroboratesStill) {
      supporting.add(MotionEvidenceSource.platformActivity);
      if (gpsStill) supporting.add(MotionEvidenceSource.gpsDisplacement);
      if (enhanced && observation.sensorProbeUsed) {
        supporting
          ..add(MotionEvidenceSource.accelerometer)
          ..add(MotionEvidenceSource.gyroscope);
      }
      _stationarySince ??= observedAt;
      if (observedAt.difference(_stationarySince!) >=
          config.stationaryConfirmationDuration) {
        return _latest = MotionEvidenceSnapshot(
          state: FusedMotionState.stationary,
          confidence: math.max(activity.confidence, 80),
          observedAt: observedAt,
          supportingSources: supporting,
          stepDetected: observation.stepDetected,
          significantMotionDetected: observation.significantMotionDetected,
          sensorProbeUsed: observation.sensorProbeUsed,
          policyVersion: policyVersion,
          reason: 'corroborated_stationary',
        );
      }
      return _latest = MotionEvidenceSnapshot(
        state: FusedMotionState.unknown,
        confidence: activity.confidence,
        observedAt: observedAt,
        supportingSources: supporting,
        sensorProbeUsed: observation.sensorProbeUsed,
        policyVersion: policyVersion,
        reason: 'stationary_confirmation_pending',
      );
    }

    _stationarySince = null;
    if (activityStationary && (accelerationActive || rotationActive)) {
      supporting.add(MotionEvidenceSource.platformActivity);
      if (accelerationActive) {
        conflicting.add(MotionEvidenceSource.accelerometer);
      }
      if (rotationActive) conflicting.add(MotionEvidenceSource.gyroscope);
    } else if (rotationActive) {
      // Rotation alone is never movement evidence.
      conflicting.add(MotionEvidenceSource.gyroscope);
    }
    if (observation.compassAvailable) {
      // Compass can support later turn analysis, never motion classification.
      conflicting.add(MotionEvidenceSource.compass);
    }
    return _latest = MotionEvidenceSnapshot(
      state: FusedMotionState.unknown,
      confidence: activity?.confidence ?? 0,
      observedAt: observedAt,
      supportingSources: supporting,
      conflictingSources: conflicting,
      stepDetected: observation.stepDetected,
      significantMotionDetected: observation.significantMotionDetected,
      sensorProbeUsed: observation.sensorProbeUsed,
      policyVersion: policyVersion,
      reason: activity?.evidenceState == ActivityEvidenceState.stale
          ? 'stale_activity'
          : 'conflicting_or_insufficient_evidence',
    );
  }

  MotionEvidenceSnapshot _unknown(DateTime at, String reason) =>
      MotionEvidenceSnapshot(
        state: FusedMotionState.unknown,
        confidence: 0,
        observedAt: at,
        policyVersion: policyVersion,
        reason: reason,
      );
}
