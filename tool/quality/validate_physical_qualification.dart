import 'dart:convert';
import 'dart:io';

const _protocolPath = 'tool/quality/physical_qualification_protocol.json';

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run tool/quality/validate_physical_qualification.dart '
      '<private-aggregate-evidence.json>',
    );
    exitCode = 64;
    return;
  }
  final protocolFile = File(_protocolPath);
  final evidenceFile = File(arguments.single);
  if (!protocolFile.existsSync() || !evidenceFile.existsSync()) {
    stderr.writeln('Protocol or evidence file does not exist.');
    exitCode = 66;
    return;
  }
  final protocol = _map(jsonDecode(protocolFile.readAsStringSync()));
  final evidence = _map(jsonDecode(evidenceFile.readAsStringSync()));
  final errors = validatePhysicalQualification(
    protocol: protocol,
    evidence: evidence,
  );
  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln('Qualification failure: $error');
    }
    exitCode = 1;
    return;
  }
  stdout.writeln('Physical qualification evidence satisfies protocol v1.');
}

/// Validates coordinate-free physical qualification aggregates.
///
/// An empty result means that the evidence satisfies the structural, coverage,
/// privacy, and safety gates. It does not independently verify that a physical
/// run occurred; candidate review and source evidence remain release duties.
List<String> validatePhysicalQualification({
  required Map<String, Object?> protocol,
  required Map<String, Object?> evidence,
}) {
  final errors = <String>[];
  _rejectSensitiveKeys(evidence, protocol, errors);
  if (evidence['schemaVersion'] != protocol['schemaVersion']) {
    errors.add('Evidence schemaVersion must match the protocol.');
  }
  _requiredText(evidence, 'candidateCommit', errors);
  _requiredText(evidence, 'toolchainId', errors);
  _requiredText(evidence, 'approvedBaselineCommit', errors);

  final routeRuns = _maps(evidence['routeBenchmarks']);
  final minimumRuns = protocol['minimumComparableRouteRuns'] as int;
  final requiredMetrics = _strings(protocol['requiredMetricKeys']);
  final platforms = _strings(protocol['platforms']);
  final presets = _strings(protocol['presets']);
  final scenarios = _strings(protocol['routeScenarios']);
  final coverageDimensions = <String, List<String>>{
    'motionFusionMode': _strings(protocol['motionFusionModes']),
    'captureIntent': _strings(protocol['captureIntents']),
    'carryState': _strings(protocol['carryStates']),
    'powerState': _strings(protocol['powerStates']),
  };
  for (final run in routeRuns) {
    _allowedValue(run, 'platform', platforms, errors);
    _allowedValue(run, 'preset', presets, errors);
    _allowedValue(run, 'scenario', scenarios, errors);
    for (final dimension in coverageDimensions.entries) {
      _allowedValue(run, dimension.key, dimension.value, errors);
    }
  }
  for (final platform in platforms) {
    for (final preset in presets) {
      for (final scenario in scenarios) {
        final matches = routeRuns.where(
          (run) =>
              run['platform'] == platform &&
              run['preset'] == preset &&
              run['scenario'] == scenario,
        );
        if (matches.isEmpty) {
          errors.add('Missing route benchmark: $platform/$preset/$scenario');
          continue;
        }
        for (final run in matches) {
          final repetitions = (run['repetitions'] as num?)?.toInt() ?? 0;
          if (repetitions < minimumRuns) {
            errors.add('$platform/$preset/$scenario has fewer than '
                '$minimumRuns repetitions.');
          }
          final metrics = run['metrics'] is Map
              ? _map(run['metrics'])
              : const <String, Object?>{};
          final missingMetrics = <String>[];
          for (final key in requiredMetrics) {
            final value = metrics[key];
            if (value is! num || !value.isFinite) {
              missingMetrics.add(key);
            }
          }
          if (missingMetrics.isNotEmpty) {
            errors.add(
              '$platform/$preset/$scenario has missing or non-finite metrics: '
              '${missingMetrics.join(', ')}.',
            );
          }
          _validateMetricRanges(
            metrics,
            '$platform/$preset/$scenario',
            errors,
          );
          final regression =
              (run['batteryRegressionPercent'] as num?)?.toDouble();
          if (regression != null &&
              regression > 10 &&
              run['regressionReviewApproved'] != true) {
            errors.add('$platform/$preset/$scenario has an unreviewed '
                '${regression.toStringAsFixed(2)}% battery regression.');
          }
        }
      }
    }
    final platformRuns = routeRuns.where((run) => run['platform'] == platform);
    for (final dimension in coverageDimensions.entries) {
      for (final expected in dimension.value) {
        if (!platformRuns.any((run) => run[dimension.key] == expected)) {
          errors.add(
            'Missing $platform coverage for ${dimension.key}=$expected.',
          );
        }
      }
    }
  }

  final recoveryRuns = _maps(evidence['iosTerminationRecovery']);
  final minimumRecovery = protocol['minimumTerminationRecoveryRuns'] as int;
  for (final scenario in _strings(protocol['iosRecoveryScenarios'])) {
    final matches = recoveryRuns.where((run) => run['scenario'] == scenario);
    if (matches.isEmpty) {
      errors.add('Missing iOS recovery scenario: $scenario');
      continue;
    }
    for (final run in matches) {
      final repetitions = (run['repetitions'] as num?)?.toInt() ?? 0;
      final outcomes = (run['outcomesRecorded'] as num?)?.toInt() ?? 0;
      if (repetitions < minimumRecovery || outcomes != repetitions) {
        errors.add('$scenario requires at least $minimumRecovery runs and one '
            'recorded outcome per run.');
      }
      if (scenario == 'user_force_quit' &&
          run['automaticRecoveryObserved'] == true) {
        errors.add('User force-quit must not be classified as recoverable.');
      }
    }
  }

  if (evidence['appStorePrivacyWordingApproved'] != true ||
      evidence['googlePlayDataSafetyWordingApproved'] != true) {
    errors.add('Store privacy/Data Safety wording approvals are required.');
  }
  return errors;
}

void _allowedValue(
  Map<String, Object?> run,
  String key,
  List<String> allowed,
  List<String> errors,
) {
  final value = run[key];
  if (value is! String || !allowed.contains(value)) {
    errors.add('Route benchmark has invalid $key: $value.');
  }
}

void _validateMetricRanges(
  Map<String, Object?> metrics,
  String label,
  List<String> errors,
) {
  final ratio = metrics['acceptedFixRatio'];
  if (ratio is num && (ratio < 0 || ratio > 1)) {
    errors.add('$label acceptedFixRatio must be between 0 and 1.');
  }
  final dutyCycle = metrics['sensorProbeDutyCyclePercent'];
  if (dutyCycle is num && (dutyCycle < 0 || dutyCycle > 100)) {
    errors.add('$label sensorProbeDutyCyclePercent must be 0 to 100.');
  }
  final rawSensorEvents = metrics['rawSensorEventsPersisted'];
  if (rawSensorEvents is num && rawSensorEvents != 0) {
    errors.add('$label persisted raw sensor events; expected exactly zero.');
  }
  const nonNegativeMetrics = <String>[
    'stationaryDriftMeanMeters',
    'stationaryDriftStdDevMeters',
    'firstFixMeanSeconds',
    'longestCallbackGapSeconds',
    'batteryMahPerHourMean',
    'batteryMahPerHourStdDev',
    'cpuSecondsPerHourMean',
    'peakRssMbMean',
    'wakeupsPerHourMean',
    'motionRecoveryP95Seconds',
    'falseStationaryMaximumSeconds',
    'visibleGapCount',
    'inferredConnectorCount',
  ];
  for (final key in nonNegativeMetrics) {
    final value = metrics[key];
    if (value is num && value < 0) {
      errors.add('$label $key must not be negative.');
    }
  }
}

void _rejectSensitiveKeys(
  Object? value,
  Map<String, Object?> protocol,
  List<String> errors, [
  String path = r'$',
]) {
  final forbidden = _strings(protocol['forbiddenKeyFragments'])
      .map((value) => value.toLowerCase())
      .toList(growable: false);
  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key.toString();
      if (forbidden.any(key.toLowerCase().contains)) {
        errors.add('Forbidden sensitive key at $path.$key');
      }
      _rejectSensitiveKeys(entry.value, protocol, errors, '$path.$key');
    }
  } else if (value is List) {
    for (var index = 0; index < value.length; index += 1) {
      _rejectSensitiveKeys(value[index], protocol, errors, '$path[$index]');
    }
  }
}

void _requiredText(
  Map<String, Object?> values,
  String key,
  List<String> errors,
) {
  if (values[key] is! String || (values[key] as String).trim().isEmpty) {
    errors.add('$key is required.');
  }
}

Map<String, Object?> _map(Object? value) =>
    (value as Map).cast<String, Object?>();

List<Map<String, Object?>> _maps(Object? value) => value is List
    ? value
        .whereType<Map>()
        .map((value) => value.cast<String, Object?>())
        .toList()
    : const <Map<String, Object?>>[];

List<String> _strings(Object? value) =>
    value is List ? value.whereType<String>().toList() : const <String>[];
