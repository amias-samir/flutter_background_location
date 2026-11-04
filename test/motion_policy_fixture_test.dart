import 'dart:convert';
import 'dart:io';

import 'package:flutter_background_location_tracker/src/application/motion_gate.dart';
import 'package:flutter_background_location_tracker/src/domain/activity_snapshot.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives Dart's MotionGate through the motion-policy-2 fixture the Kotlin
/// and Swift state machines also replay.
void main() {
  const canonicalPath = 'test/fixtures/cross_language/motion_policy_v2.json';
  const copies = <String>[
    'android/src/test/resources/motion_policy_v2.json',
    'example/ios/RunnerTests/motion_policy_v2.json',
  ];

  test('native copies of the fixture are byte-identical', () {
    final canonical = File(canonicalPath).readAsBytesSync();
    for (final copy in copies) {
      expect(File(copy).readAsBytesSync(), canonical, reason: copy);
    }
  });

  final fixture = (jsonDecode(File(canonicalPath).readAsStringSync()) as Map)
      .cast<String, Object?>();
  final settings = (fixture['config']! as Map).cast<String, Object?>();
  final config = TrackingConfig(
    stationaryConfidenceThreshold:
        settings['stationaryConfidenceThreshold']! as int,
    movingConfidenceThreshold: settings['movingConfidenceThreshold']! as int,
    movingConfirmationCount: settings['movingConfirmationCount']! as int,
    stationaryConfirmationDuration: Duration(
      seconds: settings['confirmationSeconds']! as int,
    ),
  );
  final start = DateTime.utc(2026, 10, 18, 13);

  for (final raw in fixture['scenarios']! as List<Object?>) {
    final scenario = (raw! as Map).cast<String, Object?>();
    final platforms = (scenario['platforms']! as List<Object?>).cast<String>();
    if (!platforms.contains('dart')) continue;
    test(scenario['name']! as String, () {
      final gate = MotionGate(config);
      var checked = 0;
      for (final rawStep in scenario['steps']! as List<Object?>) {
        final step = (rawStep! as Map).cast<String, Object?>();
        // MotionGate sees activity only; fix-driven departures belong to the
        // native state machines and the canonical stop hold.
        if (step['positionDriven'] == true) break;
        final at = start.add(Duration(seconds: step['t']! as int));
        final reading = step['reading'];
        if (reading is Map) {
          gate.add(
            ActivitySnapshot(
              type: trackingActivityTypeFromValue(reading['type']),
              confidence: reading['confidence']! as int,
              recordedAt: at,
              source: reading['source']! as String,
            ),
            at,
          );
        } else {
          gate.evaluate(at);
        }
        final expectation = step['expect'];
        if (expectation is Map && expectation.containsKey('episode')) {
          expect(
            gate.stillEpisodeActive,
            expectation['episode'],
            reason: 't=${step['t']}',
          );
          checked += 1;
        }
      }
      expect(checked, greaterThan(0));
    });
  }
}
