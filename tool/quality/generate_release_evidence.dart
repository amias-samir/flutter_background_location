import 'dart:convert';
import 'dart:io';

const _requirementsPath = 'tool/quality/requirements.yaml';
const _defaultOutputPath = 'build/quality/release_evidence.json';

void main(List<String> arguments) {
  final outputPath = _readOutputPath(arguments);
  final requirements = File(_requirementsPath);
  if (!requirements.existsSync()) {
    stderr.writeln('Missing $_requirementsPath');
    exitCode = 1;
    return;
  }

  final parsed = _parseRequirements(requirements.readAsLinesSync());
  final missingEvidence = <String>[];
  for (final workPackage in parsed.workPackages) {
    if (workPackage.evidence.isEmpty &&
        workPackage.evidenceMode != 'physical_manual') {
      missingEvidence.add(
        '${workPackage.id}: no automated evidence or explicit '
        'physical_manual gate',
      );
    }
    for (final evidence in workPackage.evidence) {
      if (!FileSystemEntity.isFileSync(evidence) &&
          !FileSystemEntity.isDirectorySync(evidence)) {
        missingEvidence.add('${workPackage.id}: $evidence');
      }
    }
  }
  if (missingEvidence.isNotEmpty) {
    for (final missing in missingEvidence) {
      stderr.writeln('Missing evidence: $missing');
    }
    exitCode = 1;
    return;
  }

  final packageVersion = _firstValue('pubspec.yaml', 'version') ?? 'unknown';
  final commit = _environmentValue('GITHUB_SHA') ?? _gitCommit();
  final generatedAt = DateTime.now().toUtc().toIso8601String();
  final manifest = <String, Object?>{
    'schemaVersion': 1,
    'generatedAt': generatedAt,
    'candidate': <String, Object?>{
      'package': 'flutter_background_location_tracker',
      'packageVersion': packageVersion,
      'commit': commit,
      'compatibility': parsed.compatibility,
    },
    'toolchains': <String, Object?>{
      'flutter': _environmentValue('FLUTTER_VERSION') ?? 'record-in-ci',
      'dart': Platform.version,
      'java': _environmentValue('JAVA_VERSION') ?? 'record-in-ci',
      'agp': 'declared-in-example-build',
      'gradle': 'declared-in-example-wrapper',
      'kotlin': 'declared-in-plugin-build',
      'xcode': _environmentValue('XCODE_VERSION') ?? 'record-on-macos-ci',
      'swift': _environmentValue('SWIFT_VERSION') ?? 'record-on-macos-ci',
    },
    'automatedEvidence': parsed.workPackages
        .where((workPackage) => workPackage.evidence.isNotEmpty)
        .map((workPackage) => workPackage.toJson())
        .toList(growable: false),
    'manualOrPhysicalGates': parsed.workPackages
        .where((workPackage) => workPackage.evidenceMode == 'physical_manual')
        .map((workPackage) => <String, Object?>{
              ...workPackage.toJson(),
              'status': 'required_before_promotion',
            })
        .toList(growable: false),
    'privacy': <String, Object?>{
      'containsCoordinates': false,
      'containsRawParticipantIdentifiers': false,
      'containsSecrets': false,
      'cocoaPodsManifestInspection': 'record-before-promotion',
      'swiftPackageManifestInspection': 'record-before-promotion',
      'appStorePrivacyApproval': 'record-before-promotion',
      'googlePlayDataSafetyApproval': 'record-before-promotion',
    },
    'releaseDecision': <String, Object?>{
      'status': 'candidate_only',
      'knownDeviations': <Object?>[],
      'acceptedRiskOwner': null,
      'acceptedRiskExpiry': null,
      'promotionApprovedBy': null,
      'rollbackReference': null,
    },
  };

  final output = File(outputPath);
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(manifest)}\n',
    flush: true,
  );
  stdout.writeln(
    'Wrote coordinate-free release evidence to $outputPath '
    '(${parsed.workPackages.length} work packages).',
  );
}

String _readOutputPath(List<String> arguments) {
  for (var index = 0; index < arguments.length; index += 1) {
    if (arguments[index] == '--output' && index + 1 < arguments.length) {
      return arguments[index + 1];
    }
  }
  return _defaultOutputPath;
}

String? _environmentValue(String name) {
  final value = Platform.environment[name]?.trim();
  return value == null || value.isEmpty ? null : value;
}

String _gitCommit() {
  final result = Process.runSync('git', const <String>['rev-parse', 'HEAD']);
  if (result.exitCode != 0) return 'unknown';
  final value = '${result.stdout}'.trim();
  return value.isEmpty ? 'unknown' : value;
}

String? _firstValue(String path, String key) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final pattern = RegExp('^${RegExp.escape(key)}:\\s*(.+)\\s*\$');
  for (final line in file.readAsLinesSync()) {
    final match = pattern.firstMatch(line);
    if (match != null) return match.group(1)?.trim();
  }
  return null;
}

_ParsedRequirements _parseRequirements(List<String> lines) {
  final compatibility = <String, Object?>{};
  final workPackages = <_WorkPackage>[];
  _WorkPackageBuilder? current;
  var inCompatibility = false;
  var inEvidence = false;

  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed == 'compatibility:') {
      inCompatibility = true;
      continue;
    }
    if (trimmed == 'change_classifications:' || trimmed == 'work_packages:') {
      inCompatibility = false;
    }
    if (inCompatibility) {
      final match = RegExp(r'^([a-z_]+):\s*(.+)$').firstMatch(trimmed);
      if (match != null) {
        final raw = match.group(2)!;
        compatibility[match.group(1)!] = int.tryParse(raw) ?? raw;
      }
      continue;
    }

    final idMatch = RegExp(r'^- id:\s*(.+)$').firstMatch(trimmed);
    if (idMatch != null) {
      if (current != null) workPackages.add(current.build());
      current = _WorkPackageBuilder(idMatch.group(1)!);
      inEvidence = false;
      continue;
    }
    if (current == null) continue;
    if (trimmed.startsWith('title:')) {
      current.title = trimmed.substring('title:'.length).trim();
      continue;
    }
    if (trimmed.startsWith('release_gate:')) {
      current.releaseGate = trimmed.substring('release_gate:'.length).trim();
      continue;
    }
    if (trimmed.startsWith('evidence_mode:')) {
      current.evidenceMode = trimmed.substring('evidence_mode:'.length).trim();
      continue;
    }
    if (trimmed == 'evidence: []') {
      inEvidence = false;
      continue;
    }
    if (trimmed == 'evidence:') {
      inEvidence = true;
      continue;
    }
    if (inEvidence && trimmed.startsWith('- ')) {
      current.evidence.add(trimmed.substring(2).trim());
    }
  }
  if (current != null) workPackages.add(current.build());
  return _ParsedRequirements(compatibility, workPackages);
}

final class _ParsedRequirements {
  const _ParsedRequirements(this.compatibility, this.workPackages);

  final Map<String, Object?> compatibility;
  final List<_WorkPackage> workPackages;
}

final class _WorkPackageBuilder {
  _WorkPackageBuilder(this.id);

  final String id;
  String title = '';
  String releaseGate = '';
  String evidenceMode = 'automated';
  final List<String> evidence = <String>[];

  _WorkPackage build() => _WorkPackage(
        id: id,
        title: title,
        releaseGate: releaseGate,
        evidenceMode: evidenceMode,
        evidence: List<String>.unmodifiable(evidence),
      );
}

final class _WorkPackage {
  const _WorkPackage({
    required this.id,
    required this.title,
    required this.releaseGate,
    required this.evidenceMode,
    required this.evidence,
  });

  final String id;
  final String title;
  final String releaseGate;
  final String evidenceMode;
  final List<String> evidence;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        'releaseGate': releaseGate,
        'evidenceMode': evidenceMode,
        'evidence': evidence,
      };
}
