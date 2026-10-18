import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/quality/validate_requirements.dart' as ledger;

void main() {
  test('the checked-in ledger matches the shipped code', () {
    final report = ledger.validateRequirements();

    expect(report.errors, isEmpty);
    expect(report.workPackageCount, greaterThan(52));
    expect(report.compatibilityCount, greaterThanOrEqualTo(8));
    expect(report.errorCodeCount, greaterThan(100));
  });

  group('drift detection', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('fbl_ledger_');
      _writeConsistentTree(root);
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('accepts a consistent tree', () {
      expect(ledger.validateRequirements(root: root.path).errors, isEmpty);
    });

    test('accepts multi-segment and four-letter work-package IDs', () {
      _replace(
        root,
        _requirements,
        '  - id: F0-01',
        '  - id: F0-01\n  - id: ARQ-01-02A\n  - id: LBO-00\n  - id: FIX-26',
      );

      final report = ledger.validateRequirements(root: root.path);

      expect(report.errors, isEmpty);
      expect(report.workPackageCount, 4);
    });

    test('rejects malformed and duplicate work-package IDs', () {
      _replace(
        root,
        _requirements,
        '  - id: F0-01',
        '  - id: F0-01\n  - id: lbo-1\n  - id: F0-01',
      );

      final errors = ledger.validateRequirements(root: root.path).errors;

      expect(errors, contains('Malformed work-package ID: lbo-1.'));
      expect(errors, contains('Duplicate work-package IDs: F0-01.'));
    });

    test('rejects compatibility versions that drift from code', () {
      _replace(
        root,
        _requirements,
        'route_database_schema: 14',
        'route_database_schema: 13',
      );
      _replace(
        root,
        _swiftPlugin,
        '"version": 2',
        '"version": 3',
      );

      final errors = ledger.validateRequirements(root: root.path).errors;

      expect(
        errors,
        contains(contains('`route_database_schema` is 13 in')),
      );
      expect(
        errors,
        contains(
          allOf(contains('`native_protocol` is 2'), contains('but 3 in')),
        ),
      );
    });

    test('requires every cross-checked compatibility key', () {
      _replace(root, _requirements, '  quality_policy: 1\n', '');

      expect(
        ledger.validateRequirements(root: root.path).errors,
        contains('Compatibility section is missing `quality_policy`.'),
      );
    });

    test('reports unregistered codes from every platform', () {
      _write(root, 'lib/src/sample.dart', '''
void fail() {
  throw TrackingStorageException(
    message: 'Named arguments may come in any order.',
    code: 'dart_unregistered_code',
  );
}
''');
      _write(root, 'android/src/main/kotlin/Sample.kt', '''
fun fail(result: Result, error: Exception) {
    result.error(
        if (error is IllegalStateException) {
            "kotlin_conditional_code"
        } else {
            "registered_code"
        },
        "Fixed message.",
        null,
    )
    exportError(result, "kotlin_export_code", "Fixed message.")
    // result.error("commented_out_code", "Never raised.", null)
}
''');
      _write(
          root, 'ios/flutter_background_location_tracker/Sources/S.swift', '''
enum SampleError: Error {
  case first

  var code: String {
    switch self {
    case .first: return "swift_enum_code"
    }
  }
}

func fail(result: FlutterResult) {
  result(FlutterError(code: "swift_flutter_code", message: nil, details: nil))
}
''');

      final errors = ledger.validateRequirements(root: root.path).errors;
      final reported = {
        for (final error in errors)
          if (RegExp(r'^Error code `(\w+)`').firstMatch(error)
              case final match?)
            match.group(1)!,
      };

      expect(reported, {
        'dart_unregistered_code',
        'kotlin_conditional_code',
        'kotlin_export_code',
        'swift_enum_code',
        'swift_flutter_code',
      });
    });

    test('rejects evidence that lives in ignored maintainer documents', () {
      _replace(
        root,
        _requirements,
        '    evidence: []',
        '    evidence:\n      - plugin_documents/ARCHITECTURE.md',
      );

      expect(
        ledger.validateRequirements(root: root.path).errors,
        contains(contains('plugin_documents/ARCHITECTURE.md')),
      );
    });

    test('rejects native error envelopes that leak state or platform text', () {
      _write(root, 'android/src/main/kotlin/Envelope.kt', '''
fun fail(result: Result, error: Exception) {
    result.error("registered_code", error.localizedMessage, null)
    result.error("registered_code", "Fixed message.", stateStore.statusMap())
    result.error(error.code, error.message, redactedCommandState())
    result.error("registered_code", "Fixed message.", redactedCommandState())
}
''');
      _write(
          root, 'ios/flutter_background_location_tracker/Sources/E.swift', '''
func fail(result: FlutterResult, error: Error) {
  result(FlutterError(code: "registered_code", message: error.localizedDescription, details: nil))
  result(FlutterError(code: error.code, message: error.localizedDescription, details: service.stateMap()))
  result(FlutterError(code: "registered_code", message: "Fixed.", details: redactedCommandState()))
}
''');

      final errors = ledger.validateRequirements(root: root.path).errors;

      expect(errors, [
        'android/src/main/kotlin/Envelope.kt:2: error envelope echoes a '
            'platform exception message.',
        'android/src/main/kotlin/Envelope.kt:3: error envelope details '
            'expose the full status map.',
        'ios/flutter_background_location_tracker/Sources/E.swift:2: error '
            'envelope echoes a platform error description.',
        'ios/flutter_background_location_tracker/Sources/E.swift:3: error '
            'envelope details expose the full state map.',
      ]);
    });

    test('requires a privacy declaration for every required-reason API', () {
      _write(
          root, 'ios/flutter_background_location_tracker/Sources/T.swift', '''
// UserDefaults in a comment is not a use.
let receivedNanos = ProcessInfo.processInfo.systemUptime * 1_000_000_000
let defaults = UserDefaults.standard
''');
      const manifest = 'ios/flutter_background_location_tracker/Sources/'
          'flutter_background_location_tracker/PrivacyInfo.xcprivacy';
      _write(root, manifest, '''
<array>
  <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
</array>
''');

      expect(ledger.validateRequirements(root: root.path).errors, [
        'ios/flutter_background_location_tracker/Sources/T.swift use '
            'required-reason API category '
            'NSPrivacyAccessedAPICategorySystemBootTime, which $manifest '
            'does not declare.',
      ]);

      _replace(
        root,
        manifest,
        '</array>',
        '  <string>NSPrivacyAccessedAPICategorySystemBootTime</string>\n'
            '</array>',
      );
      expect(ledger.validateRequirements(root: root.path).errors, isEmpty);
    });

    test('keeps native config parsers in step with the coverage contract', () {
      const kotlin = 'android/src/main/kotlin/com/samir/'
          'flutter_background_location/TrackingConfiguration.kt';
      const swift = 'ios/flutter_background_location_tracker/Sources/'
          'flutter_background_location_tracker/TrackingConfiguration.swift';
      _write(root, 'test/fixtures/config_key_coverage_v1.json', '''
{
  "keys": {
    "shared": {"android": "parsed", "ios": "parsed"},
    "androidOnly": {"android": "parsed", "ios": "ignored", "reason": "r"},
    "dartOnly": {"android": "ignored", "ios": "ignored", "reason": "r"}
  },
  "nativeOnlyKeys": {"android": {"legacyAlias": "r"}}
}
''');
      _write(root, kotlin, '''
val a = map["shared"]
val b = map["androidOnly"]
val c = map["legacyAlias"]
''');
      _write(root, swift, '''
let a = dictionary["shared"]
// dictionary["dartOnly"] in a comment is not a read.
''');
      expect(ledger.validateRequirements(root: root.path).errors, isEmpty);

      _replace(root, swift, 'let a', 'let d = dictionary["dartOnly"]\nlet a');
      _replace(root, kotlin, 'val c = map["legacyAlias"]\n', '');
      _replace(root, kotlin, 'val b = map["androidOnly"]\n', '');

      final errors = ledger.validateRequirements(root: root.path).errors;
      expect(errors, hasLength(3));
      expect(errors, contains(contains('reads `dartOnly`')));
      expect(errors, contains(contains('native-only key `legacyAlias`')));
      expect(errors, contains(contains('does not read `androidOnly`')));
    });

    group('release metadata', () {
      setUp(() => _writeReleaseMetadata(root));

      test('accepts matching manifests and an older same-major snippet', () {
        _replace(root, 'README.md', '^1.2.0', '^1.1.4');

        expect(ledger.validateRequirements(root: root.path).errors, isEmpty);
      });

      test('rejects a podspec version or iOS floor that drifts', () {
        _replace(root, _podspec, "s.version = '1.2.0'", "s.version = '0.1.2'");
        _replace(root, _swiftPackage, '.iOS("13.0")', '.iOS("14.0")');

        final errors = ledger.validateRequirements(root: root.path).errors;

        expect(errors, contains(contains('version `0.1.2` does not match')));
        expect(errors, contains(contains('Minimum iOS differs')));
      });

      test('rejects a README snippet ahead of or behind the major version', () {
        _replace(root, 'README.md', '^1.2.0', '^0.1.2');
        expect(
          ledger.validateRequirements(root: root.path).errors,
          contains(contains('installs `^0.1.2`')),
        );

        _replace(root, 'README.md', '^0.1.2', '^1.3.0');
        expect(
          ledger.validateRequirements(root: root.path).errors,
          contains(contains('installs `^1.3.0`')),
        );
      });

      test('requires both iOS packagings to ship the privacy manifest', () {
        _replace(root, _swiftPackage, '.process("PrivacyInfo.xcprivacy")', '');

        expect(
          ledger.validateRequirements(root: root.path).errors,
          contains(contains('Package.swift must process PrivacyInfo')),
        );
      });
    });
  });
}

const _podspec = 'ios/flutter_background_location_tracker.podspec';
const _swiftPackage = 'ios/flutter_background_location_tracker/Package.swift';

void _writeReleaseMetadata(Directory root) {
  _write(root, 'pubspec.yaml', '''
name: flutter_background_location_tracker
version: 1.2.0
''');
  _write(root, _podspec, '''
Pod::Spec.new do |s|
  s.name = 'flutter_background_location_tracker'
  s.version = '1.2.0'
  s.resource_bundles = { 'privacy' => ['Sources/PrivacyInfo.xcprivacy'] }
  s.platform = :ios, '13.0'
end
''');
  _write(root, _swiftPackage, '''
let package = Package(
  name: "flutter_background_location_tracker",
  platforms: [.iOS("13.0")],
  targets: [.target(name: "t", resources: [.process("PrivacyInfo.xcprivacy")])]
)
''');
  _write(root, 'README.md', '''
dependencies:
  flutter_background_location_tracker: ^1.2.0
''');
}

const _requirements = 'tool/quality/requirements.yaml';
const _swiftPlugin = 'ios/flutter_background_location_tracker/Sources/'
    'flutter_background_location_tracker/FlutterBackgroundLocationPlugin.swift';

void _writeConsistentTree(Directory root) {
  _write(root, _requirements, '''
schema_version: 1
package: flutter_background_location_tracker
compatibility:
  dart_api: 1
  native_protocol: 2
  route_database_schema: 14
  android_journal_schema: 2
  android_journal_payload_format: 2
  ios_journal_schema: 1
  preset_definition: 4
  quality_policy: 1
  continuity_policy: 2
change_classifications:
  additive: "Adds behavior."
work_packages:
  - id: F0-01
    phase: F0
    title: Synthetic work package
    evidence: []
''');
  _write(root, 'tool/quality/error_codes.yaml', '''
schema_version: 1
codes:
  - code: registered_code
    owner: TrackingException
    recovery: retry
    redaction: none
    commands:
      - sample
''');
  _write(
    root,
    'android/src/main/kotlin/com/samir/flutter_background_location/'
        'FlutterBackgroundLocationPlugin.kt',
    'val protocol = mapOf("version" to 2)\n',
  );
  _write(root, _swiftPlugin, 'let protocol = ["version": 2]\n');
  _write(
    root,
    'lib/src/storage/sqlite_track_repository.dart',
    'final options = OpenDatabaseOptions(\n  version: 14,\n);\n',
  );
  _write(
    root,
    'android/src/main/kotlin/com/samir/flutter_background_location/'
        'PendingLocationStore.kt',
    'private const val JOURNAL_SCHEMA_VERSION = 2\n',
  );
  _write(
    root,
    'android/src/main/kotlin/com/samir/flutter_background_location/'
        'JournalPayloadCodec.kt',
    'const val PAYLOAD_FORMAT = 2\n',
  );
  _write(
    root,
    'ios/flutter_background_location_tracker/Sources/'
        'flutter_background_location_tracker/NativeLocationJournal.swift',
    'try execute("PRAGMA user_version = 1")\n',
  );
  _write(root, 'lib/src/domain/tracking_configuration_epoch.dart', '''
abstract final class TrackingPolicyVersions {
  static const presetDefinition = 4;
  static const qualityPolicy = 1;
  static const continuityPolicy = 2;
}
''');
}

void _write(Directory root, String relativePath, String contents) {
  File('${root.path}/$relativePath')
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);
}

void _replace(Directory root, String relativePath, String from, String to) {
  final file = File('${root.path}/$relativePath');
  final contents = file.readAsStringSync();
  expect(contents, contains(from), reason: 'fixture must contain $from');
  file.writeAsStringSync(contents.replaceFirst(from, to));
}
