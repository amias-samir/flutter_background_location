/// Normalized motion activity reported for a location session.
enum TrackingActivityType {
  /// The platform supplied no reliable activity classification.
  unknown,

  /// The device is believed to be still.
  stationary,

  /// The user is believed to be walking.
  walking,

  /// The user is believed to be running.
  running,

  /// The platform reported cycling or bicycle movement.
  onBicycle,

  /// The device is believed to be travelling in a vehicle.
  inVehicle,
}

/// Serialization and movement helpers for [TrackingActivityType].
extension TrackingActivityTypeValue on TrackingActivityType {
  /// Stable snake-case value used by native payloads and stored records.
  String get value => switch (this) {
        TrackingActivityType.unknown => 'unknown',
        TrackingActivityType.stationary => 'stationary',
        TrackingActivityType.walking => 'walking',
        TrackingActivityType.running => 'running',
        TrackingActivityType.onBicycle => 'on_bicycle',
        TrackingActivityType.inVehicle => 'in_vehicle',
      };

  /// Whether this classification is positive evidence of movement.
  bool get indicatesMovement => switch (this) {
        TrackingActivityType.walking ||
        TrackingActivityType.running ||
        TrackingActivityType.onBicycle ||
        TrackingActivityType.inVehicle =>
          true,
        _ => false,
      };

  /// Cycling is the standard motion API's closest two-wheeler signal.
  /// Motorcycles may still be reported as [TrackingActivityType.inVehicle].
  bool get isTwoWheelerSignal => this == TrackingActivityType.onBicycle;
}

/// Parses platform activity names into the package's normalized enum.
TrackingActivityType trackingActivityTypeFromValue(Object? raw) {
  final value = raw?.toString().toLowerCase().replaceAll('-', '_') ?? '';
  return switch (value) {
    'still' || 'stationary' => TrackingActivityType.stationary,
    'walking' || 'on_foot' => TrackingActivityType.walking,
    'running' => TrackingActivityType.running,
    'cycling' || 'bicycle' || 'on_bicycle' => TrackingActivityType.onBicycle,
    'automotive' || 'vehicle' || 'in_vehicle' => TrackingActivityType.inVehicle,
    _ => TrackingActivityType.unknown,
  };
}

/// Activity classification captured at a particular instant.
final class ActivitySnapshot {
  /// Creates an activity reading with a confidence from 0 to 100.
  const ActivitySnapshot({
    required this.type,
    required this.confidence,
    required this.recordedAt,
  });

  /// Creates an unavailable activity reading.
  const ActivitySnapshot.unknown()
      : type = TrackingActivityType.unknown,
        confidence = 0,
        recordedAt = null;

  /// Normalized platform activity.
  final TrackingActivityType type;

  /// Platform confidence percentage, clamped to 0–100.
  final int confidence;

  /// UTC time associated with the activity reading, when available.
  final DateTime? recordedAt;

  /// Decodes a native activity-channel payload.
  factory ActivitySnapshot.fromMap(Map<Object?, Object?> map) {
    final timestamp = map['timestamp'];
    return ActivitySnapshot(
      type: trackingActivityTypeFromValue(map['type']),
      confidence: ((map['confidence'] as num?)?.round() ?? 0).clamp(0, 100),
      recordedAt: timestamp is num
          ? DateTime.fromMillisecondsSinceEpoch(
              timestamp.toInt(),
              isUtc: true,
            )
          : null,
    );
  }
}
