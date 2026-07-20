import 'activity_snapshot.dart';
import 'tracker_status.dart';

/// What the operating system reported about mock/simulated location.
///
/// [notDetected] is not proof that a fix is genuine. Platform signals can be
/// unavailable or bypassed by rooted/jailbroken devices and RF/GNSS spoofing.
enum MockLocationAssessment { detected, notDetected, unavailable }

final class LocationSample {
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
  });

  final double latitude;
  final double longitude;
  final double? altitude;
  final double? horizontalAccuracy;
  final double? verticalAccuracy;
  final double? speed;
  final double? speedAccuracy;
  final double? heading;
  final double? headingAccuracy;
  final DateTime capturedAt;
  final bool isMocked;
  final bool mockDetectionAvailable;
  final bool? isProducedByAccessory;
  final String? mockEvidence;
  final String? provider;
  final String? eventId;

  /// The native session that produced this fix, when supplied by the adapter.
  ///
  /// Durable native queues use this value to prevent a delayed event from one
  /// session being attached to a different active track after process death.
  final String? trackId;
  final ActivitySnapshot? capturedActivity;
  final MotionState? capturedMotionState;

  MockLocationAssessment get mockAssessment {
    // A positive platform signal is authoritative even if an older adapter
    // omitted or incorrectly cleared its separate availability field.
    if (isMocked) return MockLocationAssessment.detected;
    if (!mockDetectionAvailable) return MockLocationAssessment.unavailable;
    return MockLocationAssessment.notDetected;
  }

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
