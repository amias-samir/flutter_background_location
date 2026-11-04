import 'dart:convert';

import 'package:flutter_background_location_tracker/src/domain/persisted_tracking_config.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_config.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_configuration_epoch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('new configurations and host maps use the current motion policy', () {
    const config = TrackingConfig();
    expect(config.motionPolicyVersion, TrackingPolicyVersions.motionPolicy);
    expect(config.toMap()['motionPolicyVersion'], 2);
    // A host map without the key resolves like the constructor.
    expect(
      TrackingConfig.fromMap(const <String, Object?>{'accuracy': 'high'})
          .motionPolicyVersion,
      2,
    );
    expect(
      TrackingConfig.fromJson(config.toJson()).motionPolicyVersion,
      2,
    );
  });

  test('configurations the package persisted before the key stay legacy', () {
    final legacyJson = jsonEncode(
      const TrackingConfig().toMap()..remove('motionPolicyVersion'),
    );
    expect(
      decodePersistedTrackingConfig(legacyJson).motionPolicyVersion,
      TrackingPolicyVersions.legacyMotionPolicy,
    );
    expect(
      decodePersistedTrackingConfig(const TrackingConfig().toJson())
          .motionPolicyVersion,
      2,
    );
  });

  test('an epoch recorded before motion policy 2 resumes with policy 1', () {
    final legacyJson = jsonEncode(
      const TrackingConfig().toMap()..remove('motionPolicyVersion'),
    );
    final epoch = TrackingConfigurationEpoch.fromDatabase(<String, Object?>{
      'id': 'epoch-1',
      'track_id': 'track-1',
      'epoch_number': 1,
      'resolved_configuration_json': legacyJson,
      'preset_definition_version': 4,
      'quality_policy_version': 1,
      'continuity_policy_version': 3,
      'created_at': '2026-10-18T13:01:19.000Z',
      'activation_sequence': 1,
      'activated_at': '2026-10-18T13:01:19.000Z',
    });
    expect(epoch.resolvedConfig.motionPolicyVersion, 1);
    // Re-encoding the resumed configuration keeps the legacy policy for
    // native code.
    expect(epoch.resolvedConfig.toMap()['motionPolicyVersion'], 1);
  });

  test('unsupported values resolve to the newest supported policy', () {
    expect(
      TrackingConfig.fromMap(const <String, Object?>{'motionPolicyVersion': 9})
          .motionPolicyVersion,
      2,
    );
    expect(TrackingPolicyVersions.resolveMotionPolicy(1), 1);
    expect(TrackingPolicyVersions.resolveMotionPolicy(0), 2);
  });

  test('copies and preset changes keep the motion policy', () {
    final legacy = TrackingConfig.fromMap(
      const <String, Object?>{'motionPolicyVersion': 1},
    );
    expect(legacy.copyWith(batchPointCount: 10).motionPolicyVersion, 1);
    expect(legacy.withPreset(TrackingAccuracy.low).motionPolicyVersion, 1);
    expect(
      const TrackingConfig()
          .withPreset(TrackingAccuracy.precised)
          .motionPolicyVersion,
      2,
    );
  });
}
