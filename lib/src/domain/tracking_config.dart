import 'dart:convert';

import 'tracking_continuity.dart';
import 'tracking_error.dart';

enum MockLocationPolicy { allow, flag, reject }

enum TrackRecordRetentionPolicy { keepLatestOnly, keepAll }

/// iOS behavior after operating-system process termination.
///
/// [interrupted] keeps normal continuous tracking and requires an explicit
/// Resume after a terminated process is relaunched. [significantChange] opts
/// into Core Location significant-change monitoring, which has reduced and
/// OS-controlled sampling but can request relaunch. User force-quit remains a
/// non-recoverable boundary until the app is opened again.
enum IosTerminationRecoveryMode { interrupted, significantChange }

/// A predefined sampling and native location-accuracy profile.
///
/// Select a profile with [TrackingConfig.accuracy]. Any individual sampling
/// value supplied to [TrackingConfig] overrides only that value from the
/// selected profile. [TrackingConfig.locationAccuracy] can independently
/// override the native provider accuracy without changing the intervals or
/// distance filters.
enum TrackingAccuracy {
  /// Uses balanced native accuracy and accepts fixes accurate to 100 metres.
  low,

  /// Uses high native accuracy and accepts fixes accurate to 60 metres.
  medium,

  /// Uses navigation-grade native accuracy and accepts up to 20 metres.
  high,

  /// Requests the densest navigation updates and accepts up to 15 metres.
  precised;

  /// Maximum horizontal accuracy accepted by this predefined profile.
  ///
  /// A fix reporting a larger uncertainty is rejected by validation. An
  /// explicit `TrackingConfig(maximumAcceptedAccuracyMeters: ...)` value
  /// overrides this preset value.
  double get maximumAcceptedAccuracyMeters => switch (this) {
        TrackingAccuracy.low => 100,
        TrackingAccuracy.medium => 60,
        TrackingAccuracy.high => 20,
        TrackingAccuracy.precised => 15,
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

/// Fully resolved sampling and validation values for an accuracy profile.
final class ResolvedTrackingAccuracy {
  const ResolvedTrackingAccuracy({
    required this.movingInterval,
    required this.distanceFilterMeters,
    required this.locationAccuracy,
    required this.stationaryInterval,
    required this.stationaryDistanceFilterMeters,
    required this.maximumAcceptedAccuracyMeters,
  });

  final Duration movingInterval;
  final int distanceFilterMeters;
  final TrackingAccuracy locationAccuracy;
  final Duration stationaryInterval;
  final int stationaryDistanceFilterMeters;
  final double maximumAcceptedAccuracyMeters;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ResolvedTrackingAccuracy &&
          movingInterval == other.movingInterval &&
          distanceFilterMeters == other.distanceFilterMeters &&
          locationAccuracy == other.locationAccuracy &&
          stationaryInterval == other.stationaryInterval &&
          stationaryDistanceFilterMeters ==
              other.stationaryDistanceFilterMeters &&
          maximumAcceptedAccuracyMeters == other.maximumAcceptedAccuracyMeters;

  @override
  int get hashCode => Object.hash(
        movingInterval,
        distanceFilterMeters,
        locationAccuracy,
        stationaryInterval,
        stationaryDistanceFilterMeters,
        maximumAcceptedAccuracyMeters,
      );
}

/// Sampling, validation, and battery policy for a tracking session.
final class TrackingConfig {
  const TrackingConfig({
    this.accuracy = TrackingAccuracy.high,
    TrackingAccuracy? locationAccuracy,
    TrackingAccuracy? stationaryLocationAccuracy,
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
    Duration? largeGapThreshold,
    Duration? maximumProviderFixAge,
    this.callbackHealthWarningThreshold = const Duration(minutes: 2),
    Duration? acceptedGeometryGapThreshold,
    this.continuityPolicy = TrackingContinuityPolicy.conservative,
    Duration? firstFixTimeout,
    this.androidNotificationTitle = 'Location tracking active',
    this.androidNotificationText = 'Recording your route',
    this.iosTerminationRecoveryMode = IosTerminationRecoveryMode.interrupted,
  })  : firstFixTimeout = firstFixTimeout ??
            (accuracy == TrackingAccuracy.low
                ? const Duration(minutes: 3)
                : accuracy == TrackingAccuracy.medium
                    ? const Duration(minutes: 2)
                    : accuracy == TrackingAccuracy.precised
                        ? const Duration(seconds: 45)
                        : const Duration(minutes: 1)),
        locationAccuracy = locationAccuracy ??
            (accuracy == TrackingAccuracy.low
                ? TrackingAccuracy.medium
                : accuracy == TrackingAccuracy.medium
                    ? TrackingAccuracy.high
                    : TrackingAccuracy.precised),
        stationaryLocationAccuracy = stationaryLocationAccuracy ??
            locationAccuracy ??
            (accuracy == TrackingAccuracy.low
                ? TrackingAccuracy.medium
                : accuracy == TrackingAccuracy.medium
                    ? TrackingAccuracy.high
                    : TrackingAccuracy.precised),
        movingDistanceFilterMeters = movingDistanceFilterMeters ??
            (accuracy == TrackingAccuracy.low
                ? 25
                : accuracy == TrackingAccuracy.medium
                    ? 15
                    : accuracy == TrackingAccuracy.precised
                        ? 5
                        : 5),
        movingInterval = movingInterval ??
            (accuracy == TrackingAccuracy.low
                ? const Duration(seconds: 30)
                : accuracy == TrackingAccuracy.medium
                    ? const Duration(seconds: 15)
                    : accuracy == TrackingAccuracy.precised
                        ? const Duration(seconds: 5)
                        : const Duration(seconds: 10)),
        stationaryDistanceFilterMeters = stationaryDistanceFilterMeters ??
            (accuracy == TrackingAccuracy.low
                ? 100
                : accuracy == TrackingAccuracy.medium
                    ? 75
                    : accuracy == TrackingAccuracy.precised
                        ? 15
                        : 25),
        stationaryInterval = stationaryInterval ??
            (accuracy == TrackingAccuracy.low
                ? const Duration(minutes: 3)
                : accuracy == TrackingAccuracy.medium
                    ? const Duration(minutes: 2)
                    : accuracy == TrackingAccuracy.precised
                        ? const Duration(seconds: 30)
                        : const Duration(seconds: 30)),
        maximumAcceptedAccuracyMeters = maximumAcceptedAccuracyMeters ??
            (accuracy == TrackingAccuracy.low
                ? 100
                : accuracy == TrackingAccuracy.medium
                    ? 60
                    : accuracy == TrackingAccuracy.precised
                        ? 15
                        : 20),
        maximumProviderFixAge = maximumProviderFixAge ??
            largeGapThreshold ??
            const Duration(minutes: 5),
        acceptedGeometryGapThreshold = acceptedGeometryGapThreshold ??
            largeGapThreshold ??
            const Duration(minutes: 5),
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

  /// Core Location accuracy used after the stationary transition.
  ///
  /// By default this matches [locationAccuracy], so a high/precised session
  /// does not silently request fixes looser than its acceptance policy.
  final TrackingAccuracy stationaryLocationAccuracy;

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

  /// Maximum provider fix age accepted at native receipt.
  final Duration maximumProviderFixAge;

  /// Callback silence after which health may be reported as degraded.
  final Duration callbackHealthWarningThreshold;

  /// Accepted-anchor gap that should create durable diagnostic evidence.
  ///
  /// Exceeding this value is not by itself proof of an interruption.
  final Duration acceptedGeometryGapThreshold;

  /// Fallback used when capture continuity evidence is incomplete.
  final TrackingContinuityPolicy continuityPolicy;

  /// Legacy alias for [acceptedGeometryGapThreshold].
  @Deprecated(
    'Use maximumProviderFixAge and acceptedGeometryGapThreshold independently.',
  )
  Duration get largeGapThreshold => acceptedGeometryGapThreshold;
  final Duration firstFixTimeout;
  final String androidNotificationTitle;
  final String androidNotificationText;
  final IosTerminationRecoveryMode iosTerminationRecoveryMode;

  ResolvedTrackingAccuracy get resolvedAccuracy => ResolvedTrackingAccuracy(
        movingInterval: movingInterval,
        distanceFilterMeters: movingDistanceFilterMeters,
        locationAccuracy: locationAccuracy,
        stationaryInterval: stationaryInterval,
        stationaryDistanceFilterMeters: stationaryDistanceFilterMeters,
        maximumAcceptedAccuracyMeters: maximumAcceptedAccuracyMeters,
      );

  TrackingConfig copyWith({
    TrackingAccuracy? accuracy,
    TrackingAccuracy? locationAccuracy,
    TrackingAccuracy? stationaryLocationAccuracy,
    int? movingDistanceFilterMeters,
    Duration? movingInterval,
    int? stationaryDistanceFilterMeters,
    Duration? stationaryInterval,
    double? maximumAcceptedAccuracyMeters,
    double? maximumPlausibleSpeedMetersPerSecond,
    Duration? stationaryConfirmationDuration,
    double? stationaryProbeDisplacementMeters,
    int? stationaryConfidenceThreshold,
    int? movingConfidenceThreshold,
    int? movingConfirmationCount,
    Duration? activityRecognitionInterval,
    MockLocationPolicy? mockLocationPolicy,
    int? batchPointCount,
    Duration? batchMaxAge,
    Duration? largeGapThreshold,
    Duration? maximumProviderFixAge,
    Duration? callbackHealthWarningThreshold,
    Duration? acceptedGeometryGapThreshold,
    TrackingContinuityPolicy? continuityPolicy,
    Duration? firstFixTimeout,
    String? androidNotificationTitle,
    String? androidNotificationText,
    IosTerminationRecoveryMode? iosTerminationRecoveryMode,
  }) =>
      TrackingConfig(
        accuracy: accuracy ?? this.accuracy,
        locationAccuracy: locationAccuracy ?? this.locationAccuracy,
        stationaryLocationAccuracy:
            stationaryLocationAccuracy ?? this.stationaryLocationAccuracy,
        movingDistanceFilterMeters:
            movingDistanceFilterMeters ?? this.movingDistanceFilterMeters,
        movingInterval: movingInterval ?? this.movingInterval,
        stationaryDistanceFilterMeters: stationaryDistanceFilterMeters ??
            this.stationaryDistanceFilterMeters,
        stationaryInterval: stationaryInterval ?? this.stationaryInterval,
        maximumAcceptedAccuracyMeters:
            maximumAcceptedAccuracyMeters ?? this.maximumAcceptedAccuracyMeters,
        maximumPlausibleSpeedMetersPerSecond:
            maximumPlausibleSpeedMetersPerSecond ??
                this.maximumPlausibleSpeedMetersPerSecond,
        stationaryConfirmationDuration: stationaryConfirmationDuration ??
            this.stationaryConfirmationDuration,
        stationaryProbeDisplacementMeters: stationaryProbeDisplacementMeters ??
            this.stationaryProbeDisplacementMeters,
        stationaryConfidenceThreshold:
            stationaryConfidenceThreshold ?? this.stationaryConfidenceThreshold,
        movingConfidenceThreshold:
            movingConfidenceThreshold ?? this.movingConfidenceThreshold,
        movingConfirmationCount:
            movingConfirmationCount ?? this.movingConfirmationCount,
        activityRecognitionInterval:
            activityRecognitionInterval ?? this.activityRecognitionInterval,
        mockLocationPolicy: mockLocationPolicy ?? this.mockLocationPolicy,
        batchPointCount: batchPointCount ?? this.batchPointCount,
        batchMaxAge: batchMaxAge ?? this.batchMaxAge,
        maximumProviderFixAge:
            maximumProviderFixAge ?? this.maximumProviderFixAge,
        callbackHealthWarningThreshold: callbackHealthWarningThreshold ??
            this.callbackHealthWarningThreshold,
        acceptedGeometryGapThreshold: acceptedGeometryGapThreshold ??
            largeGapThreshold ??
            this.acceptedGeometryGapThreshold,
        continuityPolicy: continuityPolicy ?? this.continuityPolicy,
        firstFixTimeout: firstFixTimeout ?? this.firstFixTimeout,
        androidNotificationTitle:
            androidNotificationTitle ?? this.androidNotificationTitle,
        androidNotificationText:
            androidNotificationText ?? this.androidNotificationText,
        iosTerminationRecoveryMode:
            iosTerminationRecoveryMode ?? this.iosTerminationRecoveryMode,
      );

  void validate({String context = 'TrackingConfig'}) {
    final errors = <String>[];
    if (movingDistanceFilterMeters < 0) {
      errors.add('movingDistanceFilterMeters must be zero or greater');
    }
    if (stationaryDistanceFilterMeters < 0) {
      errors.add('stationaryDistanceFilterMeters must be zero or greater');
    }
    _positiveDuration(errors, 'movingInterval', movingInterval);
    _positiveDuration(errors, 'stationaryInterval', stationaryInterval);
    _positiveDuration(
      errors,
      'stationaryConfirmationDuration',
      stationaryConfirmationDuration,
    );
    _positiveDuration(
      errors,
      'activityRecognitionInterval',
      activityRecognitionInterval,
    );
    _positiveDuration(errors, 'batchMaxAge', batchMaxAge);
    _positiveDuration(errors, 'maximumProviderFixAge', maximumProviderFixAge);
    _positiveDuration(
      errors,
      'callbackHealthWarningThreshold',
      callbackHealthWarningThreshold,
    );
    _positiveDuration(
      errors,
      'acceptedGeometryGapThreshold',
      acceptedGeometryGapThreshold,
    );
    _positiveDuration(errors, 'firstFixTimeout', firstFixTimeout);
    _positiveFiniteDouble(
      errors,
      'maximumAcceptedAccuracyMeters',
      maximumAcceptedAccuracyMeters,
    );
    _positiveFiniteDouble(
      errors,
      'maximumPlausibleSpeedMetersPerSecond',
      maximumPlausibleSpeedMetersPerSecond,
    );
    if (!stationaryProbeDisplacementMeters.isFinite ||
        stationaryProbeDisplacementMeters < 0) {
      errors.add('stationaryProbeDisplacementMeters must be finite and >= 0');
    }
    _percent(
        errors, 'stationaryConfidenceThreshold', stationaryConfidenceThreshold);
    _percent(errors, 'movingConfidenceThreshold', movingConfidenceThreshold);
    if (movingConfirmationCount <= 0) {
      errors.add('movingConfirmationCount must be greater than zero');
    }
    if (batchPointCount <= 0) {
      errors.add('batchPointCount must be greater than zero');
    }
    if (androidNotificationTitle.trim().isEmpty) {
      errors.add('androidNotificationTitle must not be empty');
    }
    if (androidNotificationText.trim().isEmpty) {
      errors.add('androidNotificationText must not be empty');
    }
    if (errors.isEmpty) return;
    throw TrackingConfigurationException(
      code: 'invalid_configuration',
      message: '$context is invalid: ${errors.join('; ')}.',
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
        'accuracy': accuracy.name,
        'desiredAccuracy': locationAccuracy.name,
        'stationaryDesiredAccuracy': stationaryLocationAccuracy.name,
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
        // Keep the legacy key in resolved epoch JSON for older native/custom
        // consumers while persisting the independent policy values as well.
        'largeGapThresholdMs': acceptedGeometryGapThreshold.inMilliseconds,
        'maximumProviderFixAgeMs': maximumProviderFixAge.inMilliseconds,
        'callbackHealthWarningThresholdMs':
            callbackHealthWarningThreshold.inMilliseconds,
        'acceptedGeometryGapThresholdMs':
            acceptedGeometryGapThreshold.inMilliseconds,
        'continuityPolicy': continuityPolicy.name,
        'firstFixTimeoutMs': firstFixTimeout.inMilliseconds,
        'notificationTitle': androidNotificationTitle,
        'notificationText': androidNotificationText,
        if (iosTerminationRecoveryMode !=
            IosTerminationRecoveryMode.interrupted)
          'iosTerminationRecoveryMode': iosTerminationRecoveryMode.name,
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
      stationaryLocationAccuracy: map.containsKey('stationaryDesiredAccuracy')
          ? TrackingAccuracy.parse(
              map['stationaryDesiredAccuracy'],
              fallback: map.containsKey('desiredAccuracy')
                  ? TrackingAccuracy.parse(
                      map['desiredAccuracy'],
                      fallback: accuracy,
                    )
                  : accuracy,
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
      largeGapThreshold: map.containsKey('largeGapThresholdMs')
          ? Duration(milliseconds: integer('largeGapThresholdMs')!)
          : null,
      maximumProviderFixAge: duration('maximumProviderFixAgeMs'),
      callbackHealthWarningThreshold:
          duration('callbackHealthWarningThresholdMs') ??
              const Duration(minutes: 2),
      acceptedGeometryGapThreshold: duration('acceptedGeometryGapThresholdMs'),
      continuityPolicy: TrackingContinuityPolicy.parse(
        map['continuityPolicy'],
      ),
      firstFixTimeout: Duration(
        milliseconds: integer('firstFixTimeoutMs') ??
            (accuracy == TrackingAccuracy.low
                ? 180000
                : accuracy == TrackingAccuracy.medium
                    ? 120000
                    : accuracy == TrackingAccuracy.precised
                        ? 45000
                        : 60000),
      ),
      androidNotificationTitle:
          map['notificationTitle'] as String? ?? 'Location tracking active',
      androidNotificationText:
          map['notificationText'] as String? ?? 'Recording your route',
      iosTerminationRecoveryMode: IosTerminationRecoveryMode.values.firstWhere(
        (mode) => mode.name == map['iosTerminationRecoveryMode'],
        orElse: () => IosTerminationRecoveryMode.interrupted,
      ),
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

  TrackingConfiguration copyWith({
    String? databaseName,
    String? exportDirectoryName,
    TrackRecordRetentionPolicy? recordRetentionPolicy,
    TrackingConfig? defaultTrackingConfig,
    int? maximumUploadBatchPointCount,
    int? maximumUploadBatchBytes,
    Duration? uploadLeaseDuration,
    Duration? uploadInitialBackoff,
    Duration? uploadMaximumBackoff,
    Duration? uploadRecoveryInterval,
  }) =>
      TrackingConfiguration(
        databaseName: databaseName ?? this.databaseName,
        exportDirectoryName: exportDirectoryName ?? this.exportDirectoryName,
        recordRetentionPolicy:
            recordRetentionPolicy ?? this.recordRetentionPolicy,
        defaultTrackingConfig:
            defaultTrackingConfig ?? this.defaultTrackingConfig,
        maximumUploadBatchPointCount:
            maximumUploadBatchPointCount ?? this.maximumUploadBatchPointCount,
        maximumUploadBatchBytes:
            maximumUploadBatchBytes ?? this.maximumUploadBatchBytes,
        uploadLeaseDuration: uploadLeaseDuration ?? this.uploadLeaseDuration,
        uploadInitialBackoff: uploadInitialBackoff ?? this.uploadInitialBackoff,
        uploadMaximumBackoff: uploadMaximumBackoff ?? this.uploadMaximumBackoff,
        uploadRecoveryInterval:
            uploadRecoveryInterval ?? this.uploadRecoveryInterval,
      );

  void validate({String context = 'TrackingConfiguration'}) {
    final errors = <String>[];
    if (databaseName.trim().isEmpty) {
      errors.add('databaseName must not be empty');
    }
    if (exportDirectoryName.trim().isEmpty) {
      errors.add('exportDirectoryName must not be empty');
    }
    if (maximumUploadBatchPointCount <= 0) {
      errors.add('maximumUploadBatchPointCount must be greater than zero');
    }
    if (maximumUploadBatchBytes <= 0) {
      errors.add('maximumUploadBatchBytes must be greater than zero');
    }
    _positiveDuration(errors, 'uploadLeaseDuration', uploadLeaseDuration);
    _positiveDuration(errors, 'uploadInitialBackoff', uploadInitialBackoff);
    _positiveDuration(errors, 'uploadMaximumBackoff', uploadMaximumBackoff);
    _positiveDuration(errors, 'uploadRecoveryInterval', uploadRecoveryInterval);
    try {
      defaultTrackingConfig.validate(context: '$context.defaultTrackingConfig');
    } on TrackingConfigurationException catch (error) {
      errors.add(error.message);
    }
    if (errors.isEmpty) return;
    throw TrackingConfigurationException(
      code: 'invalid_configuration',
      message: '$context is invalid: ${errors.join('; ')}.',
    );
  }
}

void _positiveDuration(List<String> errors, String name, Duration value) {
  if (value <= Duration.zero) {
    errors.add('$name must be greater than zero');
  }
}

void _positiveFiniteDouble(List<String> errors, String name, double value) {
  if (!value.isFinite || value <= 0) {
    errors.add('$name must be finite and greater than zero');
  }
}

void _percent(List<String> errors, String name, int value) {
  if (value < 0 || value > 100) {
    errors.add('$name must be between 0 and 100');
  }
}
