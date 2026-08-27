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
  final errors = <String>[];
  _rejectSensitiveKeys(evidence, protocol, errors);
  _requiredText(evidence, 'candidateCommit', errors);
  _requiredText(evidence, 'toolchainId', errors);
  _requiredText(evidence, 'approvedBaselineCommit', errors);

  final routeRuns = _maps(evidence['routeBenchmarks']);
  final minimumRuns = protocol['minimumComparableRouteRuns'] as int;
  final requiredMetrics = _strings(protocol['requiredMetricKeys']);
  for (final platform in _strings(protocol['platforms'])) {
    for (final preset in _strings(protocol['presets'])) {
      for (final scenario in _strings(protocol['routeScenarios'])) {
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
          if ((run['repetitions'] as num?)?.toInt() case final count?
              when count < minimumRuns) {
            errors.add('$platform/$preset/$scenario has fewer than '
                '$minimumRuns repetitions.');
          }
          final metrics = run['metrics'] is Map
              ? _map(run['metrics'])
              : const <String, Object?>{};
          for (final key in requiredMetrics) {
            final value = metrics[key];
            if (value is! num || !value.isFinite) {
              errors.add('$platform/$preset/$scenario missing metric $key.');
            }
          }
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
  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln('Qualification failure: $error');
    }
    exitCode = 1;
    return;
  }
  stdout.writeln('Physical qualification evidence satisfies protocol v1.');
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
