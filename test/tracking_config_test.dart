import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('high is the default accuracy profile', () {
    const config = TrackingConfig();

    expect(config.accuracy, TrackingAccuracy.high);
    expect(config.locationAccuracy, TrackingAccuracy.precised);
    expect(config.movingInterval, const Duration(seconds: 5));
    expect(config.movingDistanceFilterMeters, 5);
    expect(config.stationaryInterval, const Duration(seconds: 20));
    expect(config.stationaryDistanceFilterMeters, 20);
    expect(config.maximumAcceptedAccuracyMeters, 20);
    expect(config.maximumProviderFixAge, const Duration(minutes: 5));
    expect(config.movingConfirmationCount, 1);
    expect(config.activityRecognitionInterval, const Duration(seconds: 5));
    expect(config.activityFreshnessThreshold, const Duration(seconds: 30));
    expect(config.motionEvidenceFreshness, const Duration(seconds: 30));
  });

  test('accuracy profiles resolve all predefined sampling values', () {
    const expectations = <TrackingAccuracy, Object>{
      TrackingAccuracy.low: (
        Duration(seconds: 20),
        20,
        Duration(minutes: 2),
        75,
        100.0,
        TrackingAccuracy.medium,
      ),
      TrackingAccuracy.medium: (
        Duration(seconds: 10),
        10,
        Duration(minutes: 1),
        50,
        60.0,
        TrackingAccuracy.high,
      ),
      TrackingAccuracy.high: (
        Duration(seconds: 5),
        5,
        Duration(seconds: 20),
        20,
        20.0,
        TrackingAccuracy.precised,
      ),
      TrackingAccuracy.precised: (
        Duration(seconds: 3),
        3,
        Duration(seconds: 15),
        10,
        15.0,
        TrackingAccuracy.precised,
      ),
    };

    for (final MapEntry(key: accuracy, value: expected)
        in expectations.entries) {
      final config = TrackingConfig(accuracy: accuracy);
      final values = expected as (
        Duration,
        int,
        Duration,
        int,
        double,
        TrackingAccuracy,
      );
      expect(config.movingInterval, values.$1, reason: accuracy.name);
      expect(config.movingDistanceFilterMeters, values.$2,
          reason: accuracy.name);
      expect(config.stationaryInterval, values.$3, reason: accuracy.name);
      expect(config.stationaryDistanceFilterMeters, values.$4,
          reason: accuracy.name);
      expect(config.maximumAcceptedAccuracyMeters, values.$5,
          reason: accuracy.name);
      expect(accuracy.maximumAcceptedAccuracyMeters, values.$5,
          reason: '${accuracy.name} enum value');
      expect(config.locationAccuracy, values.$6, reason: accuracy.name);
    }
  });

  test('individual values override only their matching preset values', () {
    const config = TrackingConfig(
      accuracy: TrackingAccuracy.low,
      locationAccuracy: TrackingAccuracy.precised,
      movingInterval: Duration(seconds: 8),
      stationaryDistanceFilterMeters: 12,
      maximumAcceptedAccuracyMeters: 9,
    );

    expect(config.accuracy, TrackingAccuracy.low);
    expect(config.locationAccuracy, TrackingAccuracy.precised);
    expect(config.movingInterval, const Duration(seconds: 8));
    expect(config.movingDistanceFilterMeters, 20);
    expect(config.stationaryInterval, const Duration(minutes: 2));
    expect(config.stationaryDistanceFilterMeters, 12);
    expect(config.maximumAcceptedAccuracyMeters, 9);
  });

  test('resolved accuracy exposes the final effective values', () {
    const config = TrackingConfig(
      accuracy: TrackingAccuracy.medium,
      locationAccuracy: TrackingAccuracy.precised,
      movingDistanceFilterMeters: 8,
    );

    expect(
      config.resolvedAccuracy,
      const ResolvedTrackingAccuracy(
        movingInterval: Duration(seconds: 10),
        distanceFilterMeters: 8,
        locationAccuracy: TrackingAccuracy.precised,
        stationaryInterval: Duration(minutes: 1),
        stationaryDistanceFilterMeters: 50,
        maximumAcceptedAccuracyMeters: 60,
      ),
    );
  });

  test('runtime validation catches invalid tracking config in release paths',
      () {
    final config = TrackingConfig.fromMap(<String, Object?>{
      'movingIntervalMs': 0,
      'stationaryIntervalMs': -1,
      'notificationTitle': ' ',
      'notificationText': '',
    });

    expect(
      () => config.validate(),
      throwsA(
        isA<TrackingConfigurationException>()
            .having((error) => error.code, 'code', 'invalid_configuration')
            .having(
              (error) => error.message,
              'message',
              allOf(
                contains('movingInterval'),
                contains('stationaryInterval'),
                contains('androidNotificationTitle'),
                contains('androidNotificationText'),
              ),
            ),
      ),
    );
  });

  test('accuracy and overrides survive JSON serialization', () {
    const original = TrackingConfig(
      accuracy: TrackingAccuracy.medium,
      locationAccuracy: TrackingAccuracy.precised,
      movingDistanceFilterMeters: 7,
    );

    final restored = TrackingConfig.fromJson(original.toJson());

    expect(restored.accuracy, TrackingAccuracy.medium);
    expect(restored.locationAccuracy, TrackingAccuracy.precised);
    expect(restored.movingDistanceFilterMeters, 7);
    expect(restored.movingInterval, const Duration(seconds: 10));
    expect(restored.toMap()['desiredAccuracy'], 'precised');
  });

  test('iOS termination recovery is explicit and round-trips', () {
    const defaultConfig = TrackingConfig();
    const recoveryConfig = TrackingConfig(
      iosTerminationRecoveryMode: IosTerminationRecoveryMode.significantChange,
    );

    expect(defaultConfig.iosTerminationRecoveryMode,
        IosTerminationRecoveryMode.interrupted);
    expect(
      TrackingConfig.fromJson(recoveryConfig.toJson())
          .iosTerminationRecoveryMode,
      IosTerminationRecoveryMode.significantChange,
    );
  });

  test('motion fusion is migration-safe and all controls round-trip', () {
    const defaults = TrackingConfig();
    const configured = TrackingConfig(
      captureIntent: RouteCaptureIntent.walking,
      motionFusionMode: MotionFusionMode.enhancedSensorFusion,
      unknownMotionFallback: UnknownMotionFallback.preserveCurrentProfile,
      activityFreshnessThreshold: Duration(seconds: 35),
      motionEvidenceFreshness: Duration(seconds: 40),
      sensorProbeDuration: Duration(seconds: 3),
      sensorProbeCooldown: Duration(seconds: 25),
      sensorProbeMaximumDurationPerHour: Duration(minutes: 1),
    );

    expect(defaults.captureIntent, RouteCaptureIntent.adaptive);
    expect(defaults.motionFusionMode, MotionFusionMode.platformActivityOnly);
    final restored = TrackingConfig.fromJson(configured.toJson());
    expect(restored.captureIntent, RouteCaptureIntent.walking);
    expect(restored.motionFusionMode, MotionFusionMode.enhancedSensorFusion);
    expect(restored.unknownMotionFallback,
        UnknownMotionFallback.preserveCurrentProfile);
    expect(restored.activityFreshnessThreshold, const Duration(seconds: 35));
    expect(restored.motionEvidenceFreshness, const Duration(seconds: 40));
    expect(restored.sensorProbeDuration, const Duration(seconds: 3));
    expect(restored.sensorProbeCooldown, const Duration(seconds: 25));
    expect(
        restored.sensorProbeMaximumDurationPerHour, const Duration(minutes: 1));
  });

  test('legacy maps without a profile use the current high defaults', () {
    final config = TrackingConfig.fromMap(<String, Object?>{
      'movingIntervalMs': 12000,
      'stationaryDistanceFilterMeters': 45,
    });

    expect(config.accuracy, TrackingAccuracy.high);
    expect(config.locationAccuracy, TrackingAccuracy.precised);
    expect(config.movingInterval, const Duration(seconds: 12));
    expect(config.movingDistanceFilterMeters, 5);
    expect(config.stationaryInterval, const Duration(seconds: 20));
    expect(config.stationaryDistanceFilterMeters, 45);
    expect(config.maximumAcceptedAccuracyMeters, 20);
  });

  test('vehicle intent keeps dense capture and a bounded urban envelope', () {
    const vehicle = TrackingConfig(
      accuracy: TrackingAccuracy.high,
      captureIntent: RouteCaptureIntent.vehicle,
    );
    const overridden = TrackingConfig(
      accuracy: TrackingAccuracy.high,
      captureIntent: RouteCaptureIntent.vehicle,
      movingInterval: Duration(seconds: 7),
      movingDistanceFilterMeters: 8,
      maximumAcceptedAccuracyMeters: 18,
    );

    expect(vehicle.movingInterval, const Duration(seconds: 3));
    expect(vehicle.movingDistanceFilterMeters, 3);
    expect(vehicle.maximumAcceptedAccuracyMeters, 35);
    expect(overridden.movingInterval, const Duration(seconds: 7));
    expect(overridden.movingDistanceFilterMeters, 8);
    expect(overridden.maximumAcceptedAccuracyMeters, 18);
  });

  test('precise serialized spelling is accepted as a compatibility alias', () {
    final config = TrackingConfig.fromMap(<String, Object?>{
      'accuracy': 'precise',
      'desiredAccuracy': 'precise',
    });

    expect(config.accuracy, TrackingAccuracy.precised);
    expect(config.locationAccuracy, TrackingAccuracy.precised);
  });

  test('runtime validation catches invalid package configuration', () {
    final configuration = const TrackingConfiguration(
      databaseName: ' ',
      exportDirectoryName: '',
      uploadLeaseDuration: Duration.zero,
    );

    expect(
      () => configuration.validate(),
      throwsA(
        isA<TrackingConfigurationException>()
            .having((error) => error.code, 'code', 'invalid_configuration')
            .having(
              (error) => error.message,
              'message',
              allOf(
                contains('databaseName'),
                contains('exportDirectoryName'),
                contains('uploadLeaseDuration'),
              ),
            ),
      ),
    );
  });
}
