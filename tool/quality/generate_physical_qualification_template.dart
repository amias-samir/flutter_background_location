import 'dart:convert';
import 'dart:io';

const _protocolPath = 'tool/quality/physical_qualification_protocol.json';
const _defaultOutputPath = 'build/quality/physical_qualification_template.json';

void main(List<String> arguments) {
  final outputPath = arguments.isEmpty ? _defaultOutputPath : arguments.single;
  final protocolFile = File(_protocolPath);
  if (!protocolFile.existsSync()) {
    stderr.writeln('Missing $_protocolPath');
    exitCode = 66;
    return;
  }
  final protocol = (jsonDecode(protocolFile.readAsStringSync()) as Map)
      .cast<String, Object?>();
  final routeBenchmarks = <Map<String, Object?>>[];
  var coverageIndex = 0;
  for (final platform in _strings(protocol['platforms'])) {
    for (final preset in _strings(protocol['presets'])) {
      for (final scenario in _strings(protocol['routeScenarios'])) {
        routeBenchmarks.add(<String, Object?>{
          'platform': platform,
          'preset': preset,
          'scenario': scenario,
          'motionFusionMode': _cycled(
            protocol['motionFusionModes'],
            coverageIndex,
          ),
          'captureIntent': _cycled(protocol['captureIntents'], coverageIndex),
          'carryState': _cycled(protocol['carryStates'], coverageIndex),
          'powerState': _cycled(protocol['powerStates'], coverageIndex),
          'repetitions': protocol['minimumComparableRouteRuns'],
          'metrics': <String, Object?>{
            for (final key in _strings(protocol['requiredMetricKeys']))
              key: null,
          },
          'batteryRegressionPercent': null,
          'regressionReviewApproved': false,
          'reviewNotes': '',
        });
        coverageIndex += 1;
      }
    }
  }
  final evidence = <String, Object?>{
    'schemaVersion': protocol['schemaVersion'],
    'templateOnly': true,
    'candidateCommit': '',
    'toolchainId': '',
    'approvedBaselineCommit': '',
    'routeBenchmarks': routeBenchmarks,
    'iosTerminationRecovery': <Map<String, Object?>>[
      for (final scenario in _strings(protocol['iosRecoveryScenarios']))
        <String, Object?>{
          'scenario': scenario,
          'repetitions': protocol['minimumTerminationRecoveryRuns'],
          'outcomesRecorded': 0,
          'automaticRecoveryObserved': false,
          'reviewNotes': '',
        },
    ],
    'appStorePrivacyWordingApproved': false,
    'googlePlayDataSafetyWordingApproved': false,
  };
  final output = File(outputPath);
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(evidence)}\n',
    flush: true,
  );
  stdout.writeln(
    'Wrote an intentionally incomplete, coordinate-free qualification '
    'template to $outputPath.',
  );
}

String _cycled(Object? values, int index) {
  final options = _strings(values);
  return options[index % options.length];
}

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : const <String>[];
