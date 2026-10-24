import 'dart:convert';

import 'activity_snapshot.dart';
import 'motion_evidence.dart';
import 'step_coverage.dart';
import 'tracker_status.dart';

/// What the operating system reported about mock/simulated location.
///
/// [notDetected] is not proof that a fix is genuine. Platform signals can be
/// unavailable or bypassed by rooted/jailbroken devices and RF/GNSS spoofing.
enum MockLocationAssessment {
  /// The platform positively marked the fix as simulated or mocked.
  detected,

  /// Mock detection was available and did not flag the fix.
  notDetected,

  /// The platform could not provide mock-location evidence.
  unavailable,
}

/// Raw location and capture evidence received from the native provider.
final class LocationSample {
  /// Creates one provider sample before package quality validation.
  const LocationSample({
    required this.latitude,
    required this.longitude,
    required this.capturedAt,
    this.altitude,
    this.horizontalAccuracy,
    this.verticalAccuracy,
    this.speed,
    this.speedAccuracy,
    this.heading,
    this.headingAccuracy,
    this.isMocked = false,
    this.mockDetectionAvailable = false,
    this.isProducedByAccessory,
    this.mockEvidence,
    this.provider,
    this.eventId,
    this.trackId,
    this.capturedActivity,
    this.capturedMotionState,
    this.capturedMotionEvidence,
    this.nativeReceivedAt,
    this.providerTimeDeltaMsAtReceipt,
    this.monotonicFixNanos,
    this.monotonicReceivedNanos,
    this.monotonicDomainId,
    this.captureGenerationId,
    this.nativeSessionStartedAt,
    this.nativeLifecycle,
    this.samplingProfile,
    this.stepCount,
    this.activityReadings = const <ActivitySnapshot>[],
    this.activityReadingsDropped,
    this.stepCoverage,
    this.profileTransitions = const <SamplingProfileTransition>[],
  });

  /// Latitude in decimal degrees.
  final double latitude;

  /// Longitude in decimal degrees.
  final double longitude;

  /// Altitude in metres as the platform reports it: above the WGS 84
  /// ellipsoid on Android and above mean sea level on iOS. Null when unknown
  /// or when the vertical accuracy marks it invalid.
  final double? altitude;

  /// Reported horizontal uncertainty radius, in metres.
  final double? horizontalAccuracy;

  /// Reported vertical uncertainty, in metres.
  final double? verticalAccuracy;

  /// Reported ground speed in metres per second.
  final double? speed;

  /// Reported speed uncertainty in metres per second.
  final double? speedAccuracy;

  /// Reported direction of travel in degrees.
  final double? heading;

  /// Reported heading uncertainty in degrees.
  final double? headingAccuracy;

  /// UTC provider timestamp for the fix.
  final DateTime capturedAt;

  /// Whether the platform positively marked this fix as mocked.
  final bool isMocked;

  /// Whether the platform exposed a mock-detection signal.
  final bool mockDetectionAvailable;

  /// Whether an external accessory produced the location, when known.
  final bool? isProducedByAccessory;

  /// Sanitized platform reason associated with mock detection.
  final String? mockEvidence;

  /// Native provider name, such as `fused` or `gps`.
  final String? provider;

  /// Durable native-journal event identifier, when provided.
  final String? eventId;

  /// The native session that produced this fix, when supplied by the adapter.
  ///
  /// Durable native queues use this value to prevent a delayed event from one
  /// session being attached to a different active track after process death.
  final String? trackId;

  /// Activity evidence captured with this fix.
  final ActivitySnapshot? capturedActivity;

  /// Native moving/stationary state captured with this fix.
  final MotionState? capturedMotionState;

  /// Bounded sensor-fusion decision captured with this fix, when available.
  final MotionEvidenceSnapshot? capturedMotionEvidence;

  /// Wall-clock time at which the native callback received this fix.
  final DateTime? nativeReceivedAt;

  /// Signed native-receipt minus provider-time delta in milliseconds.
  final int? providerTimeDeltaMsAtReceipt;

  /// Provider monotonic fix marker, when the platform supplies one.
  final int? monotonicFixNanos;

  /// Native callback monotonic marker in [monotonicDomainId].
  ///
  /// On iOS this is derived from system uptime, which Apple's privacy rules
  /// allow only for measuring elapsed time on the device. The package never
  /// exports or uploads it; host uploaders should not send it off-device.
  final int? monotonicReceivedNanos;

  /// Opaque boot/process clock domain for safe monotonic comparisons.
  final String? monotonicDomainId;

  /// Opaque identity of one uninterrupted native provider session.
  final String? captureGenerationId;

  /// UTC time at which that native capture generation began.
  final DateTime? nativeSessionStartedAt;

  /// Native lifecycle attached to this journaled callback.
  final TrackerLifecycle? nativeLifecycle;

  /// Native sampling profile attached to this journaled callback.
  final SamplingProfile? samplingProfile;

  /// Steps the native step counter counted since this capture generation
  /// began (`stepCount`); null when the device has no step counter, the
  /// activity permission is missing, or the native build predates it.
  final int? stepCount;

  /// Activity readings native code received since the previous journaled fix
  /// and journaled with this one (capability `journaled_decision_inputs`),
  /// oldest first. Quality policy 5 decides from these and the attached
  /// [capturedActivity] only, so a route drained from the journal later is
  /// decided like one received live.
  final List<ActivitySnapshot> activityReadings;

  /// Readings native code dropped from [activityReadings] to keep the
  /// journaled payload bounded; null when none were dropped.
  final int? activityReadingsDropped;

  /// How completely the step counter counted this capture generation when
  /// the fix was captured (capability `step_count_coverage`); null without a
  /// step counter or a native build that reports it.
  final StepCoverage? stepCoverage;

  /// Native sampling-profile switches since the previous journaled fix
  /// (capability `journaled_decision_inputs`), oldest first.
  final List<SamplingProfileTransition> profileTransitions;

  /// Three-state interpretation of the available mock-location evidence.
  MockLocationAssessment get mockAssessment {
    // A positive platform signal is authoritative even if an older adapter
    // omitted or incorrectly cleared its separate availability field.
    if (isMocked) return MockLocationAssessment.detected;
    if (!mockDetectionAvailable) return MockLocationAssessment.unavailable;
    return MockLocationAssessment.notDetected;
  }

  /// Decodes a native location-channel payload.
  factory LocationSample.fromMap(Map<Object?, Object?> map) {
    double? number(String key) => (map[key] as num?)?.toDouble();
    DateTime timestamp(Object? value, {DateTime? fallback}) {
      if (value is num) {
        return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
      }
      if (value is String) {
        return DateTime.tryParse(value)?.toUtc() ??
            fallback ??
            DateTime.now().toUtc();
      }
      return fallback ?? DateTime.now().toUtc();
    }

    final capturedAt = timestamp(map['timestamp']);
    final isMocked = map['isMocked'] as bool? ?? false;
    final rawMotion =
        map['motionState'] ?? map['trackingProfile'] ?? map['samplingProfile'];
    final rawLifecycle = map['nativeLifecycle']?.toString().toLowerCase();
    final rawSampling = map['samplingProfile']?.toString().toLowerCase();
    final rawMotionEvidence = _nestedMap(map['motionEvidence']);
    // Platforms mark unknown kinematics with negative sentinels (iOS reports
    // -1 speed and course), and a negative vertical accuracy marks the
    // altitude invalid. Keep only physically meaningful values.
    double? nonNegative(String key) {
      final value = number(key);
      return value == null || !value.isFinite || value < 0 ? null : value;
    }

    final rawVerticalAccuracy = number('verticalAccuracy');
    final altitudeInvalid =
        rawVerticalAccuracy != null && rawVerticalAccuracy < 0;
    final heading = nonNegative('heading');

    return LocationSample(
      latitude: number('lat') ?? number('latitude') ?? double.nan,
      longitude:
          number('lon') ?? number('lng') ?? number('longitude') ?? double.nan,
      altitude: altitudeInvalid ? null : number('altitude'),
      horizontalAccuracy: number('accuracy') ?? number('horizontalAccuracy'),
      verticalAccuracy: altitudeInvalid ? null : rawVerticalAccuracy,
      speed: nonNegative('speed'),
      speedAccuracy: nonNegative('speedAccuracy'),
      heading: heading == null ? null : heading % 360,
      headingAccuracy: nonNegative('headingAccuracy'),
      capturedAt: capturedAt,
      isMocked: isMocked,
      mockDetectionAvailable:
          isMocked || (map['mockDetectionAvailable'] as bool? ?? false),
      isProducedByAccessory: map['isProducedByAccessory'] as bool?,
      mockEvidence: map['mockEvidence'] as String?,
      provider: map['provider'] as String?,
      eventId: map['eventId'] as String?,
      trackId: map['trackId'] as String?,
      nativeReceivedAt: map['nativeReceivedAt'] == null
          ? null
          : timestamp(map['nativeReceivedAt']),
      providerTimeDeltaMsAtReceipt:
          (map['providerTimeDeltaMsAtReceipt'] as num?)?.toInt(),
      monotonicFixNanos: (map['monotonicFixNanos'] as num?)?.toInt(),
      monotonicReceivedNanos: (map['monotonicReceivedNanos'] as num?)?.toInt(),
      monotonicDomainId: map['monotonicDomainId'] as String?,
      captureGenerationId: map['captureGenerationId'] as String?,
      nativeSessionStartedAt: map['nativeSessionStartedAt'] == null
          ? null
          : timestamp(map['nativeSessionStartedAt']),
      nativeLifecycle:
          TrackerLifecycle.values.cast<TrackerLifecycle?>().firstWhere(
                (candidate) => candidate?.name == rawLifecycle,
                orElse: () => null,
              ),
      samplingProfile: switch (rawSampling) {
        'stationary' => SamplingProfile.stationary,
        'moving' => SamplingProfile.moving,
        _ => null,
      },
      stepCount: stepCountFromPayload(map['stepCount']),
      activityReadings: _activityReadingsFromPayload(map['activityReadings']),
      activityReadingsDropped: switch (map['activityReadingsDropped']) {
        final num dropped when dropped.isFinite && dropped > 0 =>
          dropped.toInt(),
        _ => null,
      },
      stepCoverage: StepCoverage.fromPayload(map['stepCoverage']),
      profileTransitions:
          SamplingProfileTransition.listFromPayload(map['profileTransitions']),
      capturedActivity: _activityFromLocationPayload(map),
      capturedMotionState: switch (rawMotion?.toString().toLowerCase()) {
        'moving' => MotionState.moving,
        'stationary' => MotionState.stationary,
        _ => null,
      },
      capturedMotionEvidence: rawMotionEvidence == null
          ? null
          : MotionEvidenceSnapshot.fromMap(rawMotionEvidence),
    );
  }
}

/// A native `stepCount`: a whole, non-negative number of steps, or null for an
/// absent or malformed value.
int? stepCountFromPayload(Object? value) {
  if (value is! num || !value.isFinite || value < 0) return null;
  if (value is double && value != value.roundToDouble()) return null;
  return value.toInt();
}

/// Decodes the `activity*` keys of a native location payload.
///
/// The payload's own `timestamp` is the fix time, so only the prefixed keys
/// describe the activity reading. A payload without activity evidence yields
/// null, so consumers fall back to the activity stream instead of treating an
/// unknown reading as fresh.
ActivitySnapshot? _activityFromLocationPayload(Map<Object?, Object?> map) {
  final timestamp = map['activityTimestamp'];
  final evidenceState = map['activityEvidenceState'];
  if (timestamp == null &&
      evidenceState == null &&
      trackingActivityTypeFromValue(map['activityType']) ==
          TrackingActivityType.unknown &&
      ((map['activityConfidence'] as num?) ?? 0) == 0) {
    return null;
  }
  return ActivitySnapshot.fromMap(<Object?, Object?>{
    'type': map['activityType'],
    'confidence': map['activityConfidence'],
    'timestamp': timestamp,
    'evidenceState': evidenceState,
    'source': map['activitySource'],
    'rawType': map['activityRawType'],
    'ageMs': map['activityAgeMs'],
    'probabilities': _nestedMap(map['activityProbabilities']),
  });
}

/// Decodes journaled `activityReadings`: a list of activity-channel maps,
/// also accepted as JSON text. Malformed entries are skipped.
List<ActivitySnapshot> _activityReadingsFromPayload(Object? value) {
  Object? list = value;
  if (list is String) {
    try {
      list = jsonDecode(list);
    } on FormatException {
      return const <ActivitySnapshot>[];
    }
  }
  if (list is! List) return const <ActivitySnapshot>[];
  final readings = <ActivitySnapshot>[];
  for (final entry in list) {
    final map = _nestedMap(entry);
    if (map == null || map['timestamp'] is! num) continue;
    readings.add(ActivitySnapshot.fromMap(map));
  }
  readings.sort((a, b) => a.recordedAt!.compareTo(b.recordedAt!));
  return List<ActivitySnapshot>.unmodifiable(readings);
}

/// A nested payload map, also accepted as JSON text.
///
/// Android journal rows store nested values as JSON strings and inflate them
/// before replay; accepting the string form keeps a row readable if it ever
/// arrives uninflated. Older rows hold `toString()` text such as `{a=1}`,
/// which is not JSON and reads as absent evidence.
Map<Object?, Object?>? _nestedMap(Object? value) {
  if (value is Map) return value.cast<Object?, Object?>();
  if (value is! String) return null;
  try {
    final decoded = jsonDecode(value);
    return decoded is Map ? decoded.cast<Object?, Object?>() : null;
  } on FormatException {
    return null;
  }
}
