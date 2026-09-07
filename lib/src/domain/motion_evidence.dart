import 'dart:collection';

import 'activity_snapshot.dart';

/// Optional native evidence sources used to classify motion.
enum MotionEvidenceSource {
  platformActivity,
  step,
  significantMotion,
  gpsDisplacement,
  accelerometer,
  gyroscope,
  compass,
}

/// Coordinate-free result produced by the motion-evidence reducer.
enum FusedMotionState { moving, stationary, unknown }

/// One bounded, coordinate-free motion decision.
///
/// Raw accelerometer, gyroscope, or magnetometer samples are intentionally not
/// represented by this API. Native code reduces them to short-lived window
/// features before emitting a decision.
final class MotionEvidenceSnapshot {
  MotionEvidenceSnapshot({
    required this.state,
    required int confidence,
    required this.observedAt,
    Iterable<MotionEvidenceSource> supportingSources =
        const <MotionEvidenceSource>[],
    Iterable<MotionEvidenceSource> conflictingSources =
        const <MotionEvidenceSource>[],
    this.stepDetected = false,
    this.significantMotionDetected = false,
    this.sensorProbeUsed = false,
    this.policyVersion = 1,
    this.reason = 'insufficient_evidence',
    this.generation,
    this.probeDuration,
    this.accelerometerSampleCount = 0,
    this.accelerationMotionEnergy,
    this.gyroscopeSampleCount = 0,
    this.rotationEnergy,
    this.compassAvailable = false,
    this.gpsDisplacementEvidence,
    this.nativeForegroundState,
    this.screenInteractive,
    this.batterySaverActive,
  })  : confidence = confidence.clamp(0, 100),
        supportingSources = UnmodifiableSetView<MotionEvidenceSource>(
          Set<MotionEvidenceSource>.of(supportingSources),
        ),
        conflictingSources = UnmodifiableSetView<MotionEvidenceSource>(
          Set<MotionEvidenceSource>.of(conflictingSources),
        );

  /// Final motion classification.
  final FusedMotionState state;

  /// Reducer confidence from 0 to 100; this is not GPS accuracy.
  final int confidence;

  /// UTC timestamp of the newest evidence used by this decision.
  final DateTime observedAt;

  /// Evidence that supports [state].
  final UnmodifiableSetView<MotionEvidenceSource> supportingSources;

  /// Fresh evidence that disagrees with the selected state.
  final UnmodifiableSetView<MotionEvidenceSource> conflictingSources;

  /// Whether a fresh step/pedometer increment was present.
  final bool stepDetected;

  /// Whether a fresh hardware significant-motion event was present.
  final bool significantMotionDetected;

  /// Whether bounded continuous-sensor sampling contributed window features.
  final bool sensorProbeUsed;

  /// Version of the decision table used to produce this result.
  final int policyVersion;

  /// Stable coordinate-free explanation suitable for diagnostics.
  final String reason;

  /// Native listener generation used to reject delayed events.
  final int? generation;

  /// Duration of the bounded raw-sensor probe, when one ran.
  final Duration? probeDuration;

  /// Number of raw accelerometer samples reduced inside the bounded window.
  final int accelerometerSampleCount;

  /// Coordinate-free RMS/energy summary for linear acceleration.
  final double? accelerationMotionEnergy;

  /// Number of raw gyroscope samples reduced inside the bounded window.
  final int gyroscopeSampleCount;

  /// Coordinate-free rotation-energy summary.
  final double? rotationEnergy;

  /// Whether calibrated orientation support was available.
  final bool compassAvailable;

  /// Sanitized GPS displacement classification, never coordinates.
  final String? gpsDisplacementEvidence;

  /// Native foreground/background state during the decision.
  final String? nativeForegroundState;

  /// Whether the screen was interactive, when the platform reports it.
  final bool? screenInteractive;

  /// Whether battery saver was active, when available.
  final bool? batterySaverActive;

  /// Decodes a native status or event-channel payload.
  factory MotionEvidenceSnapshot.fromMap(Map<Object?, Object?> map) {
    final rawTimestamp = map['observedAt'] ?? map['timestamp'];
    final timestamp = rawTimestamp is num
        ? DateTime.fromMillisecondsSinceEpoch(rawTimestamp.toInt(), isUtc: true)
        : DateTime.tryParse(rawTimestamp?.toString() ?? '')?.toUtc() ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    Set<MotionEvidenceSource> sources(Object? value) {
      final values = value is Iterable ? value : const <Object?>[];
      return <MotionEvidenceSource>{
        for (final item in values)
          for (final source in MotionEvidenceSource.values)
            if (source.name == item?.toString()) source,
      };
    }

    return MotionEvidenceSnapshot(
      state: FusedMotionState.values.firstWhere(
        (candidate) => candidate.name == map['state']?.toString(),
        orElse: () => FusedMotionState.unknown,
      ),
      confidence: (map['confidence'] as num?)?.round() ?? 0,
      observedAt: timestamp,
      supportingSources: sources(map['supportingSources']),
      conflictingSources: sources(map['conflictingSources']),
      stepDetected: map['stepDetected'] as bool? ?? false,
      significantMotionDetected:
          map['significantMotionDetected'] as bool? ?? false,
      sensorProbeUsed: map['sensorProbeUsed'] as bool? ?? false,
      policyVersion: (map['policyVersion'] as num?)?.toInt() ?? 1,
      reason: map['reason']?.toString() ?? 'insufficient_evidence',
      generation: (map['generation'] as num?)?.toInt(),
      probeDuration: map['probeDurationMs'] is num
          ? Duration(milliseconds: (map['probeDurationMs'] as num).toInt())
          : null,
      accelerometerSampleCount:
          (map['accelerometerSampleCount'] as num?)?.toInt() ?? 0,
      accelerationMotionEnergy:
          (map['accelerationMotionEnergy'] as num?)?.toDouble(),
      gyroscopeSampleCount: (map['gyroscopeSampleCount'] as num?)?.toInt() ?? 0,
      rotationEnergy: (map['rotationEnergy'] as num?)?.toDouble(),
      compassAvailable: map['compassAvailable'] as bool? ?? false,
      gpsDisplacementEvidence: map['gpsDisplacementEvidence']?.toString(),
      nativeForegroundState: map['nativeForegroundState']?.toString(),
      screenInteractive: map['screenInteractive'] as bool?,
      batterySaverActive: map['batterySaverActive'] as bool?,
    );
  }

  /// Coordinate-free transport representation.
  Map<String, Object?> toMap() => <String, Object?>{
        'state': state.name,
        'confidence': confidence,
        'observedAt': observedAt.millisecondsSinceEpoch,
        'supportingSources':
            supportingSources.map((source) => source.name).toList(),
        'conflictingSources':
            conflictingSources.map((source) => source.name).toList(),
        'stepDetected': stepDetected,
        'significantMotionDetected': significantMotionDetected,
        'sensorProbeUsed': sensorProbeUsed,
        'policyVersion': policyVersion,
        'reason': reason,
        'generation': generation,
        'probeDurationMs': probeDuration?.inMilliseconds,
        'accelerometerSampleCount': accelerometerSampleCount,
        'accelerationMotionEnergy': accelerationMotionEnergy,
        'gyroscopeSampleCount': gyroscopeSampleCount,
        'rotationEnergy': rotationEnergy,
        'compassAvailable': compassAvailable,
        'gpsDisplacementEvidence': gpsDisplacementEvidence,
        'nativeForegroundState': nativeForegroundState,
        'screenInteractive': screenInteractive,
        'batterySaverActive': batterySaverActive,
      };
}

/// Bounded feature window supplied to the pure motion reducer.
///
/// GPS contributes only a displacement classification. This object never
/// contains coordinates or raw sensor vectors.
final class MotionEvidenceObservation {
  const MotionEvidenceObservation({
    required this.observedAt,
    this.activity,
    this.stepDetected = false,
    this.significantMotionDetected = false,
    this.gpsDisplacementMeters,
    this.gpsUncertaintyMeters,
    this.accelerationMotionEnergy,
    this.rotationEnergy,
    this.compassAvailable = false,
    this.sensorProbeUsed = false,
    this.generation = 0,
  });

  final DateTime observedAt;
  final ActivitySnapshot? activity;
  final bool stepDetected;
  final bool significantMotionDetected;
  final double? gpsDisplacementMeters;
  final double? gpsUncertaintyMeters;
  final double? accelerationMotionEnergy;
  final double? rotationEnergy;
  final bool compassAvailable;
  final bool sensorProbeUsed;
  final int generation;
}
