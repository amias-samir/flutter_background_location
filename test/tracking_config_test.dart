import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('high is the default accuracy profile', () {
    const config = TrackingConfig();

    expect(config.accuracy, TrackingAccuracy.high);
    expect(config.locationAccuracy, TrackingAccuracy.high);
    expect(config.movingInterval, const Duration(seconds: 15));
    expect(config.movingDistanceFilterMeters, 15);
    expect(config.stationaryInterval, const Duration(minutes: 2));
    expect(config.stationaryDistanceFilterMeters, 75);
    expect(config.maximumAcceptedAccuracyMeters, 60);
  });

  test('accuracy profiles resolve all predefined sampling values', () {
    const expectations = <TrackingAccuracy, Object>{
      TrackingAccuracy.low: (
        Duration(minutes: 1),
        50,
        Duration(minutes: 5),
        200,
        200.0,
      ),
      TrackingAccuracy.medium: (
        Duration(seconds: 30),
        25,
        Duration(minutes: 3),
        100,
        100.0,
      ),
      TrackingAccuracy.high: (
        Duration(seconds: 15),
        15,
        Duration(minutes: 2),
        75,
        60.0,
      ),
      TrackingAccuracy.precised: (
        Duration(seconds: 5),
        5,
        Duration(seconds: 30),
        25,
        20.0,
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
      expect(config.locationAccuracy, accuracy, reason: accuracy.name);
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
    expect(config.movingDistanceFilterMeters, 50);
    expect(config.stationaryInterval, const Duration(minutes: 5));
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
        movingInterval: Duration(seconds: 30),
        distanceFilterMeters: 8,
        locationAccuracy: TrackingAccuracy.precised,
        stationaryInterval: Duration(minutes: 3),
        stationaryDistanceFilterMeters: 100,
        maximumAcceptedAccuracyMeters: 100,
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
    expect(restored.movingInterval, const Duration(seconds: 30));
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

  test('legacy maps without a profile keep the previous high defaults', () {
    final config = TrackingConfig.fromMap(<String, Object?>{
      'movingIntervalMs': 12000,
      'stationaryDistanceFilterMeters': 45,
    });

    expect(config.accuracy, TrackingAccuracy.high);
    expect(config.locationAccuracy, TrackingAccuracy.high);
    expect(config.movingInterval, const Duration(seconds: 12));
    expect(config.movingDistanceFilterMeters, 15);
    expect(config.stationaryInterval, const Duration(minutes: 2));
    expect(config.stationaryDistanceFilterMeters, 45);
    expect(config.maximumAcceptedAccuracyMeters, 60);
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
