import 'activity_snapshot.dart';
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
    this.nativeReceivedAt,
    this.providerTimeDeltaMsAtReceipt,
    this.monotonicFixNanos,
    this.monotonicReceivedNanos,
    this.monotonicDomainId,
    this.captureGenerationId,
    this.nativeSessionStartedAt,
    this.nativeLifecycle,
    this.samplingProfile,
  });

  /// Latitude in decimal degrees.
  final double latitude;

  /// Longitude in decimal degrees.
  final double longitude;

  /// Altitude above the provider's reference ellipsoid, in metres.
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

  /// Wall-clock time at which the native callback received this fix.
  final DateTime? nativeReceivedAt;

  /// Signed native-receipt minus provider-time delta in milliseconds.
  final int? providerTimeDeltaMsAtReceipt;

  /// Provider monotonic fix marker, when the platform supplies one.
  final int? monotonicFixNanos;

  /// Native callback monotonic marker in [monotonicDomainId].
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
    final hasActivity = map.containsKey('activityType') ||
        map.containsKey('activityConfidence');
    final rawMotion =
        map['motionState'] ?? map['trackingProfile'] ?? map['samplingProfile'];
    final rawLifecycle = map['nativeLifecycle']?.toString().toLowerCase();
    final rawSampling = map['samplingProfile']?.toString().toLowerCase();

    return LocationSample(
      latitude: number('lat') ?? number('latitude') ?? double.nan,
      longitude:
          number('lon') ?? number('lng') ?? number('longitude') ?? double.nan,
      altitude: number('altitude'),
      horizontalAccuracy: number('accuracy') ?? number('horizontalAccuracy'),
      verticalAccuracy: number('verticalAccuracy'),
      speed: number('speed'),
      speedAccuracy: number('speedAccuracy'),
      heading: number('heading'),
      headingAccuracy: number('headingAccuracy'),
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
      capturedActivity: hasActivity
          ? ActivitySnapshot(
              type: trackingActivityTypeFromValue(map['activityType']),
              confidence: ((map['activityConfidence'] as num?)?.round() ?? 0)
                  .clamp(0, 100),
              recordedAt: timestamp(
                map['activityTimestamp'],
                fallback: capturedAt,
              ),
            )
          : null,
      capturedMotionState: switch (rawMotion?.toString().toLowerCase()) {
        'moving' => MotionState.moving,
        'stationary' => MotionState.stationary,
        _ => null,
      },
    );
  }
}
