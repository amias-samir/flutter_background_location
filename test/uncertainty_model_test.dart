import 'dart:math' as math;

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/src/domain/uncertainty_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LBO-18 uncertainty model v1', () {
    test('a 68 % radius maps to per-axis sigma with a floor', () {
      // The 68 % radius of a circular normal is sqrt(-2 ln 0.32) sigmas.
      expect(
        UncertaintyModel.radiusPerSigma,
        closeTo(math.sqrt(-2 * math.log(0.32)), 0.001),
      );
      expect(
        UncertaintyModel.horizontalSigmaMeters(15.1, FixOriginClass.gnss),
        closeTo(10, 0.001),
      );
      expect(
        UncertaintyModel.horizontalSigmaMeters(1, FixOriginClass.gnss),
        UncertaintyModel.minimumHorizontalSigmaMeters,
      );
      expect(
        UncertaintyModel.horizontalSigmaMeters(15.1, FixOriginClass.network),
        closeTo(18, 0.001),
      );
      for (final invalid in <double?>[null, 0, -1, double.nan]) {
        expect(
          UncertaintyModel.horizontalSigmaMeters(invalid, FixOriginClass.gnss),
          isNull,
        );
      }
    });

    test('correlated fixes average down far less than independent ones', () {
      const origin = FixOriginClass.gnss;
      final second = UncertaintyModel.averagingVarianceFactor(
        const Duration(seconds: 1),
        origin,
      );
      final halfMinute = UncertaintyModel.averagingVarianceFactor(
        const Duration(seconds: 30),
        origin,
      );
      final tenMinutes = UncertaintyModel.averagingVarianceFactor(
        const Duration(minutes: 10),
        origin,
      );

      expect(second, UncertaintyModel.maximumAveragingVarianceFactor);
      expect(
          halfMinute, closeTo((1 + math.exp(-1)) / (1 - math.exp(-1)), 1e-9));
      expect(tenMinutes, closeTo(1, 1e-6));
      // Network errors stay correlated longer than GNSS errors.
      expect(
        UncertaintyModel.averagingVarianceFactor(
          const Duration(seconds: 60),
          FixOriginClass.network,
        ),
        greaterThan(
          UncertaintyModel.averagingVarianceFactor(
            const Duration(seconds: 60),
            FixOriginClass.gnss,
          ),
        ),
      );
    });

    test('kinematic sigmas have floors and need a reported accuracy', () {
      expect(UncertaintyModel.speedSigmaMetersPerSecond(0.02), 0.1);
      expect(UncertaintyModel.speedSigmaMetersPerSecond(0.6), 0.6);
      expect(UncertaintyModel.speedSigmaMetersPerSecond(null), isNull);
      expect(UncertaintyModel.bearingSigmaDegrees(0.5), 2);
      expect(UncertaintyModel.bearingSigmaDegrees(-1), isNull);
    });

    test('origin is inferred from coordinate-free signals', () {
      LocationSample sample({
        double? accuracy = 5,
        double? speedAccuracy,
        double? verticalAccuracy,
        bool? accessory,
      }) =>
          LocationSample(
            latitude: 0.001,
            longitude: 0.001,
            capturedAt: DateTime.utc(2026, 7, 20, 8),
            horizontalAccuracy: accuracy,
            speedAccuracy: speedAccuracy,
            verticalAccuracy: verticalAccuracy,
            isProducedByAccessory: accessory,
          );

      expect(
        UncertaintyModel.inferOrigin(
          sample(speedAccuracy: 0.3, verticalAccuracy: 4),
        ),
        FixOriginClass.gnss,
      );
      expect(
        UncertaintyModel.inferOrigin(sample(accuracy: 40)),
        FixOriginClass.network,
      );
      expect(
        UncertaintyModel.inferOrigin(
          sample(accuracy: 40, speedAccuracy: 0.3, verticalAccuracy: 4),
        ),
        FixOriginClass.unknown,
      );
      expect(
        UncertaintyModel.inferOrigin(sample(accessory: true)),
        FixOriginClass.accessory,
      );
    });
  });
}
