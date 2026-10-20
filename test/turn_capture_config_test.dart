import 'dart:convert';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/src/domain/persisted_tracking_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// `turnCaptureDegrees`: a fix between the regular ones when a moving route
/// turns sharply, so junctions and hairpins are not cut.
void main() {
  test('High and Precised capture turns at 45 degrees; Medium and Low do not',
      () {
    for (final intent in RouteCaptureIntent.values) {
      expect(
        TrackingConfig(captureIntent: intent).turnCaptureDegrees,
        45,
      );
      expect(
        TrackingConfig(
                accuracy: TrackingAccuracy.precised, captureIntent: intent)
            .turnCaptureDegrees,
        45,
      );
      expect(
        TrackingConfig(accuracy: TrackingAccuracy.medium, captureIntent: intent)
            .turnCaptureDegrees,
        0,
      );
      expect(
        TrackingConfig(accuracy: TrackingAccuracy.low, captureIntent: intent)
            .turnCaptureDegrees,
        0,
      );
    }
  });

  test('a custom angle survives maps, JSON and other fields changing', () {
    const custom = TrackingConfig(
      accuracy: TrackingAccuracy.medium,
      turnCaptureDegrees: 60,
    );
    expect(custom.toMap()['turnCaptureDegrees'], 60);
    expect(TrackingConfig.fromMap(custom.toMap()).turnCaptureDegrees, 60);
    expect(TrackingConfig.fromJson(custom.toJson()).turnCaptureDegrees, 60);
    expect(
      decodePersistedTrackingConfig(custom.toJson()).turnCaptureDegrees,
      60,
    );
    expect(
      custom
          .copyWith(movingInterval: const Duration(seconds: 8))
          .turnCaptureDegrees,
      60,
    );
    expect(
      const TrackingConfig(turnCaptureDegrees: 0).turnCaptureDegrees,
      0,
      reason: 'zero turns it off',
    );
  });

  test('switching the preset takes its turn capture', () {
    const custom = TrackingConfig(
      accuracy: TrackingAccuracy.low,
      turnCaptureDegrees: 30,
    );
    expect(custom.withPreset(TrackingAccuracy.high).turnCaptureDegrees, 45);
    expect(custom.withPreset(TrackingAccuracy.medium).turnCaptureDegrees, 0);
  });

  test('a route stored before turn capture resumes without it', () {
    final legacy = Map<String, Object?>.of(const TrackingConfig().toMap())
      ..remove('turnCaptureDegrees');
    expect(
      decodePersistedTrackingConfig(jsonEncode(legacy)).turnCaptureDegrees,
      0,
    );
    // A host map without the key takes the preset, like the constructor.
    expect(TrackingConfig.fromMap(legacy).turnCaptureDegrees, 45);
  });

  test('angles outside 0 to 180 degrees are rejected', () {
    expect(
      () => TrackingConfig(turnCaptureDegrees: 200),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => TrackingConfig(turnCaptureDegrees: -1),
      throwsA(isA<AssertionError>()),
    );
  });
}
