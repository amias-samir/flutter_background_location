import 'dart:convert';

import 'package:flutter_background_location_tracker/src/domain/persisted_tracking_config.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_config.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_configuration_epoch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new configurations and host maps use sampling policy 2', () {
    const config = TrackingConfig();
    expect(config.samplingPolicyVersion, TrackingPolicyVersions.samplingPolicy);
    expect(config.toMap()['samplingPolicyVersion'], 2);
    // A host map without the key resolves like the constructor.
    expect(
      TrackingConfig.fromMap(const <String, Object?>{'accuracy': 'high'})
          .samplingPolicyVersion,
      2,
    );
    expect(TrackingConfig.fromJson(config.toJson()).samplingPolicyVersion, 2);
  });

  test('configurations the package persisted before the key keep policy 1', () {
    final legacyJson = jsonEncode(
      const TrackingConfig().toMap()..remove('samplingPolicyVersion'),
    );
    expect(
      decodePersistedTrackingConfig(legacyJson).samplingPolicyVersion,
      TrackingPolicyVersions.legacySamplingPolicy,
    );
    expect(
      decodePersistedTrackingConfig(const TrackingConfig().toJson())
          .samplingPolicyVersion,
      2,
    );
  });

  test('a route recording across the upgrade resumes with sampling policy 1',
      () {
    final legacyJson = jsonEncode(
      const TrackingConfig().toMap()..remove('samplingPolicyVersion'),
    );
    final epoch = TrackingConfigurationEpoch.fromDatabase(<String, Object?>{
      'id': 'epoch-1',
      'track_id': 'track-1',
      'epoch_number': 1,
      'resolved_configuration_json': legacyJson,
      'preset_definition_version': 5,
      'quality_policy_version': 4,
      'continuity_policy_version': 3,
      'created_at': '2026-10-24T02:00:00.000Z',
      'activation_sequence': 1,
      'activated_at': '2026-10-24T02:00:00.000Z',
    });
    expect(epoch.resolvedConfig.samplingPolicyVersion, 1);
    // Native code receives the policy the route started with.
    expect(epoch.resolvedConfig.toMap()['samplingPolicyVersion'], 1);
  });

  test('invalid and unsupported values resolve to the newest supported policy',
      () {
    expect(
      TrackingConfig.fromMap(
        const <String, Object?>{'samplingPolicyVersion': 9},
      ).samplingPolicyVersion,
      2,
    );
    expect(
      TrackingConfig.fromMap(
        const <String, Object?>{'samplingPolicyVersion': 1.0},
      ).samplingPolicyVersion,
      1,
    );
    expect(TrackingPolicyVersions.resolveSamplingPolicy(1), 1);
    expect(TrackingPolicyVersions.resolveSamplingPolicy(0), 2);
  });

  test('copies and preset changes keep the sampling policy', () {
    final legacy = TrackingConfig.fromMap(
      const <String, Object?>{'samplingPolicyVersion': 1},
    );
    expect(legacy.copyWith(batchPointCount: 10).samplingPolicyVersion, 1);
    expect(legacy.withPreset(TrackingAccuracy.low).samplingPolicyVersion, 1);
    expect(
      const TrackingConfig()
          .withPreset(TrackingAccuracy.precised)
          .samplingPolicyVersion,
      2,
    );
  });
}
