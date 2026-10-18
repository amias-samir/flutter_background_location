import 'dart:convert';
import 'dart:io';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixture = (jsonDecode(
    File('test/fixtures/config_key_coverage_v1.json').readAsStringSync(),
  ) as Map)
      .cast<String, Object?>();
  final keys = (fixture['keys']! as Map).cast<String, Object?>();

  test('FIX-13 the coverage contract lists every serialized config key', () {
    final emitted = <String>{
      for (final accuracy in TrackingAccuracy.values)
        for (final intent in RouteCaptureIntent.values)
          ...TrackingConfig(accuracy: accuracy, captureIntent: intent)
              .toMap()
              .keys,
      ...const TrackingConfig(
        iosTerminationRecoveryMode:
            IosTerminationRecoveryMode.significantChange,
      ).toMap().keys,
    };

    expect(keys.keys.toSet(), emitted);
  });

  test('every key states each platform and explains what natives ignore', () {
    for (final MapEntry(key: key, value: raw) in keys.entries) {
      final entry = (raw! as Map).cast<String, Object?>();
      for (final platform in <String>['android', 'ios']) {
        expect(<Object?>['parsed', 'ignored'], contains(entry[platform]),
            reason: '$key/$platform');
      }
      if (entry.values.contains('ignored')) {
        expect(entry['reason'], isA<String>(), reason: key);
      }
    }
  });
}
