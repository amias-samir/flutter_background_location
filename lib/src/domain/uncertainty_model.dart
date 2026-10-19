import 'dart:math' as math;

import 'location_sample.dart';

/// Where a fix most likely came from, inferred from cheap coordinate-free
/// signals. Inferred, never reported by the platform as such.
enum FixOriginClass { gnss, network, accessory, unknown }

/// Uncertainty model v1 (`uncertainty_model_v1`).
///
/// Turns reported accuracy radii into per-axis standard deviations for
/// statistics (stationary tests, smoothing, kinematic checks). Acceptance
/// thresholds stay in reported-radius units, so no preset is reinterpreted.
/// Native evidence windows mirror these constants.
abstract final class UncertaintyModel {
  static const id = 'uncertainty_model_v1';

  /// Floor for a per-axis horizontal standard deviation, in metres.
  static const minimumHorizontalSigmaMeters = 1.5;

  /// Reported radius per standard deviation. Android reports the radius of a
  /// 68 % circle, which is `sqrt(-2 ln 0.32)` ≈ 1.51 per-axis deviations.
  /// iOS defines no confidence; 1.51 is provisional until calibrated.
  static const radiusPerSigma = 1.51;

  /// Above this reported accuracy a fix is not treated as GNSS evidence.
  static const maximumGnssAccuracyMeters = 25.0;

  /// Upper bound of [averagingVarianceFactor].
  static const maximumAveragingVarianceFactor = 6.0;

  static const _originFactors = <FixOriginClass, double>{
    FixOriginClass.gnss: 1.0,
    FixOriginClass.network: 1.8,
    FixOriginClass.accessory: 1.2,
    FixOriginClass.unknown: 1.2,
  };

  static const _correlationTimes = <FixOriginClass, Duration>{
    FixOriginClass.gnss: Duration(seconds: 30),
    FixOriginClass.network: Duration(seconds: 120),
    FixOriginClass.accessory: Duration(seconds: 60),
    FixOriginClass.unknown: Duration(seconds: 60),
  };

  /// Per-axis horizontal standard deviation, or null without a positive,
  /// finite reported accuracy.
  static double? horizontalSigmaMeters(
    double? reportedAccuracyMeters,
    FixOriginClass origin,
  ) {
    if (reportedAccuracyMeters == null ||
        !reportedAccuracyMeters.isFinite ||
        reportedAccuracyMeters <= 0) {
      return null;
    }
    final sigma = math.max(
      minimumHorizontalSigmaMeters,
      reportedAccuracyMeters / radiusPerSigma,
    );
    return sigma * _originFactors[origin]!;
  }

  /// How much more variance an average of fixes [spacing] apart has than
  /// independent fixes would: `(1 + ρ) / (1 − ρ)` with `ρ = e^(−Δt/τ)`.
  ///
  /// Phone errors are multipath-dominated and correlated for tens of seconds,
  /// so averaging a stop's fixes shrinks uncertainty far less than `1/n`.
  static double averagingVarianceFactor(
    Duration spacing,
    FixOriginClass origin,
  ) {
    final tau = _correlationTimes[origin]!.inMicroseconds;
    final dt = spacing.inMicroseconds;
    if (dt <= 0) return maximumAveragingVarianceFactor;
    final rho = math.exp(-dt / tau);
    return math.min(maximumAveragingVarianceFactor, (1 + rho) / (1 - rho));
  }

  /// Speed standard deviation in m/s, or null without a speed accuracy.
  static double? speedSigmaMetersPerSecond(double? speedAccuracy) =>
      speedAccuracy == null || !speedAccuracy.isFinite || speedAccuracy < 0
          ? null
          : math.max(0.1, speedAccuracy);

  /// Bearing standard deviation in degrees, or null without an accuracy.
  static double? bearingSigmaDegrees(double? bearingAccuracy) =>
      bearingAccuracy == null ||
              !bearingAccuracy.isFinite ||
              bearingAccuracy < 0
          ? null
          : math.max(2.0, bearingAccuracy);

  /// Infers the origin from coordinate-free signals: GNSS fixes carry speed
  /// and vertical accuracies and a small radius; network fixes carry neither.
  static FixOriginClass inferOrigin(LocationSample sample) =>
      inferOriginFromEvidence(
        horizontalAccuracy: sample.horizontalAccuracy,
        hasSpeedAccuracy: sample.speedAccuracy != null,
        hasVerticalAccuracy: sample.verticalAccuracy != null,
        producedByAccessory: sample.isProducedByAccessory,
      );

  /// [inferOrigin] for evidence that is not a [LocationSample], such as a
  /// stored point.
  static FixOriginClass inferOriginFromEvidence({
    required double? horizontalAccuracy,
    required bool hasSpeedAccuracy,
    required bool hasVerticalAccuracy,
    bool? producedByAccessory,
  }) {
    if (producedByAccessory == true) return FixOriginClass.accessory;
    final accuracy = horizontalAccuracy;
    if (hasSpeedAccuracy &&
        hasVerticalAccuracy &&
        accuracy != null &&
        accuracy > 0 &&
        accuracy <= maximumGnssAccuracyMeters) {
      return FixOriginClass.gnss;
    }
    if (!hasSpeedAccuracy && !hasVerticalAccuracy) {
      return FixOriginClass.network;
    }
    return FixOriginClass.unknown;
  }
}
