import 'dart:math' as math;

import 'activity_snapshot.dart';
import 'track_geodesy.dart';

/// How far a fix's own Doppler speed can be trusted under quality policy 5.
///
/// Chipsets differ in what they report, not where they are: one reports a
/// precise speed with a modest position accuracy, another an optimistic
/// position accuracy with metres per second of speed uncertainty, or a speed
/// of exactly zero with a large uncertainty when it has no velocity solution.
/// Speed accuracy therefore never rejects a fix; it only decides what the
/// fix's Doppler speed may vouch for.
enum DopplerClass {
  /// Speed accuracy of at most [KinematicPolicy.preciseSpeedAccuracy]: the
  /// speed may vouch for the fix's own position.
  precise,

  /// Speed accuracy below [KinematicPolicy.usableSpeedAccuracy]: the speed may
  /// confirm a suspect fix or a departure.
  usable,

  /// Anything else, including the zero placeholder.
  degraded,
}

/// Travel mode that bounds how fast the device can have moved since the
/// route's last accepted point, from the newest fresh activity reading.
enum KinematicMode { pedestrian, running, bicycle, vehicle, other }

/// Rules of quality policy 5 that compare a fix with where the device could
/// have been (`K1`–`K3`), and the effective uncertainty they use (`R3`).
///
/// Displacement decides; Doppler and activity only support it. A fix the
/// rules doubt is stored as rejected evidence with
/// [kinematicOutlierReason], never deleted, and a later fix that agrees with
/// it re-anchors the route. Pure functions only: the decision engine keeps
/// the state.
abstract final class KinematicPolicy {
  /// Rejection reason and issue code of a fix the kinematic rules doubt.
  static const kinematicOutlierReason = 'kinematic_outlier';

  /// Issue code of the first far fix after a silence that its Doppler speed
  /// could not vouch for.
  static const unconfirmedAfterGapIssue = 'unconfirmed_after_gap';

  /// Largest speed accuracy, in m/s, of a precise Doppler speed.
  static const double preciseSpeedAccuracy = 1.5;

  /// Speed accuracies at or above this, in m/s, are degraded.
  static const double usableSpeedAccuracy = 3.0;

  /// A speed below this, in m/s, with a speed accuracy of at least
  /// [preciseSpeedAccuracy] is the zero placeholder of a missing velocity
  /// solution, not a measured stillness.
  static const double zeroPlaceholderSpeed = 0.05;

  /// Floor of the effective per-axis uncertainty, in metres.
  static const double minimumSigmaMeters = 1.5;

  /// Floor of the distance two fixes may disagree by, in metres.
  static const double minimumUncertaintyMeters = 20;

  /// Standard deviations of combined uncertainty two fixes may disagree by.
  static const double uncertaintyFactor = 3;

  /// Ceiling of every speed bound, in m/s.
  static const double maximumSpeedMetersPerSecond = 70;

  /// Shortest silence after which the next far fix must prove itself.
  static const minimumReacquisitionSilence = Duration(seconds: 20);

  /// Moving intervals of silence after which the next far fix must prove
  /// itself, when that is longer than [minimumReacquisitionSilence].
  static const int reacquisitionIntervals = 4;

  /// A fix at least this far from the reference, in metres (or the combined
  /// uncertainty when larger), is far after a silence.
  static const double reacquisitionMinimumMeters = 30;

  /// Window before the reference point whose motion bounds the next fix.
  static const contextWindow = Duration(seconds: 60);

  /// How long degraded suspects must persist before they can re-anchor the
  /// route without a usable confirmation.
  static const suspectPersistence = Duration(seconds: 30);

  /// Suspects that must fit one constant-velocity line to re-anchor the route
  /// after [suspectPersistence].
  static const int suspectConsensusFixes = 3;

  /// Above this reference speed, in m/s, a walking reading no longer makes
  /// the device a pedestrian.
  static const double pedestrianMaximumReferenceSpeed = 3;

  /// Longest acceleration time, in seconds, a context bound allows for.
  static const double accelerationSeconds = 10;

  /// Acceleration, in m/s², a context bound allows for outside walking.
  static const double accelerationMetersPerSecondSquared = 2;

  /// How trustworthy the Doppler speed [speed] ± [speedAccuracy] is.
  static DopplerClass classify({
    required double? speed,
    required double? speedAccuracy,
  }) {
    if (speed == null ||
        speedAccuracy == null ||
        !speed.isFinite ||
        !speedAccuracy.isFinite ||
        speed < 0 ||
        speedAccuracy < 0) {
      return DopplerClass.degraded;
    }
    if (speed < zeroPlaceholderSpeed && speedAccuracy >= preciseSpeedAccuracy) {
      return DopplerClass.degraded;
    }
    if (speedAccuracy <= preciseSpeedAccuracy) return DopplerClass.precise;
    if (speedAccuracy < usableSpeedAccuracy) return DopplerClass.usable;
    return DopplerClass.degraded;
  }

  /// Whether [doppler] may confirm a suspect or a departure.
  static bool isUsable(DopplerClass doppler) =>
      doppler != DopplerClass.degraded;

  /// Silence after which the next far fix must prove itself: the longer of
  /// [minimumReacquisitionSilence] and [reacquisitionIntervals] moving
  /// intervals.
  static Duration reacquisitionSilence(Duration movingInterval) {
    final intervals = movingInterval * reacquisitionIntervals;
    return intervals > minimumReacquisitionSilence
        ? intervals
        : minimumReacquisitionSilence;
  }

  /// Effective per-axis uncertainty (`R3`): reported accuracy can only widen
  /// it, never narrow it below what the fixes themselves show.
  static double effectiveSigma({
    required double reportedSigmaMeters,
    double? observedSigmaMeters,
  }) =>
      math.max(
        minimumSigmaMeters,
        math.max(reportedSigmaMeters, observedSigmaMeters ?? 0),
      );

  /// Distance, in metres, two fixes with per-axis uncertainties
  /// [firstSigmaMeters] and [secondSigmaMeters] may disagree by.
  static double uncertaintyMeters(
    double firstSigmaMeters,
    double secondSigmaMeters,
  ) =>
      math.max(
        minimumUncertaintyMeters,
        uncertaintyFactor *
            math.sqrt(
              firstSigmaMeters * firstSigmaMeters +
                  secondSigmaMeters * secondSigmaMeters,
            ),
      );

  /// Speed bound, in m/s, a precise Doppler speed vouches for; null when the
  /// speed is not precise.
  static double? ownSpeedBound({
    required double? speed,
    required double? speedAccuracy,
  }) {
    if (classify(speed: speed, speedAccuracy: speedAccuracy) !=
        DopplerClass.precise) {
      return null;
    }
    return 1.5 * speed! + 3 * speedAccuracy! + 0.5;
  }

  /// Travel mode from the newest fresh activity reading [reading] and the
  /// route's recent speed [referenceSpeed].
  static KinematicMode modeOf(
    ActivitySnapshot? reading, {
    required double referenceSpeed,
  }) {
    final type = reading?.type;
    if (type == TrackingActivityType.inVehicle) return KinematicMode.vehicle;
    if (type == TrackingActivityType.onBicycle) return KinematicMode.bicycle;
    if (referenceSpeed < pedestrianMaximumReferenceSpeed) {
      if (type == TrackingActivityType.running) return KinematicMode.running;
      if (type == TrackingActivityType.walking) return KinematicMode.pedestrian;
    }
    return KinematicMode.other;
  }

  /// Speed bound, in m/s, the route's context allows over [elapsed]: mode
  /// floors and the recent speed, never a tight cap, so a vehicle whose
  /// activity reading lags is not throttled.
  static double contextSpeedBound({
    required KinematicMode mode,
    required double referenceSpeed,
    required Duration elapsed,
  }) {
    switch (mode) {
      case KinematicMode.pedestrian:
        return math.max(3, 1.5 * referenceSpeed + 1);
      case KinematicMode.running:
        return math.max(6, 1.5 * referenceSpeed + 1);
      case KinematicMode.bicycle:
      case KinematicMode.vehicle:
      case KinematicMode.other:
        final floor = switch (mode) {
          KinematicMode.vehicle => 15.0,
          KinematicMode.bicycle => 10.0,
          _ => 3.0,
        };
        final seconds = math.min(
          elapsed.inMilliseconds / 1000,
          accelerationSeconds,
        );
        return math.max(floor, 1.5 * referenceSpeed + 3) +
            accelerationMetersPerSecondSquared * seconds;
    }
  }

  /// Whether a fix [distanceMeters] from the reference after [elapsed] is
  /// reachable (`K1`) within [uncertainty] and the speed bound [speedBound].
  static bool reachable({
    required double distanceMeters,
    required double uncertainty,
    required double speedBound,
    required Duration elapsed,
  }) {
    final seconds = math.max(0, elapsed.inMilliseconds) / 1000;
    final speed = math.min(speedBound, maximumSpeedMetersPerSecond);
    return distanceMeters <= uncertainty + speed * seconds;
  }

  /// Whether the first far fix after a silence may be accepted at once
  /// (`K2`): only a precise Doppler speed that covers the displacement beyond
  /// [uncertainty] vouches for it.
  static bool vouchedAfterSilence({
    required double distanceMeters,
    required double uncertainty,
    required Duration elapsed,
    required double? speed,
    required double? speedAccuracy,
  }) {
    final bound = ownSpeedBound(speed: speed, speedAccuracy: speedAccuracy);
    if (bound == null) return false;
    final seconds = math.max(1, elapsed.inMilliseconds) / 1000;
    return math.max(0, distanceMeters - uncertainty) / seconds <= bound;
  }

  /// Largest distance, in metres, of three or more points from the
  /// least-squares constant-velocity line through them, in a local tangent
  /// plane; null for fewer than three points or a zero time span.
  static double? constantVelocityResidualMeters(List<KinematicPoint> points) {
    if (points.length < 3) return null;
    final origin = points.first;
    const metersPerDegree = TrackGeodesy.meanEarthRadiusMeters * math.pi / 180;
    final cosine = math.cos(origin.latitude * math.pi / 180);
    final times = <double>[];
    final easts = <double>[];
    final norths = <double>[];
    for (final point in points) {
      times.add(
        point.capturedAt.difference(origin.capturedAt).inMilliseconds / 1000,
      );
      easts.add(
        TrackGeodesy.longitudeDelta(origin.longitude, point.longitude) *
            metersPerDegree *
            cosine,
      );
      norths.add((point.latitude - origin.latitude) * metersPerDegree);
    }
    double mean(List<double> values) =>
        values.reduce((a, b) => a + b) / values.length;
    final meanTime = mean(times);
    final meanEast = mean(easts);
    final meanNorth = mean(norths);
    var timeSumOfSquares = 0.0;
    var east = 0.0;
    var north = 0.0;
    for (var index = 0; index < points.length; index += 1) {
      final dt = times[index] - meanTime;
      timeSumOfSquares += dt * dt;
      east += dt * (easts[index] - meanEast);
      north += dt * (norths[index] - meanNorth);
    }
    if (timeSumOfSquares <= 0) return null;
    final eastVelocity = east / timeSumOfSquares;
    final northVelocity = north / timeSumOfSquares;
    var largest = 0.0;
    for (var index = 0; index < points.length; index += 1) {
      final dt = times[index] - meanTime;
      final eastResidual = easts[index] - meanEast - eastVelocity * dt;
      final northResidual = norths[index] - meanNorth - northVelocity * dt;
      largest = math.max(
        largest,
        math.sqrt(eastResidual * eastResidual + northResidual * northResidual),
      );
    }
    return largest;
  }

  /// Per-axis uncertainty, in metres, a run of moving fixes shows: the
  /// median second difference of evenly spaced triples divided by the
  /// Rayleigh median of a second difference of independent errors
  /// (`1.177 × √6` standard deviations). Null with fewer than
  /// [minimumObservedTriples] usable triples.
  static double? observedMovingSigma(List<KinematicPoint> points) {
    final magnitudes = <double>[];
    for (var index = 1; index + 1 < points.length; index += 1) {
      final previous = points[index - 1];
      final current = points[index];
      final next = points[index + 1];
      final first = current.capturedAt.difference(previous.capturedAt);
      final second = next.capturedAt.difference(current.capturedAt);
      if (first <= Duration.zero ||
          second <= Duration.zero ||
          first > observedTripleMaximumGap ||
          second > observedTripleMaximumGap ||
          (first - second).abs() > observedTripleSpacingTolerance) {
        continue;
      }
      final cosine = math.cos(current.latitude * math.pi / 180);
      const metersPerDegree =
          TrackGeodesy.meanEarthRadiusMeters * math.pi / 180;
      final east = (TrackGeodesy.longitudeDelta(
                current.longitude,
                next.longitude,
              ) -
              TrackGeodesy.longitudeDelta(
                previous.longitude,
                current.longitude,
              )) *
          metersPerDegree *
          cosine;
      final north = ((next.latitude - current.latitude) -
              (current.latitude - previous.latitude)) *
          metersPerDegree;
      magnitudes.add(math.sqrt(east * east + north * north));
    }
    if (magnitudes.length < minimumObservedTriples) return null;
    magnitudes.sort();
    final middle = magnitudes.length ~/ 2;
    final median = magnitudes.length.isOdd
        ? magnitudes[middle]
        : (magnitudes[middle - 1] + magnitudes[middle]) / 2;
    return median / (rayleighMedianFactor * math.sqrt(6));
  }

  /// Median of a Rayleigh distribution in standard deviations, `√(2 ln 2)`.
  static const double rayleighMedianFactor = 1.1774100225154747;

  /// Fewest evenly spaced triples [observedMovingSigma] needs.
  static const int minimumObservedTriples = 10;

  /// Largest gap inside a triple used by [observedMovingSigma].
  static const observedTripleMaximumGap = Duration(seconds: 15);

  /// Largest difference between a triple's two gaps.
  static const observedTripleSpacingTolerance = Duration(seconds: 1);
}

/// A position and time the kinematic rules compare.
final class KinematicPoint {
  const KinematicPoint({
    required this.latitude,
    required this.longitude,
    required this.capturedAt,
  });

  final double latitude;
  final double longitude;
  final DateTime capturedAt;
}
