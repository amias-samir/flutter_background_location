import 'dart:convert';
import 'dart:io';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> load(int version) => (jsonDecode(
        File('test/fixtures/presets/preset_definition_v$version.json')
            .readAsStringSync(),
      ) as Map)
          .cast<String, Object?>();
  final fixture = load(6);
  final presets = (fixture['presets']! as Map).cast<String, Object?>();

  Iterable<(TrackingAccuracy, RouteCaptureIntent)> combinations() sync* {
    for (final accuracy in TrackingAccuracy.values) {
      for (final intent in RouteCaptureIntent.values) {
        yield (accuracy, intent);
      }
    }
  }

  // The motion policy is versioned on its own (TrackingPolicyVersions), not by
  // the preset definition, so the frozen preset record leaves it out.
  Map<String, Object?> presetRecord(TrackingConfig config) =>
      config.toMap()..remove('motionPolicyVersion');

  test('preset definition 6 resolves exactly as recorded', () {
    // Changing a preset value means a new preset-definition version, a new
    // configuration epoch for new routes, and a new fixture. Old routes are
    // never reinterpreted, so this record stays frozen.
    expect(fixture['presetDefinitionVersion'], 6);
    expect(
      TrackingPolicyVersions.presetDefinition,
      6,
      reason: 'Add preset_definition_v7.json when bumping the version.',
    );
    expect(presets, hasLength(combinations().length));
    for (final (accuracy, intent) in combinations()) {
      expect(
        presetRecord(
          TrackingConfig(accuracy: accuracy, captureIntent: intent),
        ),
        presets['${accuracy.name}/${intent.name}'],
        reason: '${accuracy.name}/${intent.name}',
      );
    }
  });

  test('preset definition 6 adds only sampling policy 2 to version 5', () {
    final version5 = (load(5)['presets']! as Map).cast<String, Object?>();
    expect(version5.keys, presets.keys);
    for (final key in presets.keys) {
      final current = Map<String, Object?>.of(
        (presets[key]! as Map).cast<String, Object?>(),
      );
      expect(current.remove('samplingPolicyVersion'), 2, reason: key);
      expect(current, version5[key], reason: key);
    }
  });

  test('preset definition 5 adds only turn capture to version 4', () {
    final version4 = (load(4)['presets']! as Map).cast<String, Object?>();
    final version5 = (load(5)['presets']! as Map).cast<String, Object?>();
    expect(version4.keys, version5.keys);
    for (final key in version5.keys) {
      final current = Map<String, Object?>.of(
        (version5[key]! as Map).cast<String, Object?>(),
      );
      final degrees = current.remove('turnCaptureDegrees');
      expect(current, version4[key], reason: key);
      expect(
        degrees,
        key.startsWith('high/') || key.startsWith('precised/') ? 45 : 0,
        reason: key,
      );
    }
  });

  test('FIX-12 a partial map resolves exactly like the constructor', () {
    for (final (accuracy, intent) in combinations()) {
      expect(
        TrackingConfig.fromMap(<String, Object?>{
          'accuracy': accuracy.name,
          'captureIntent': intent.name,
        }).toMap(),
        TrackingConfig(accuracy: accuracy, captureIntent: intent).toMap(),
        reason: '${accuracy.name}/${intent.name}',
      );
    }
  });

  // Keys a preset derives; withPreset must replace exactly these.
  const presetKeys = <String>{
    'accuracy',
    'desiredAccuracy',
    'stationaryDesiredAccuracy',
    'movingDistanceFilterMeters',
    'movingIntervalMs',
    'stationaryDistanceFilterMeters',
    'stationaryIntervalMs',
    'maximumAcceptedAccuracyMeters',
    'turnCaptureDegrees',
    'firstFixTimeoutMs',
  };

  test('presets vary only in the keys withPreset replaces', () {
    // A new preset-derived field must join presetKeys and withPreset.
    for (final intent in RouteCaptureIntent.values) {
      final baseline = TrackingConfig(captureIntent: intent).toMap();
      for (final accuracy in TrackingAccuracy.values) {
        final resolved =
            TrackingConfig(accuracy: accuracy, captureIntent: intent).toMap();
        final varying = {
          for (final key in resolved.keys)
            if (resolved[key] != baseline[key]) key,
        };
        expect(presetKeys, containsAll(varying), reason: accuracy.name);
      }
    }
  });

  test('FIX-04 withPreset replaces preset fields and keeps every other field',
      () {
    const custom = TrackingConfig(
      captureIntent: RouteCaptureIntent.walking,
      maximumPlausibleSpeedMetersPerSecond: 40,
      stationaryConfirmationDuration: Duration(seconds: 120),
      stationaryProbeDisplacementMeters: 45,
      stationaryConfidenceThreshold: 80,
      movingConfidenceThreshold: 65,
      movingConfirmationCount: 2,
      activityRecognitionInterval: Duration(seconds: 10),
      activityFreshnessThreshold: Duration(seconds: 50),
      staleActivityFallback: StaleActivityFallback.preserveCurrentProfile,
      motionFusionMode: MotionFusionMode.lowPowerSensorFusion,
      unknownMotionFallback: UnknownMotionFallback.preserveCurrentProfile,
      motionEvidenceFreshness: Duration(seconds: 40),
      sensorProbeDuration: Duration(seconds: 3),
      sensorProbeCooldown: Duration(seconds: 30),
      sensorProbeMaximumDurationPerHour: Duration(minutes: 2),
      mockLocationPolicy: MockLocationPolicy.reject,
      batchPointCount: 40,
      batchMaxAge: Duration(minutes: 4),
      maximumProviderFixAge: Duration(minutes: 3),
      callbackHealthWarningThreshold: Duration(minutes: 3),
      acceptedGeometryGapThreshold: Duration(minutes: 4),
      continuityPolicy: TrackingContinuityPolicy.preferContinuous,
      androidNotificationTitle: 'Route active',
      androidNotificationText: 'Recording',
      iosTerminationRecoveryMode: IosTerminationRecoveryMode.significantChange,
    );
    final original = custom.toMap();

    for (final accuracy in TrackingAccuracy.values) {
      final switched = custom.withPreset(accuracy).toMap();
      final preset = TrackingConfig(
        accuracy: accuracy,
        captureIntent: custom.captureIntent,
      ).toMap();

      expect(switched.keys.toSet(), original.keys.toSet());
      for (final key in original.keys) {
        expect(
          switched[key],
          presetKeys.contains(key) ? preset[key] : original[key],
          reason: '${accuracy.name}: $key',
        );
      }
    }
  });

  test('every preset survives a map round trip unchanged', () {
    for (final (accuracy, intent) in combinations()) {
      final resolved =
          TrackingConfig(accuracy: accuracy, captureIntent: intent).toMap();
      expect(
        TrackingConfig.fromMap(resolved).toMap(),
        resolved,
        reason: '${accuracy.name}/${intent.name}',
      );
    }
  });
}
