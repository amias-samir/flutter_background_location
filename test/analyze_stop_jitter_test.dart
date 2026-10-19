import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import '../tool/quality/analyze_stop_jitter.dart';

void main() {
  // A synthetic export: a 150 m walk, a 20-minute stop with metre-scale
  // jitter and some held fixes, then a walk away. Generated coordinates only.
  Map<String, Object?> export() {
    const metersPerDegree = 111195.07973436875;
    final start = DateTime.utc(2026, 10, 18, 13);
    final features = <Map<String, Object?>>[];
    void point(
      int seconds,
      double east,
      double north, {
      bool accepted = true,
      String? reason,
      String profile = 'moving',
      int? activityAgeMs,
      String activity = 'onFoot',
      int confidence = 90,
    }) {
      features.add(<String, Object?>{
        'type': 'Feature',
        'geometry': <String, Object?>{
          'type': 'Point',
          'coordinates': <double>[
            0.5 + east / (metersPerDegree * math.cos(0.5 * math.pi / 180)),
            0.5 + north / metersPerDegree,
          ],
        },
        'properties': <String, Object?>{
          'capturedAt': start.add(Duration(seconds: seconds)).toIso8601String(),
          'accuracy': 3.0,
          'accepted': accepted,
          if (reason != null) 'rejectionReason': reason,
          'samplingProfile': profile,
          if (activityAgeMs != null) 'activityAgeMs': activityAgeMs,
          'activityRawType': activity,
          'activityConfidence': confidence,
        },
      });
    }

    for (var step = 0; step <= 25; step += 1) {
      point(step * 5, -150 + step * 6.0, 0);
    }
    final random = math.Random(4);
    for (var step = 0; step < 60; step += 1) {
      final held = step.isOdd;
      point(
        130 + step * 20,
        (random.nextDouble() - 0.5) * 16,
        (random.nextDouble() - 0.5) * 16,
        accepted: !held,
        reason: held ? 'stationary_hold' : null,
        profile: step > 10 ? 'stationary' : 'moving',
        activityAgeMs: step == 40 ? 900000 : 3000,
        activity: step == 20 ? 'still' : 'unknown',
        confidence: step == 20 ? 100 : 40,
      );
    }
    for (var step = 1; step <= 25; step += 1) {
      point(130 + 60 * 20 + step * 5, step * 6.0, 0);
    }
    return <String, Object?>{'type': 'FeatureCollection', 'features': features};
  }

  test('finds the stop and reports its jitter without coordinates', () {
    final report = analyzeStopJitter(export());
    expect(report.pointCount, 26 + 60 + 25);
    expect(report.rejectionReasons, <String, int>{'stationary_hold': 30});
    expect(report.stops, hasLength(1));
    final stop = report.stops.single;
    expect(stop.duration.inMinutes, greaterThanOrEqualTo(19));
    expect(stop.heldCount, 30);
    expect(stop.acceptedCount, greaterThanOrEqualTo(30));
    expect(stop.phantomDistanceMeters, greaterThan(100));
    expect(stop.spreadMaxMeters, lessThan(stopRadiusMeters + 1));
    expect(stop.stillEvidence, isTrue);
    expect(stop.activityMix.keys.first, 'unknown');
    expect(stop.reliableDopplerP50, isNull, reason: 'no precise speeds');
    expect(stop.spreadToAccuracyP50, isNotNull);
    expect(stop.stationaryProfileShare, inInclusiveRange(0.7, 0.9));
    expect(stop.longestActivitySilence, const Duration(minutes: 15));

    final text = formatStopJitterReport(report);
    expect(text, contains('still evidence yes'));
    expect(text, contains('stops'));
    // Coordinate-free: no degree values appear in the report.
    expect(text, isNot(contains('0.50')));
  });

  test('a slow walk with short pauses has no stops', () {
    const metersPerDegree = 111195.07973436875;
    final start = DateTime.utc(2026, 10, 19, 3);
    final features = <Map<String, Object?>>[];
    var at = 0;
    var east = 0.0;
    for (var leg = 0; leg < 8; leg += 1) {
      for (var step = 0; step < 6; step += 1) {
        at += 5;
        east += 5;
        features.add(<String, Object?>{
          'type': 'Feature',
          'geometry': <String, Object?>{
            'type': 'Point',
            'coordinates': <double>[
              0.5 + east / (metersPerDegree * math.cos(0.5 * math.pi / 180)),
              0.5,
            ],
          },
          'properties': <String, Object?>{
            'capturedAt': start.add(Duration(seconds: at)).toIso8601String(),
            'accuracy': 4.0,
            'accepted': true,
            'speed': 1.0,
            'speedAccuracy': 0.25,
            'activityRawType': 'onFoot',
            'activityConfidence': 92,
          },
        });
      }
      at += 75;
    }
    final report = analyzeStopJitter(<String, Object?>{
      'type': 'FeatureCollection',
      'features': features,
    });
    expect(report.stops, isEmpty);
  });
}
