import 'dart:convert';

enum MockLocationPolicy { allow, flag, reject }

enum TrackRecordRetentionPolicy { keepLatestOnly, keepAll }

/// A predefined sampling and native location-accuracy profile.
///
/// Select a profile with [TrackingConfig.accuracy]. Any individual sampling
/// value supplied to [TrackingConfig] overrides only that value from the
/// selected profile. [TrackingConfig.locationAccuracy] can independently
/// override the native provider accuracy without changing the intervals or
/// distance filters.
enum TrackingAccuracy {
  /// Prioritizes battery life and accepts fixes accurate to 200 metres.
  low,

  /// Balances route fidelity and battery use, accepting up to 100 metres.
  medium,

  /// Uses the original high-fidelity defaults and accepts up to 60 metres.
  high,

  /// Requests dense navigation updates and accepts up to 20 metres.
  precised;

  /// Maximum horizontal accuracy accepted by this predefined profile.
  ///
  /// A fix reporting a larger uncertainty is rejected by validation. An
  /// explicit `TrackingConfig(maximumAcceptedAccuracyMeters: ...)` value
  /// overrides this preset value.
  double get maximumAcceptedAccuracyMeters => switch (this) {
        TrackingAccuracy.low => 200,
        TrackingAccuracy.medium => 100,
        TrackingAccuracy.high => 60,
        TrackingAccuracy.precised => 20,
      };

  /// Parses persisted/native values while accepting the grammatically common
  /// `precise` spelling as an alias for [precised].
  static TrackingAccuracy parse(
    Object? value, {
    TrackingAccuracy fallback = TrackingAccuracy.high,
  }) {
    if (value is TrackingAccuracy) return value;
    final normalized = value?.toString().trim().toLowerCase();
    if (normalized == 'precise' ||
        normalized == 'navigation' ||
        normalized == 'bestfornavigation') {
      return TrackingAccuracy.precised;
    }
    if (normalized == 'balanced' || normalized == 'nearesttenmeters') {
      return TrackingAccuracy.medium;
    }
    if (normalized == 'lowpower' || normalized == 'hundredmeters') {
      return TrackingAccuracy.low;
    }
    if (normalized == 'best') return TrackingAccuracy.high;
    return TrackingAccuracy.values.firstWhere(
      (candidate) => candidate.name == normalized,
      orElse: () => fallback,
    );
  }
}

/// Sampling, validation, and battery policy for a tracking session.
final class TrackingConfig {
  const TrackingConfig({
    this.accuracy = TrackingAccuracy.high,
    TrackingAccuracy? locationAccuracy,
    int? movingDistanceFilterMeters,
    Duration? movingInterval,
    int? stationaryDistanceFilterMeters,
    Duration? stationaryInterval,
    double? maximumAcceptedAccuracyMeters,
    this.maximumPlausibleSpeedMetersPerSecond = 70,
    this.stationaryConfirmationDuration = const Duration(seconds: 90),
    this.stationaryProbeDisplacementMeters = 30,
    this.stationaryConfidenceThreshold = 75,
    this.movingConfidenceThreshold = 60,
    this.movingConfirmationCount = 2,
    this.activityRecognitionInterval = const Duration(seconds: 10),
    this.mockLocationPolicy = MockLocationPolicy.flag,
    this.batchPointCount = 25,
    this.batchMaxAge = const Duration(minutes: 2),
    this.largeGapThreshold = const Duration(minutes: 5),
    this.androidNotificationTitle = 'Location tracking active',
    this.androidNotificationText = 'Recording your route',
  })  : locationAccuracy = locationAccuracy ?? accuracy,
        movingDistanceFilterMeters = movingDistanceFilterMeters ??
            (accuracy == TrackingAccuracy.low
                ? 50
                : accuracy == TrackingAccuracy.medium
                    ? 25
                    : accuracy == TrackingAccuracy.precised
                        ? 5
                        : 15),
        movingInterval = movingInterval ??
            (accuracy == TrackingAccuracy.low
                ? const Duration(minutes: 1)
                : accuracy == TrackingAccuracy.medium
                    ? const Duration(seconds: 30)
                    : accuracy == TrackingAccuracy.precised
                        ? const Duration(seconds: 5)
                        : const Duration(seconds: 15)),
        stationaryDistanceFilterMeters = stationaryDistanceFilterMeters ??
            (accuracy == TrackingAccuracy.low
                ? 200
                : accuracy == TrackingAccuracy.medium
                    ? 100
                    : accuracy == TrackingAccuracy.precised
                        ? 25
                        : 75),
        stationaryInterval = stationaryInterval ??
            (accuracy == TrackingAccuracy.low
                ? const Duration(minutes: 5)
                : accuracy == TrackingAccuracy.medium
                    ? const Duration(minutes: 3)
                    : accuracy == TrackingAccuracy.precised
                        ? const Duration(seconds: 30)
                        : const Duration(minutes: 2)),
        maximumAcceptedAccuracyMeters = maximumAcceptedAccuracyMeters ??
            (accuracy == TrackingAccuracy.low
                ? 200
                : accuracy == TrackingAccuracy.medium
                    ? 100
                    : accuracy == TrackingAccuracy.precised
                        ? 20
                        : 60),
        assert(movingDistanceFilterMeters == null ||
            movingDistanceFilterMeters >= 0),
        assert(stationaryDistanceFilterMeters == null ||
            stationaryDistanceFilterMeters >= 0),
        assert(maximumAcceptedAccuracyMeters == null ||
            maximumAcceptedAccuracyMeters > 0),
        assert(maximumPlausibleSpeedMetersPerSecond > 0),
        assert(stationaryProbeDisplacementMeters >= 0),
        assert(stationaryConfidenceThreshold >= 0 &&
            stationaryConfidenceThreshold <= 100),
        assert(
            movingConfidenceThreshold >= 0 && movingConfidenceThreshold <= 100),
        assert(movingConfirmationCount > 0),
        assert(batchPointCount > 0);

  /// The profile from which unset sampling values are resolved.
  final TrackingAccuracy accuracy;

  /// The native provider accuracy, independently overridable from [accuracy].
  final TrackingAccuracy locationAccuracy;

  final int movingDistanceFilterMeters;
  final Duration movingInterval;
  final int stationaryDistanceFilterMeters;
  final Duration stationaryInterval;
  final double maximumAcceptedAccuracyMeters;
  final double maximumPlausibleSpeedMetersPerSecond;
  final Duration stationaryConfirmationDuration;
  final double stationaryProbeDisplacementMeters;
  final int stationaryConfidenceThreshold;
  final int movingConfidenceThreshold;
  final int movingConfirmationCount;
  final Duration activityRecognitionInterval;
  final MockLocationPolicy mockLocationPolicy;
  final int batchPointCount;
  final Duration batchMaxAge;
  final Duration largeGapThreshold;
  final String androidNotificationTitle;
  final String androidNotificationText;

  Map<String, Object?> toMap() => <String, Object?>{
        'accuracy': accuracy.name,
        'desiredAccuracy': locationAccuracy.name,
        'movingDistanceFilterMeters': movingDistanceFilterMeters,
        'movingIntervalMs': movingInterval.inMilliseconds,
        'stationaryDistanceFilterMeters': stationaryDistanceFilterMeters,
        'stationaryIntervalMs': stationaryInterval.inMilliseconds,
        'maximumAcceptedAccuracyMeters': maximumAcceptedAccuracyMeters,
        'maximumPlausibleSpeedMetersPerSecond':
            maximumPlausibleSpeedMetersPerSecond,
        'stationaryConfirmationMs':
            stationaryConfirmationDuration.inMilliseconds,
        'stationaryProbeDisplacementMeters': stationaryProbeDisplacementMeters,
        'stationaryConfidenceThreshold': stationaryConfidenceThreshold,
        'movingConfidenceThreshold': movingConfidenceThreshold,
        'movingConfirmationCount': movingConfirmationCount,
        'activityRecognitionIntervalMs':
            activityRecognitionInterval.inMilliseconds,
        'mockLocationPolicy': mockLocationPolicy.name,
        'batchPointCount': batchPointCount,
        'batchMaxAgeMs': batchMaxAge.inMilliseconds,
        'largeGapThresholdMs': largeGapThreshold.inMilliseconds,
        'notificationTitle': androidNotificationTitle,
        'notificationText': androidNotificationText,
      };

  String toJson() => jsonEncode(toMap());

  factory TrackingConfig.fromMap(Map<String, Object?> map) {
    int? integer(String key) => (map[key] as num?)?.toInt();
    double? decimal(String key) => (map[key] as num?)?.toDouble();
    Duration? duration(String key) {
      final milliseconds = integer(key);
      return milliseconds == null ? null : Duration(milliseconds: milliseconds);
    }

    final accuracy = TrackingAccuracy.parse(
      map['accuracy'] ?? map['trackingAccuracy'],
    );

    return TrackingConfig(
      accuracy: accuracy,
      locationAccuracy: map.containsKey('desiredAccuracy')
          ? TrackingAccuracy.parse(
              map['desiredAccuracy'],
              fallback: accuracy,
            )
          : null,
      movingDistanceFilterMeters: integer('movingDistanceFilterMeters'),
      movingInterval: duration('movingIntervalMs'),
      stationaryDistanceFilterMeters: integer('stationaryDistanceFilterMeters'),
      stationaryInterval: duration('stationaryIntervalMs'),
      maximumAcceptedAccuracyMeters: decimal('maximumAcceptedAccuracyMeters'),
      maximumPlausibleSpeedMetersPerSecond:
          decimal('maximumPlausibleSpeedMetersPerSecond') ?? 70,
      stationaryConfirmationDuration: Duration(
        milliseconds: integer('stationaryConfirmationMs') ?? 90000,
      ),
      stationaryProbeDisplacementMeters:
          decimal('stationaryProbeDisplacementMeters') ?? 30,
      stationaryConfidenceThreshold:
          integer('stationaryConfidenceThreshold') ?? 75,
      movingConfidenceThreshold: integer('movingConfidenceThreshold') ?? 60,
      movingConfirmationCount: integer('movingConfirmationCount') ?? 2,
      activityRecognitionInterval: Duration(
        milliseconds: integer('activityRecognitionIntervalMs') ?? 10000,
      ),
      mockLocationPolicy: MockLocationPolicy.values.firstWhere(
        (value) => value.name == map['mockLocationPolicy'],
        orElse: () => map['rejectMockLocations'] == true
            ? MockLocationPolicy.reject
            : MockLocationPolicy.flag,
      ),
      batchPointCount: integer('batchPointCount') ?? 25,
      batchMaxAge: Duration(milliseconds: integer('batchMaxAgeMs') ?? 120000),
      largeGapThreshold: Duration(
        milliseconds: integer('largeGapThresholdMs') ?? 300000,
      ),
      androidNotificationTitle:
          map['notificationTitle'] as String? ?? 'Location tracking active',
      androidNotificationText:
          map['notificationText'] as String? ?? 'Recording your route',
    );
  }

  factory TrackingConfig.fromJson(String source) => TrackingConfig.fromMap(
        (jsonDecode(source) as Map).cast<String, Object?>(),
      );
}

/// Package-level storage and export configuration.
final class TrackingConfiguration {
  const TrackingConfiguration({
    this.databaseName = 'flutter_background_location.sqlite',
    this.exportDirectoryName = 'flutter_background_location',
    this.recordRetentionPolicy = TrackRecordRetentionPolicy.keepAll,
    this.defaultTrackingConfig = const TrackingConfig(),
    this.maximumUploadBatchPointCount = 100,
    this.maximumUploadBatchBytes = 256 * 1024,
    this.uploadLeaseDuration = const Duration(minutes: 2),
    this.uploadInitialBackoff = const Duration(seconds: 5),
    this.uploadMaximumBackoff = const Duration(minutes: 15),
    this.uploadRecoveryInterval = const Duration(seconds: 30),
  })  : assert(maximumUploadBatchPointCount > 0),
        assert(maximumUploadBatchBytes > 0);

  final String databaseName;
  final String exportDirectoryName;
  final TrackRecordRetentionPolicy recordRetentionPolicy;
  final TrackingConfig defaultTrackingConfig;
  final int maximumUploadBatchPointCount;
  final int maximumUploadBatchBytes;
  final Duration uploadLeaseDuration;
  final Duration uploadInitialBackoff;
  final Duration uploadMaximumBackoff;
  final Duration uploadRecoveryInterval;
}
