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

/// Freshness of activity evidence relative to the consuming decision.
enum ActivityEvidenceState { fresh, stale, unavailable }

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
    this.evidenceState = ActivityEvidenceState.fresh,
    this.source = 'platform_activity',
    this.rawType,
    this.age,
    this.probabilities = const <TrackingActivityType, int>{},
  });

  /// Creates an unavailable activity reading.
  const ActivitySnapshot.unknown()
      : type = TrackingActivityType.unknown,
        confidence = 0,
        recordedAt = null,
        evidenceState = ActivityEvidenceState.unavailable,
        source = 'unavailable',
        rawType = null,
        age = null,
        probabilities = const <TrackingActivityType, int>{};

  /// Normalized platform activity.
  final TrackingActivityType type;

  /// Platform confidence percentage, clamped to 0–100.
  final int confidence;

  /// UTC time associated with the activity reading, when available.
  final DateTime? recordedAt;

  /// Whether this reading is fresh enough for a motion decision.
  final ActivityEvidenceState evidenceState;

  /// Native evidence source, such as `android_activity_recognition`.
  final String source;

  /// Platform-native activity value retained for diagnostics.
  final String? rawType;

  /// Age reported by native code when the snapshot was emitted.
  final Duration? age;

  /// Bounded probable-activity distribution when supplied by the platform.
  final Map<TrackingActivityType, int> probabilities;

  /// Returns this reading with freshness evaluated at [now].
  ActivitySnapshot evaluatedAt(DateTime now, Duration freshnessThreshold) {
    final timestamp = recordedAt;
    if (timestamp == null) return const ActivitySnapshot.unknown();
    final calculatedAge = now.toUtc().difference(timestamp.toUtc()).abs();
    return ActivitySnapshot(
      type: type,
      confidence: confidence,
      recordedAt: timestamp,
      evidenceState: calculatedAge <= freshnessThreshold
          ? ActivityEvidenceState.fresh
          : ActivityEvidenceState.stale,
      source: source,
      rawType: rawType,
      age: calculatedAge,
      probabilities: probabilities,
    );
  }

  /// Decodes a native activity-channel payload.
  factory ActivitySnapshot.fromMap(Map<Object?, Object?> map) {
    final timestamp = map['timestamp'] ?? map['activityTimestamp'];
    final probabilities = <TrackingActivityType, int>{};
    final rawProbabilities =
        map['probabilities'] ?? map['activityProbabilities'];
    if (rawProbabilities is Map) {
      for (final entry in rawProbabilities.entries) {
        final type = trackingActivityTypeFromValue(entry.key);
        final confidence = (entry.value as num?)?.round();
        if (confidence != null) probabilities[type] = confidence.clamp(0, 100);
      }
    }
    return ActivitySnapshot(
      type: trackingActivityTypeFromValue(map['type'] ?? map['activityType']),
      confidence: ((map['confidence'] as num?)?.round() ??
              (map['activityConfidence'] as num?)?.round() ??
              0)
          .clamp(0, 100),
      recordedAt: timestamp is num
          ? DateTime.fromMillisecondsSinceEpoch(
              timestamp.toInt(),
              isUtc: true,
            )
          : null,
      evidenceState: ActivityEvidenceState.values.firstWhere(
        (candidate) =>
            candidate.name ==
            (map['evidenceState'] ?? map['activityEvidenceState'])?.toString(),
        orElse: () => timestamp == null
            ? ActivityEvidenceState.unavailable
            : ActivityEvidenceState.fresh,
      ),
      source: (map['source'] ?? map['activitySource'])?.toString() ??
          'platform_activity',
      rawType: (map['rawType'] ?? map['activityRawType'])?.toString(),
      age: (map['ageMs'] ?? map['activityAgeMs']) is num
          ? Duration(
              milliseconds:
                  ((map['ageMs'] ?? map['activityAgeMs']) as num).toInt(),
            )
          : null,
      probabilities: probabilities,
    );
  }
}
