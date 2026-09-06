import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/quality/validate_physical_qualification.dart' as qualification;

void main() {
  final protocol = (jsonDecode(
    File(
      'tool/quality/physical_qualification_protocol.json',
    ).readAsStringSync(),
  ) as Map)
      .cast<String, Object?>();

  test('accepts complete coordinate-free qualification aggregates', () {
    final evidence = _validEvidence(protocol);

    expect(
      qualification.validatePhysicalQualification(
        protocol: protocol,
        evidence: evidence,
      ),
      isEmpty,
    );
  });

  test('rejects persisted raw sensors and missing fusion coverage', () {
    final evidence = _validEvidence(protocol);
    final runs =
        (evidence['routeBenchmarks']! as List).cast<Map<String, Object?>>();
    for (final run in runs.where((run) => run['platform'] == 'android')) {
      run['motionFusionMode'] = 'platformActivityOnly';
    }
    (runs.first['metrics']!
        as Map<String, Object?>)['rawSensorEventsPersisted'] = 1;

    final errors = qualification.validatePhysicalQualification(
      protocol: protocol,
      evidence: evidence,
    );

    expect(errors, contains(contains('persisted raw sensor events')));
    expect(
      errors,
      contains(contains('motionFusionMode=lowPowerSensorFusion')),
    );
    expect(
      errors,
      contains(contains('motionFusionMode=enhancedSensorFusion')),
    );
  });

  test('rejects sensitive coordinate-shaped evidence keys', () {
    final evidence = _validEvidence(protocol)
      ..['deviceCoordinates'] = <String, Object?>{'value': 'redacted'};

    final errors = qualification.validatePhysicalQualification(
      protocol: protocol,
      evidence: evidence,
    );

    expect(errors, contains(contains('Forbidden sensitive key')));
  });
}

Map<String, Object?> _validEvidence(Map<String, Object?> protocol) {
  final modes = _strings(protocol['motionFusionModes']);
  final intents = _strings(protocol['captureIntents']);
  final carryStates = _strings(protocol['carryStates']);
  final powerStates = _strings(protocol['powerStates']);
  final metricKeys = _strings(protocol['requiredMetricKeys']);
  final runs = <Map<String, Object?>>[];
  var index = 0;
  for (final platform in _strings(protocol['platforms'])) {
    for (final preset in _strings(protocol['presets'])) {
      for (final scenario in _strings(protocol['routeScenarios'])) {
        runs.add(<String, Object?>{
          'platform': platform,
          'preset': preset,
          'scenario': scenario,
          'motionFusionMode': modes[index % modes.length],
          'captureIntent': intents[index % intents.length],
          'carryState': carryStates[index % carryStates.length],
          'powerState': powerStates[index % powerStates.length],
          'repetitions': protocol['minimumComparableRouteRuns'],
          'metrics': <String, Object?>{
            for (final key in metricKeys) key: _validMetric(key),
          },
          'batteryRegressionPercent': 0,
        });
        index += 1;
      }
    }
  }
  return <String, Object?>{
    'schemaVersion': protocol['schemaVersion'],
    'candidateCommit': 'candidate',
    'toolchainId': 'toolchain',
    'approvedBaselineCommit': 'baseline',
    'routeBenchmarks': runs,
    'iosTerminationRecovery': <Map<String, Object?>>[
      for (final scenario in _strings(protocol['iosRecoveryScenarios']))
        <String, Object?>{
          'scenario': scenario,
          'repetitions': protocol['minimumTerminationRecoveryRuns'],
          'outcomesRecorded': protocol['minimumTerminationRecoveryRuns'],
          'automaticRecoveryObserved': false,
        },
    ],
    'appStorePrivacyWordingApproved': true,
    'googlePlayDataSafetyWordingApproved': true,
  };
}

num _validMetric(String key) => switch (key) {
      'acceptedFixRatio' => 0.9,
      'sensorProbeDutyCyclePercent' => 1,
      'rawSensorEventsPersisted' => 0,
      _ => 1,
    };

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : const <String>[];
