import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The turn-capture contract the Kotlin and Swift samplers replay.
void main() {
  const canonicalPath = 'test/fixtures/cross_language/turn_capture_v1.json';
  const copies = <String>[
    'android/src/test/resources/turn_capture_v1.json',
    'example/ios/RunnerTests/turn_capture_v1.json',
  ];

  test('native copies of the fixture are byte-identical', () {
    final canonical = File(canonicalPath).readAsBytesSync();
    for (final copy in copies) {
      expect(File(copy).readAsBytesSync(), canonical, reason: copy);
    }
  });

  test('every scenario records indices of its own fixes, in order', () {
    final fixture = (jsonDecode(File(canonicalPath).readAsStringSync()) as Map)
        .cast<String, Object?>();
    final scenarios = (fixture['scenarios']! as List).cast<Map>();
    expect(scenarios, hasLength(greaterThanOrEqualTo(8)));
    for (final scenario in scenarios) {
      final fixes = scenario['fixes']! as List;
      final recorded = (scenario['recorded']! as List).cast<int>();
      expect(recorded.first, 0, reason: '${scenario['name']}');
      expect(recorded, orderedEquals([...recorded]..sort()));
      expect(recorded.last, lessThan(fixes.length));
    }
  });
}
