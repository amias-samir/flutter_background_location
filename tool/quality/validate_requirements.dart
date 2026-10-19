import 'dart:convert';
import 'dart:io';

const _path = 'tool/quality/requirements.yaml';
const _errorCodePath = 'tool/quality/error_codes.yaml';
const _ignoredMaintainerDocsPrefix = 'plugin_documents/';

/// Work-package IDs such as `F0-01`, `E1-READY`, `ARQ-01-02A`, `LBO-00`, or
/// `FIX-26`: a phase prefix of two to four characters, then one or more
/// dash-separated segments.
final _workPackageIdPattern =
    RegExp(r'^[A-Z][A-Z0-9]{1,3}-[A-Z0-9]+(-[A-Z0-9]+)*$');

/// Compatibility values that must match the constants shipped in code.
///
/// Hosts and reviewers classify changes from the ledger, so a ledger value
/// that drifts from the implementation fails validation.
const _compatibilitySources = <String, List<_VersionSource>>{
  'native_protocol': [
    _VersionSource(
      'android/src/main/kotlin/com/samir/flutter_background_location/'
          'FlutterBackgroundLocationPlugin.kt',
      r'"version"\s+to\s+(\d+)',
    ),
    _VersionSource(
      'ios/flutter_background_location_tracker/Sources/'
          'flutter_background_location_tracker/'
          'FlutterBackgroundLocationPlugin.swift',
      r'"version":\s*(\d+)',
    ),
  ],
  'route_database_schema': [
    _VersionSource(
      'lib/src/storage/sqlite_track_repository.dart',
      r'^\s*version:\s*(\d+),\s*$',
    ),
  ],
  'android_journal_schema': [
    _VersionSource(
      'android/src/main/kotlin/com/samir/flutter_background_location/'
          'PendingLocationStore.kt',
      r'JOURNAL_SCHEMA_VERSION\s*=\s*(\d+)',
    ),
  ],
  'android_journal_payload_format': [
    _VersionSource(
      'android/src/main/kotlin/com/samir/flutter_background_location/'
          'JournalPayloadCodec.kt',
      r'PAYLOAD_FORMAT\s*=\s*(\d+)',
    ),
  ],
  'ios_journal_schema': [
    _VersionSource(
      'ios/flutter_background_location_tracker/Sources/'
          'flutter_background_location_tracker/NativeLocationJournal.swift',
      r'PRAGMA user_version = (\d+)',
    ),
  ],
  'preset_definition': [
    _VersionSource(
      'lib/src/domain/tracking_configuration_epoch.dart',
      r'\bpresetDefinition\s*=\s*(\d+);',
    ),
  ],
  'quality_policy': [
    _VersionSource(
      'lib/src/domain/tracking_configuration_epoch.dart',
      r'\bqualityPolicy\s*=\s*(\d+);',
    ),
  ],
  'continuity_policy': [
    _VersionSource(
      'lib/src/domain/tracking_configuration_epoch.dart',
      r'\bcontinuityPolicy\s*=\s*(\d+);',
    ),
  ],
  'motion_policy': [
    _VersionSource(
      'lib/src/domain/tracking_configuration_epoch.dart',
      r'\bmotionPolicy\s*=\s*(\d+);',
    ),
    _VersionSource(
      'android/src/main/kotlin/com/samir/flutter_background_location/'
          'StationaryPolicyV2.kt',
      r'MOTION_POLICY_VERSION\s*=\s*(\d+)',
    ),
    _VersionSource(
      'ios/flutter_background_location_tracker/Sources/'
          'flutter_background_location_tracker/StationaryPolicyV2.swift',
      r'static let motionPolicyVersion = (\d+)',
    ),
  ],
};

/// Package sources that raise error codes. Every literal code they raise must
/// be registered in [_errorCodePath], so hosts can rely on one stable list.
/// Native error envelopes are also checked for redaction.
const _errorCodeSources = <_ErrorCodeSource>[
  _ErrorCodeSource('lib/src', '.dart', _dartErrorCodes),
  _ErrorCodeSource(
    'android/src/main/kotlin',
    '.kt',
    _kotlinErrorCodes,
    _kotlinEnvelopeIssues,
  ),
  _ErrorCodeSource(
    'ios/flutter_background_location_tracker/Sources',
    '.swift',
    _swiftErrorCodes,
    _swiftEnvelopeIssues,
  ),
];

final _codeLiteral = RegExp(r'''["']([a-z][a-z0-9_]+)["']''');
final _namedCodeArgument = RegExp(r'^code\s*[:=]\s*([\s\S]*)$');
final _namedArgument = RegExp(r'^(\w+):\s*([\s\S]*)$');
final _packageCode = RegExp(r'^[\w.]+\.code$');
final _platformMessage = RegExp(
  r'\b(localizedMessage|localizedDescription)\b|\b\w+\.message\b',
);

void main() {
  final report = validateRequirements();
  if (report.errors.isNotEmpty) {
    for (final error in report.errors) {
      stderr.writeln(error);
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'Validated $_path with ${report.workPackageCount} work-package IDs, '
    '${report.compatibilityCount} compatibility versions, and '
    '${report.errorCodeCount} registered error codes.',
  );
}

/// Result of validating the quality ledger and error-code registry.
final class RequirementsReport {
  const RequirementsReport({
    required this.errors,
    required this.workPackageCount,
    required this.compatibilityCount,
    required this.errorCodeCount,
  });

  final List<String> errors;
  final int workPackageCount;
  final int compatibilityCount;
  final int errorCodeCount;
}

/// Validates the ledger, its compatibility versions against shipped code, and
/// the error-code registry against every literal code the package raises.
///
/// [root] is the repository root; tests point it at a temporary tree.
RequirementsReport validateRequirements({String root = '.'}) {
  final file = File('$root/$_path');
  if (!file.existsSync()) {
    return const RequirementsReport(
      errors: ['Missing $_path'],
      workPackageCount: 0,
      compatibilityCount: 0,
      errorCodeCount: 0,
    );
  }

  final lines = file.readAsLinesSync();
  final errors = <String>[];
  final ids = _validateWorkPackageIds(lines, errors);
  _validateEvidencePaths(lines, errors);
  final compatibility = _validateSections(lines, errors);
  _validateCompatibilityAgainstCode(root, compatibility, errors);
  _validateReleaseMetadata(root, errors);
  _validatePrivacyManifest(root, errors);
  _validateConfigKeyCoverage(root, errors);
  final codeCount = _validateErrorCodes(root, errors);
  return RequirementsReport(
    errors: errors,
    workPackageCount: ids.length,
    compatibilityCount: compatibility.length,
    errorCodeCount: codeCount,
  );
}

Set<String> _validateWorkPackageIds(List<String> lines, List<String> errors) {
  final ids = <String>{};
  final duplicates = <String>{};
  final idLine = RegExp(r'^\s*-\s+id:\s+(\S+)\s*$');
  for (final line in lines) {
    final match = idLine.firstMatch(line);
    if (match == null) continue;
    final id = match.group(1)!;
    if (!_workPackageIdPattern.hasMatch(id)) {
      errors.add('Malformed work-package ID: $id.');
      continue;
    }
    if (!ids.add(id)) duplicates.add(id);
  }
  if (ids.isEmpty) {
    errors.add('No work-package IDs found.');
  }
  if (duplicates.isNotEmpty) {
    errors.add('Duplicate work-package IDs: ${duplicates.join(', ')}.');
  }
  return ids;
}

void _validateEvidencePaths(List<String> lines, List<String> errors) {
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.startsWith('- $_ignoredMaintainerDocsPrefix')) {
      errors.add(
        'Evidence must be available in a clean checkout; replace ignored '
        '${trimmed.substring(2)} with a tracked package artifact.',
      );
    }
  }
}

Map<String, String> _validateSections(
  List<String> lines,
  List<String> errors,
) {
  final compatibility = <String, String>{};
  var hasChangeClassifications = false;
  var inCompatibility = false;
  final entry = RegExp(r'^\s{2}([a-z_]+):\s*(\S.*?)\s*$');
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed == 'compatibility:') {
      inCompatibility = true;
      continue;
    }
    if (trimmed == 'change_classifications:') {
      hasChangeClassifications = true;
    }
    if (inCompatibility) {
      final match = entry.firstMatch(line);
      if (match != null) {
        compatibility[match.group(1)!] = match.group(2)!;
        continue;
      }
      if (line.isNotEmpty && !line.startsWith(' ')) inCompatibility = false;
    }
  }
  if (compatibility.isEmpty) {
    errors.add('Missing compatibility section.');
  }
  if (!hasChangeClassifications) {
    errors.add('Missing change_classifications section.');
  }
  return compatibility;
}

void _validateCompatibilityAgainstCode(
  String root,
  Map<String, String> compatibility,
  List<String> errors,
) {
  for (final MapEntry(key: key, value: sources)
      in _compatibilitySources.entries) {
    final raw = compatibility[key];
    if (raw == null) {
      errors.add('Compatibility section is missing `$key`.');
      continue;
    }
    final declared = int.tryParse(raw);
    if (declared == null) {
      errors.add('Compatibility `$key` must be an integer, found `$raw`.');
      continue;
    }
    for (final source in sources) {
      final actual = source.read(root);
      if (actual == null) {
        errors.add(
          'Could not read `$key` from ${source.path}; update the validator '
          'pattern when the constant moves.',
        );
      } else if (actual != declared) {
        errors.add(
          'Compatibility `$key` is $declared in $_path but $actual in '
          '${source.path}.',
        );
      }
    }
  }
}

const _privacyManifestPath = 'ios/flutter_background_location_tracker/'
    'Sources/flutter_background_location_tracker/PrivacyInfo.xcprivacy';

/// Apple required-reason API categories and the Swift symbols that need them.
/// Package Swift that uses a symbol must declare its category in the privacy
/// manifest bundled by both iOS packagings.
final _requiredReasonApis = <String, RegExp>{
  'NSPrivacyAccessedAPICategorySystemBootTime':
      RegExp(r'\b(systemUptime|mach_absolute_time)\b'),
  'NSPrivacyAccessedAPICategoryUserDefaults':
      RegExp(r'\b(UserDefaults|NSUserDefaults)\b'),
  'NSPrivacyAccessedAPICategoryFileTimestamp': RegExp(
    r'\b(creationDate|modificationDate|fileModificationDate|'
    r'contentModificationDateKey|creationDateKey|getattrlist|getattrlistbulk|'
    r'fgetattrlist)\b|\b(stat|fstat|fstatat|lstat)\s*\(',
  ),
  'NSPrivacyAccessedAPICategoryDiskSpace': RegExp(
    r'\b(volumeAvailableCapacity\w*Key|volumeTotalCapacityKey|systemFreeSize|'
    r'systemSize)\b|\b(statfs|statvfs|fstatfs|fstatvfs)\s*\(',
  ),
  'NSPrivacyAccessedAPICategoryActiveKeyboards':
      RegExp(r'\bactiveInputModes\b'),
};

/// Every required-reason API used by package Swift is declared in the
/// privacy manifest.
void _validatePrivacyManifest(String root, List<String> errors) {
  final used = <String, Set<String>>{};
  final swift = _ErrorCodeSource(
    'ios/flutter_background_location_tracker/Sources',
    '.swift',
    _noCodes,
  );
  for (final (path, source) in swift._sources(root)) {
    for (final MapEntry(key: category, value: pattern)
        in _requiredReasonApis.entries) {
      if (pattern.hasMatch(source)) {
        used.putIfAbsent(category, () => <String>{}).add(path);
      }
    }
  }
  if (used.isEmpty) return;
  final manifest = File('$root/$_privacyManifestPath');
  final declared = manifest.existsSync() ? manifest.readAsStringSync() : '';
  for (final MapEntry(key: category, value: paths) in used.entries) {
    if (!declared.contains('<string>$category</string>')) {
      errors.add(
        '${paths.join(', ')} use required-reason API category $category, '
        'which $_privacyManifestPath does not declare.',
      );
    }
  }
}

Iterable<String> _noCodes(String source) => const <String>[];

const _configKeyCoveragePath = 'test/fixtures/config_key_coverage_v2.json';
const _nativeConfigurationSources = <String, String>{
  'android': 'android/src/main/kotlin/com/samir/flutter_background_location/'
      'TrackingConfiguration.kt',
  'ios': 'ios/flutter_background_location_tracker/Sources/'
      'flutter_background_location_tracker/TrackingConfiguration.swift',
};

/// Each native configuration parser reads exactly the keys the coverage
/// contract marks `parsed`, plus its documented native-only keys.
void _validateConfigKeyCoverage(String root, List<String> errors) {
  final file = File('$root/$_configKeyCoveragePath');
  if (!file.existsSync()) return;
  final contract =
      (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
  final keys = (contract['keys']! as Map).cast<String, Object?>();
  final nativeOnly =
      (contract['nativeOnlyKeys'] as Map? ?? const <String, Object?>{})
          .cast<String, Object?>();
  for (final MapEntry(key: platform, value: relativePath)
      in _nativeConfigurationSources.entries) {
    final source = File('$root/$relativePath');
    if (!source.existsSync()) continue;
    final code = _withoutComments(source.readAsStringSync());
    bool reads(String key) => code.contains('"$key"');
    for (final MapEntry(key: key, value: raw) in keys.entries) {
      final coverage = (raw! as Map)[platform];
      if (coverage == 'parsed' && !reads(key)) {
        errors.add(
          '$relativePath does not read `$key`, which '
          '$_configKeyCoveragePath marks parsed on $platform.',
        );
      } else if (coverage == 'ignored' && reads(key)) {
        errors.add(
          '$relativePath reads `$key`; mark it parsed for $platform in '
          '$_configKeyCoveragePath.',
        );
      }
    }
    final platformOnly =
        (nativeOnly[platform] as Map? ?? const <String, Object?>{}).keys;
    for (final key in platformOnly) {
      if (!reads(key.toString())) {
        errors.add(
          '$relativePath no longer reads native-only key `$key`; remove it '
          'from $_configKeyCoveragePath.',
        );
      }
    }
  }
}

const _podspecPath = 'ios/flutter_background_location_tracker.podspec';
const _swiftPackagePath =
    'ios/flutter_background_location_tracker/Package.swift';

/// The pubspec, podspec, Swift package, and README install snippet describe
/// one release, so their names, versions, and iOS floors must agree.
void _validateReleaseMetadata(String root, List<String> errors) {
  final pubspec = File('$root/pubspec.yaml');
  if (!pubspec.existsSync()) return;
  final pubspecText = pubspec.readAsStringSync();
  final name = _firstGroup(r'^name:\s*(\S+)\s*$', pubspecText);
  final version = _firstGroup(r'^version:\s*(\S+)\s*$', pubspecText);
  if (name == null || version == null) {
    errors.add('pubspec.yaml must declare a name and version.');
    return;
  }

  final podspec = _readOrReport(root, _podspecPath, errors);
  final package = _readOrReport(root, _swiftPackagePath, errors);
  if (podspec != null) {
    final podName = _firstGroup(r"s\.name\s*=\s*'([^']+)'", podspec);
    final podVersion = _firstGroup(r"s\.version\s*=\s*'([^']+)'", podspec);
    if (podName != name) {
      errors.add('$_podspecPath name `$podName` does not match `$name`.');
    }
    if (podVersion != version) {
      errors.add(
        '$_podspecPath version `$podVersion` does not match pubspec '
        '`$version`.',
      );
    }
    if (!podspec.contains('PrivacyInfo.xcprivacy')) {
      errors.add('$_podspecPath must bundle PrivacyInfo.xcprivacy.');
    }
  }
  if (package != null) {
    final packageName = _firstGroup(r'name:\s*"([^"]+)"', package);
    if (packageName != name) {
      errors.add(
        '$_swiftPackagePath name `$packageName` does not match `$name`.',
      );
    }
    if (!package.contains('PrivacyInfo.xcprivacy')) {
      errors.add('$_swiftPackagePath must process PrivacyInfo.xcprivacy.');
    }
  }
  if (podspec != null && package != null) {
    final podIos = _firstGroup(r"s\.platform\s*=\s*:ios,\s*'([^']+)'", podspec);
    final packageIos = _firstGroup(r'\.iOS\("([^"]+)"\)', package);
    if (podIos == null || podIos != packageIos) {
      errors.add(
        'Minimum iOS differs: podspec `$podIos`, Package.swift '
        '`$packageIos`.',
      );
    }
  }

  final readme = File('$root/README.md');
  if (!readme.existsSync()) return;
  final pinned = _firstGroup(
    '^\\s*${RegExp.escape(name)}:\\s*\\^(\\S+)\\s*\$',
    readme.readAsStringSync(),
  );
  if (pinned == null) {
    errors.add('README.md must show the `$name: ^<version>` dependency.');
  } else if (!_sameMajorAndNotAhead(pinned, version)) {
    errors.add(
      'README.md installs `^$pinned`, which must share the major version of '
      'pubspec `$version` and not exceed it.',
    );
  }
}

String? _readOrReport(String root, String relativePath, List<String> errors) {
  final file = File('$root/$relativePath');
  if (file.existsSync()) return file.readAsStringSync();
  errors.add('Missing $relativePath');
  return null;
}

String? _firstGroup(String pattern, String source) =>
    RegExp(pattern, multiLine: true).firstMatch(source)?.group(1);

bool _sameMajorAndNotAhead(String pinned, String version) {
  List<int>? parts(String value) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(value);
    return match == null
        ? null
        : [for (var group = 1; group <= 3; group++) int.parse(match[group]!)];
  }

  final left = parts(pinned);
  final right = parts(version);
  if (left == null || right == null || left.first != right.first) {
    return false;
  }
  for (var index = 0; index < 3; index++) {
    if (left[index] != right[index]) return left[index] < right[index];
  }
  return true;
}

int _validateErrorCodes(String root, List<String> errors) {
  final errorCodeFile = File('$root/$_errorCodePath');
  if (!errorCodeFile.existsSync()) {
    errors.add('Missing $_errorCodePath');
    return 0;
  }
  final codePattern = RegExp(r'^\s*-\s+code:\s+([a-z][a-z0-9_]+)\s*$');
  final codes = <String>{};
  final duplicateCodes = <String>{};
  for (final line in errorCodeFile.readAsLinesSync()) {
    final match = codePattern.firstMatch(line);
    if (match == null) continue;
    final code = match.group(1)!;
    if (!codes.add(code)) duplicateCodes.add(code);
  }
  if (codes.isEmpty) {
    errors.add('No stable error codes found in $_errorCodePath.');
  }
  if (duplicateCodes.isNotEmpty) {
    errors.add('Duplicate error codes: ${duplicateCodes.join(', ')}.');
  }

  final unregistered = <String, Set<String>>{};
  for (final source in _errorCodeSources) {
    for (final MapEntry(key: code, value: path) in source.scan(root)) {
      if (codes.contains(code)) continue;
      unregistered.putIfAbsent(code, () => <String>{}).add(path);
    }
  }
  for (final MapEntry(key: code, value: paths) in unregistered.entries) {
    errors.add(
      'Error code `$code` is raised in ${paths.join(', ')} but missing from '
      '$_errorCodePath.',
    );
  }
  for (final source in _errorCodeSources) {
    errors.addAll(source.envelopeIssues(root));
  }
  return codes.length;
}

/// `Tracking*Exception(..., code: 'literal', ...)`.
Iterable<String> _dartErrorCodes(String source) sync* {
  for (final call in RegExp(r'\bTracking\w*Exception\(').allMatches(source)) {
    for (final argument in _callArguments(source, call.end - 1)) {
      final named = _namedCodeArgument.firstMatch(argument);
      if (named != null) yield* _literals(named.group(1)!);
    }
  }
}

/// `result.error("literal", ...)`, `events.error(...)`,
/// `Rejection("literal", ...)` and `exportError(result, "literal", ...)`,
/// including conditional code expressions.
Iterable<String> _kotlinErrorCodes(String source) sync* {
  final calls = RegExp(r'\b(error|Rejection|exportError)\(');
  for (final call in calls.allMatches(source)) {
    final arguments = _callArguments(source, call.end - 1);
    final named = arguments.map(_namedCodeArgument.firstMatch).nonNulls;
    final position = call.group(1) == 'exportError' ? 1 : 0;
    final expression = named.isNotEmpty
        ? named.first.group(1)!
        : arguments.length > position
            ? arguments[position]
            : '';
    yield* _literals(expression);
  }
}

/// `FlutterError(code: "literal", ...)`, `Rejection(code: "literal", ...)` and
/// enum-backed `var code: String { ... return "literal" ... }` mappings.
Iterable<String> _swiftErrorCodes(String source) sync* {
  final calls = RegExp(r'\b(FlutterError|Rejection)\(');
  for (final call in calls.allMatches(source)) {
    for (final argument in _callArguments(source, call.end - 1)) {
      final named = _namedCodeArgument.firstMatch(argument);
      if (named != null) yield* _literals(named.group(1)!);
    }
  }
  final mappings = RegExp(r'\bvar code: String \{');
  for (final mapping in mappings.allMatches(source)) {
    final body = source.substring(
      mapping.end,
      _closingBracket(source, mapping.end - 1),
    );
    for (final match
        in RegExp(r'\breturn\s+"([a-z][a-z0-9_]+)"').allMatches(body)) {
      yield match.group(1)!;
    }
  }
}

/// Native error envelopes reach hosts as exception messages and causes. They
/// may echo a message only for package-coded errors (`error.code`), because
/// platform messages can carry paths, URIs, or payload fragments, and they
/// must never carry the full status map, which holds coordinates and track
/// identity.
Iterable<(int, String)> _kotlinEnvelopeIssues(String source) sync* {
  for (final call in RegExp(r'\.error\(').allMatches(source)) {
    final arguments = _callArguments(source, call.end - 1);
    if (arguments.length < 2) continue;
    if (!_packageCode.hasMatch(arguments[0]) &&
        _platformMessage.hasMatch(arguments[1])) {
      yield (call.start, 'error envelope echoes a platform exception message');
    }
    if (arguments.length > 2 && arguments[2].contains('statusMap()')) {
      yield (call.start, 'error envelope details expose the full status map');
    }
  }
}

/// Swift counterpart of [_kotlinEnvelopeIssues] for `FlutterError(...)`.
Iterable<(int, String)> _swiftEnvelopeIssues(String source) sync* {
  for (final call in RegExp(r'\bFlutterError\(').allMatches(source)) {
    final named = <String, String>{
      for (final argument in _callArguments(source, call.end - 1))
        if (_namedArgument.firstMatch(argument) case final match?)
          match.group(1)!: match.group(2)!,
    };
    if (!_packageCode.hasMatch(named['code'] ?? '') &&
        _platformMessage.hasMatch(named['message'] ?? '')) {
      yield (call.start, 'error envelope echoes a platform error description');
    }
    if ((named['details'] ?? '').contains('stateMap()')) {
      yield (call.start, 'error envelope details expose the full state map');
    }
  }
}

Iterable<String> _literals(String expression) =>
    _codeLiteral.allMatches(expression).map((match) => match.group(1)!);

/// Top-level, comma-separated arguments of the call whose opening
/// parenthesis is at [open].
List<String> _callArguments(String source, int open) {
  final close = _closingBracket(source, open);
  final arguments = <String>[];
  var start = open + 1;
  _scanCode(source, open, close, (index, depth) {
    if (depth == 1 && source[index] == ',') {
      arguments.add(source.substring(start, index).trim());
      start = index + 1;
    }
    return false;
  });
  arguments.add(source.substring(start, close).trim());
  return arguments..removeWhere((argument) => argument.isEmpty);
}

/// Index of the bracket that closes the one at [open], or the source length.
int _closingBracket(String source, int open) {
  var close = source.length;
  _scanCode(source, open, source.length, (index, depth) {
    if (depth == 0) {
      close = index;
      return true;
    }
    return false;
  });
  return close;
}

/// Walks code characters from [from] to [to], skipping string literals, and
/// reports each one with the bracket depth after it. Stops when [visit]
/// returns true. Comments are already blanked by [_withoutComments].
void _scanCode(
  String source,
  int from,
  int to,
  bool Function(int index, int depth) visit,
) {
  var depth = 0;
  String? quote;
  for (var index = from; index < to; index++) {
    final char = source[index];
    if (quote != null) {
      if (char == r'\') {
        index++;
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    switch (char) {
      case '"' || "'":
        quote = char;
        continue;
      case '(' || '[' || '{':
        depth++;
      case ')' || ']' || '}':
        depth--;
    }
    if (visit(index, depth)) return;
  }
}

/// Replaces comments with spaces so commented-out calls and Dartdoc examples
/// never count as raised codes. String literals are kept intact.
String _withoutComments(String source) {
  final buffer = StringBuffer();
  String? quote;
  for (var index = 0; index < source.length; index++) {
    final char = source[index];
    if (quote != null) {
      buffer.write(char);
      if (char == r'\' && index + 1 < source.length) {
        buffer.write(source[++index]);
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
    } else if (char == '/' && index + 1 < source.length) {
      final next = source[index + 1];
      if (next == '/' || next == '*') {
        final end = next == '/'
            ? source.indexOf('\n', index)
            : source.indexOf('*/', index + 2);
        final stop = end < 0
            ? source.length
            : next == '/'
                ? end
                : end + 2;
        buffer.write(' ' * (stop - index));
        index = stop - 1;
        continue;
      }
    }
    buffer.write(char);
  }
  return buffer.toString();
}

final class _VersionSource {
  const _VersionSource(this.path, this.pattern);

  final String path;
  final String pattern;

  int? read(String root) {
    final file = File('$root/$path');
    if (!file.existsSync()) return null;
    final match =
        RegExp(pattern, multiLine: true).firstMatch(file.readAsStringSync());
    return match == null ? null : int.tryParse(match.group(1)!);
  }
}

final class _ErrorCodeSource {
  const _ErrorCodeSource(
    this.root,
    this.extension,
    this.codes, [
    this.envelopeChecks,
  ]);

  final String root;
  final String extension;
  final Iterable<String> Function(String source) codes;
  final Iterable<(int, String)> Function(String source)? envelopeChecks;

  Iterable<MapEntry<String, String>> scan(String repositoryRoot) sync* {
    for (final (path, source) in _sources(repositoryRoot)) {
      for (final code in codes(source)) {
        yield MapEntry(code, path);
      }
    }
  }

  Iterable<String> envelopeIssues(String repositoryRoot) sync* {
    final checks = envelopeChecks;
    if (checks == null) return;
    for (final (path, source) in _sources(repositoryRoot)) {
      for (final (offset, issue) in checks(source)) {
        final line = '\n'.allMatches(source.substring(0, offset)).length + 1;
        yield '$path:$line: $issue.';
      }
    }
  }

  /// Repository-relative paths and comment-free contents, in path order.
  Iterable<(String, String)> _sources(String repositoryRoot) sync* {
    final directory = Directory('$repositoryRoot/$root');
    if (!directory.existsSync()) return;
    final files = directory
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith(extension))
        .toList()
      ..sort((left, right) => left.path.compareTo(right.path));
    for (final file in files) {
      yield (
        file.path.substring(repositoryRoot.length + 1),
        _withoutComments(file.readAsStringSync()),
      );
    }
  }
}
