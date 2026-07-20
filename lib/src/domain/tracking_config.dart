import 'dart:convert';

enum MockLocationPolicy { allow, flag, reject }

/// Sampling, validation, and battery policy for a tracking session.
final class TrackingConfig {
  const TrackingConfig({
    this.movingDistanceFilterMeters = 15,
    this.movingInterval = const Duration(seconds: 15),
    this.stationaryDistanceFilterMeters = 75,
    this.stationaryInterval = const Duration(minutes: 2),
    this.maximumAcceptedAccuracyMeters = 60,
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
  })  : assert(movingDistanceFilterMeters >= 0),
        assert(stationaryDistanceFilterMeters >= 0),
        assert(maximumAcceptedAccuracyMeters > 0),
        assert(maximumPlausibleSpeedMetersPerSecond > 0),
        assert(stationaryProbeDisplacementMeters >= 0),
        assert(stationaryConfidenceThreshold >= 0 &&
            stationaryConfidenceThreshold <= 100),
        assert(
            movingConfidenceThreshold >= 0 && movingConfidenceThreshold <= 100),
        assert(movingConfirmationCount > 0),
        assert(batchPointCount > 0);

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
    int integer(String key, int fallback) =>
        (map[key] as num?)?.toInt() ?? fallback;
    double decimal(String key, double fallback) =>
        (map[key] as num?)?.toDouble() ?? fallback;

    return TrackingConfig(
      movingDistanceFilterMeters: integer('movingDistanceFilterMeters', 15),
      movingInterval:
          Duration(milliseconds: integer('movingIntervalMs', 15000)),
      stationaryDistanceFilterMeters: integer(
        'stationaryDistanceFilterMeters',
        75,
      ),
      stationaryInterval: Duration(
        milliseconds: integer('stationaryIntervalMs', 120000),
      ),
      maximumAcceptedAccuracyMeters: decimal(
        'maximumAcceptedAccuracyMeters',
        60,
      ),
      maximumPlausibleSpeedMetersPerSecond: decimal(
        'maximumPlausibleSpeedMetersPerSecond',
        70,
      ),
      stationaryConfirmationDuration: Duration(
        milliseconds: integer('stationaryConfirmationMs', 90000),
      ),
      stationaryProbeDisplacementMeters: decimal(
        'stationaryProbeDisplacementMeters',
        30,
      ),
      stationaryConfidenceThreshold: integer(
        'stationaryConfidenceThreshold',
        75,
      ),
      movingConfidenceThreshold: integer('movingConfidenceThreshold', 60),
      movingConfirmationCount: integer('movingConfirmationCount', 2),
      activityRecognitionInterval: Duration(
        milliseconds: integer('activityRecognitionIntervalMs', 10000),
      ),
      mockLocationPolicy: MockLocationPolicy.values.firstWhere(
        (value) => value.name == map['mockLocationPolicy'],
        orElse: () => map['rejectMockLocations'] == true
            ? MockLocationPolicy.reject
            : MockLocationPolicy.flag,
      ),
      batchPointCount: integer('batchPointCount', 25),
      batchMaxAge: Duration(milliseconds: integer('batchMaxAgeMs', 120000)),
      largeGapThreshold: Duration(
        milliseconds: integer('largeGapThresholdMs', 300000),
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
final class FieldTrackingConfiguration {
  const FieldTrackingConfiguration({
    this.databaseName = 'flutter_background_location.sqlite',
    this.exportDirectoryName = 'flutter_background_location',
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
  final TrackingConfig defaultTrackingConfig;
  final int maximumUploadBatchPointCount;
  final int maximumUploadBatchBytes;
  final Duration uploadLeaseDuration;
  final Duration uploadInitialBackoff;
  final Duration uploadMaximumBackoff;
  final Duration uploadRecoveryInterval;
}
