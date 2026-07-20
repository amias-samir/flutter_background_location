enum TrackingActivityType {
  unknown,
  stationary,
  walking,
  running,
  onBicycle,
  inVehicle,
}

extension TrackingActivityTypeValue on TrackingActivityType {
  String get value => switch (this) {
        TrackingActivityType.unknown => 'unknown',
        TrackingActivityType.stationary => 'stationary',
        TrackingActivityType.walking => 'walking',
        TrackingActivityType.running => 'running',
        TrackingActivityType.onBicycle => 'on_bicycle',
        TrackingActivityType.inVehicle => 'in_vehicle',
      };

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

final class ActivitySnapshot {
  const ActivitySnapshot({
    required this.type,
    required this.confidence,
    required this.recordedAt,
  });

  const ActivitySnapshot.unknown()
      : type = TrackingActivityType.unknown,
        confidence = 0,
        recordedAt = null;

  final TrackingActivityType type;
  final int confidence;
  final DateTime? recordedAt;

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
