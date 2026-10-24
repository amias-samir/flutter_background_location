import 'dart:math' as math;

import 'activity_snapshot.dart';
import 'kinematic_policy.dart';
import 'motion_policy.dart';
import 'track_geodesy.dart';

/// Rules of quality policy 3, where a stop is a stay at a place and the route
/// keeps only movement.
///
/// A *stay* starts at the first quiet fix, one without moving evidence, or at
/// a motion-policy-2 still episode. Its quiet fixes are held from the start,
/// so no stop or pause jitter enters the route. A stay that lasts
/// [dwellMinimumDuration] with no net progress, or with still evidence,
/// becomes a stop: walking inside its radius is then part of it, and a stop
/// record keeps where it was and how long it lasted. A shorter stay is a
/// pause and ends at the first moving fix. Dart only: native sampling keeps
/// motion policy 2.
abstract final class StopSitePolicy {
  /// How long a stay must last before it is a stop.
  static const dwellMinimumDuration = Duration(minutes: 2);

  /// A moving reading this recent makes a fix a moving one. Activity
  /// Recognition reports every few seconds while its owner walks or rides.
  static const quietWindow = Duration(seconds: 30);

  /// Largest net progress of a dwell's fixes, in metres per second: their
  /// least-squares velocity less twice its standard error, so scattered fixes
  /// of a stop don't fake progress. A slow walk with pauses moves along a
  /// line and makes clearly more progress than this, so it keeps its
  /// distance.
  static const dwellMaximumTrendSpeedMetersPerSecond = 0.15;

  /// A Doppler speed at least this high, measured to within
  /// [movingDopplerMaximumSpeedAccuracy], is moving evidence.
  static const movingDopplerSpeedMetersPerSecond = 0.6;

  /// Largest speed accuracy, in metres per second, of a Doppler speed that
  /// counts as moving evidence.
  static const movingDopplerMaximumSpeedAccuracy = 0.4;

  /// A precise Doppler speed whose value plus accuracy stays within this, in
  /// metres per second, shows the device is still, whatever an older activity
  /// reading said. A slow walk measures more.
  static const stillDopplerMaximumMetersPerSecond = 0.5;

  /// How long a moving reading stays current for a departure. Leaving the
  /// radius with current moving evidence departs on the second outside fix.
  static const movingEvidenceWindow = Duration(seconds: 60);

  /// Most fixes a confined run keeps, oldest dropped first.
  static const maximumDwellRunFixes = 256;

  /// Whether a measured Doppler speed shows movement. Unlike
  /// [MotionPolicyV2.dopplerConfirmsDeparture], a walking speed counts when it
  /// is measured precisely; indoor speeds with metres per second of
  /// uncertainty never do.
  static bool dopplerShowsMovement({
    required double? speed,
    required double? speedAccuracy,
  }) {
    if (speed == null || speedAccuracy == null) return false;
    if (!speed.isFinite || !speedAccuracy.isFinite || speedAccuracy < 0) {
      return false;
    }
    return speedAccuracy <= movingDopplerMaximumSpeedAccuracy &&
        speed >=
            math.max(
              movingDopplerSpeedMetersPerSecond,
              MotionPolicyV2.departureSpeedAccuracyFactor * speedAccuracy,
            );
  }

  /// Whether a measured Doppler speed shows movement, at walking pace when
  /// precisely measured or as a clear departure otherwise.
  static bool showsMovement({
    required double? speed,
    required double? speedAccuracy,
  }) =>
      dopplerShowsMovement(speed: speed, speedAccuracy: speedAccuracy) ||
      MotionPolicyV2.dopplerConfirmsDeparture(
        speed: speed,
        speedAccuracy: speedAccuracy,
      );

  /// Whether a precise Doppler speed shows the device is still: measured to
  /// within [movingDopplerMaximumSpeedAccuracy] and, with that accuracy
  /// added, at most [stillDopplerMaximumMetersPerSecond].
  static bool dopplerShowsStillness({
    required double? speed,
    required double? speedAccuracy,
  }) {
    if (speed == null || speedAccuracy == null) return false;
    if (!speed.isFinite || !speedAccuracy.isFinite || speedAccuracy < 0) {
      return false;
    }
    return speedAccuracy <= movingDopplerMaximumSpeedAccuracy &&
        speed + speedAccuracy <= stillDopplerMaximumMetersPerSecond;
  }

  /// Whether [activity] is moving evidence: a moving reading at or above its
  /// threshold, an ENTER transition into a moving activity, or EXIT STILL.
  static bool isMovingEvidence(
    ActivitySnapshot activity, {
    required int movingConfidenceThreshold,
  }) =>
      MotionPolicyV2.isMovingTransitionEnter(activity) ||
      MotionPolicyV2.isStillTransitionExit(activity) ||
      MotionPolicyV2.isMovingReading(
        activity,
        movingConfidenceThreshold: movingConfidenceThreshold,
      );
}

/// Rules of quality policy 5 for stays at a place, chipset-agnostic.
///
/// Version 3's pause ended at the first fix with one moving reading or a
/// walking-pace Doppler speed measured to 0.4 m/s, anywhere: a pocketed
/// phone's Doppler noise or one Activity Recognition reading split stops on
/// one phone and not on another. Here nothing inside the hold radius ends a
/// stay. Outside it, a stay ends on a Doppler speed whose lower bound shows
/// movement, on confirmed activity (never one reading), or on steady outward
/// progress; a fresh confident still reading with no measured speed blocks
/// the activity and progress exits. The radius comes from effective
/// uncertainty and is clamped, so neither an optimistic chipset nor a few
/// network fixes change it much. Network fixes never set the radius, never
/// count as members and never confirm a departure.
abstract final class StopSitePolicyV5 {
  /// Smallest hold radius, in metres.
  static const double radiusFloorMeters = 25;

  /// Largest hold radius, in metres.
  static const double radiusCapMeters = 60;

  /// `√9.21`: the 99 % radius of a two-dimensional normal, per sigma.
  static const double radiusSigmaFactor = 3.0348;

  /// A Doppler speed less twice its accuracy must reach this, in m/s, to show
  /// movement.
  static const double leavingLowerBoundMetersPerSecond = 0.4;

  /// Doppler speed, in m/s, that leaves a pause.
  static const double pauseLeavingSpeedMetersPerSecond = 0.6;

  /// Doppler speed, in m/s, that leaves a stop.
  static const double stopLeavingSpeedMetersPerSecond = 1.2;

  /// Moving readings this far apart or closer confirm activity.
  static const confirmedReadingsWindow = Duration(seconds: 60);

  /// The newest confirming reading must be this recent.
  static const confirmedReadingFreshness = Duration(seconds: 30);

  /// Consecutive outside fixes, each farther out, that leave a pause.
  static const int pauseProgressFixes = 3;

  /// Shortest span of those fixes.
  static const pauseProgressSpan = Duration(seconds: 10);

  /// Shortest outside run that leaves a stop by progress.
  static const stopProgressSpan = Duration(seconds: 60);

  /// Smallest distance trend, in m/s, of that run.
  static const double stopProgressTrendMetersPerSecond = 0.2;

  /// Outside fixes must reach this many radii out to leave by progress.
  static const double progressRadiusFactor = 2;

  /// A still reading at or above this confidence can block an exit.
  static const int blockerStillConfidence = 75;

  /// How recent that still reading must be.
  static const blockerStillFreshness = Duration(seconds: 30);

  /// Largest Doppler speed, in m/s, that lets a still reading block an exit.
  static const double blockerMaximumSpeedMetersPerSecond = 0.3;

  /// Consecutive agreeing outside fixes that re-anchor a pause once.
  static const int reanchorFixes = 3;

  /// Shortest span of those fixes.
  static const reanchorSpan = Duration(seconds: 15);

  /// Fewest member fixes, spanning [promotionSpan], that make a stay a stop.
  static const int promotionMembers = 3;

  /// Shortest span of those members.
  static const promotionSpan = Duration(seconds: 60);

  /// Fewest member fixes that make a stay with still evidence a stop.
  static const int stillPromotionMembers = 2;

  /// Hold radius, in metres, around a centre with per-axis uncertainty
  /// [centreSigmaMeters] for a fix with [fixSigmaMeters].
  static double holdRadiusMeters({
    required double centreSigmaMeters,
    required double fixSigmaMeters,
  }) =>
      math.min(
        radiusCapMeters,
        math.max(
          radiusFloorMeters,
          radiusSigmaFactor *
              math.sqrt(
                centreSigmaMeters * centreSigmaMeters +
                    fixSigmaMeters * fixSigmaMeters,
              ),
        ),
      );

  /// Whether a Doppler speed leaves a stay: usable, with a lower bound of at
  /// least [leavingLowerBoundMetersPerSecond], and at least the pause or stop
  /// leaving speed.
  static bool dopplerLeaves({
    required double? speed,
    required double? speedAccuracy,
    required bool stop,
  }) {
    if (!KinematicPolicy.isUsable(
      KinematicPolicy.classify(speed: speed, speedAccuracy: speedAccuracy),
    )) {
      return false;
    }
    return speed! - 2 * speedAccuracy! >= leavingLowerBoundMetersPerSecond &&
        speed >=
            (stop
                ? stopLeavingSpeedMetersPerSecond
                : pauseLeavingSpeedMetersPerSecond);
  }

  /// Whether the activity and progress exits are blocked: by a fix whose
  /// precise Doppler speed shows the device still
  /// ([StopSitePolicy.dopplerShowsStillness]; moving readings arrive late),
  /// or by a fresh confident still reading [reading] with a Doppler speed
  /// that doesn't contradict it.
  static bool stillBlocks({
    required ActivitySnapshot? reading,
    required DateTime capturedAt,
    required double? speed,
    required double? speedAccuracy,
  }) {
    if (StopSitePolicy.dopplerShowsStillness(
      speed: speed,
      speedAccuracy: speedAccuracy,
    )) {
      return true;
    }
    final recordedAt = reading?.recordedAt;
    if (reading == null ||
        recordedAt == null ||
        reading.type != TrackingActivityType.stationary ||
        reading.confidence < blockerStillConfidence ||
        capturedAt.difference(recordedAt) > blockerStillFreshness) {
      return false;
    }
    final placeholder = speed != null &&
        speedAccuracy != null &&
        speed < KinematicPolicy.zeroPlaceholderSpeed &&
        speedAccuracy >= KinematicPolicy.preciseSpeedAccuracy;
    return speed == null ||
        placeholder ||
        speed <= blockerMaximumSpeedMetersPerSecond;
  }
}

/// Centre of a stop and the uncertainty of that centre.
final class StopSiteAnchor {
  const StopSiteAnchor({
    required this.latitude,
    required this.longitude,
    required this.sigmaMeters,
  });

  final double latitude;
  final double longitude;

  /// Per-axis standard deviation of the centre, for the hold radius.
  final double sigmaMeters;
}

/// One fix of a [DwellRun].
final class DwellFix {
  const DwellFix({
    required this.latitude,
    required this.longitude,
    required this.sigmaMeters,
    required this.capturedAt,
  });

  final double latitude;
  final double longitude;
  final double sigmaMeters;
  final DateTime capturedAt;
}

/// The newest run of fixes that stay within the hold radius of their median,
/// fed in capture order. A dwell is current once the run spans
/// [StopSitePolicy.dwellMinimumDuration] without net progress.
final class DwellRun {
  final List<DwellFix> _fixes = <DwellFix>[];

  /// Fixes in the run, oldest first.
  List<DwellFix> get fixes => List<DwellFix>.unmodifiable(_fixes);

  void reset() => _fixes.clear();

  /// Adds [fix] and drops the oldest fixes until the run is confined again.
  void add(DwellFix fix) {
    _fixes.add(fix);
    while (_fixes.length > StopSitePolicy.maximumDwellRunFixes) {
      _fixes.removeAt(0);
    }
    while (_fixes.length > 1 && !_confined()) {
      _fixes.removeAt(0);
    }
  }

  /// Drops fixes captured at or before [at], such as those before the latest
  /// moving evidence.
  void dropThrough(DateTime at) =>
      _fixes.removeWhere((fix) => !fix.capturedAt.isAfter(at));

  /// The stop centre when the run is a dwell, otherwise null.
  StopSiteAnchor? dwellAnchor() {
    if (_fixes.length < 2) return null;
    final span = _fixes.last.capturedAt.difference(_fixes.first.capturedAt);
    if (span < StopSitePolicy.dwellMinimumDuration) return null;
    if (progressSpeedMetersPerSecond(_fixes) >
        StopSitePolicy.dwellMaximumTrendSpeedMetersPerSecond) {
      return null;
    }
    return centreOf(_fixes);
  }

  bool _confined() {
    final centre = centreOf(_fixes);
    return _fixes.every(
      (fix) =>
          TrackGeodesy.sphericalHaversineMeters(
            centre.latitude,
            centre.longitude,
            fix.latitude,
            fix.longitude,
          ) <=
          MotionPolicyV2.holdRadiusMeters(
            anchorSigmaMeters: centre.sigmaMeters,
            fixSigmaMeters: fix.sigmaMeters,
          ),
    );
  }

  /// Component-wise median position and median uncertainty of [fixes].
  static StopSiteAnchor centreOf(List<DwellFix> fixes) => StopSiteAnchor(
        latitude: _median(fixes.map((fix) => fix.latitude)),
        longitude: _median(fixes.map((fix) => fix.longitude)),
        sigmaMeters: _median(fixes.map((fix) => fix.sigmaMeters)),
      );

  /// Least-squares velocity of [fixes] in metres per second, in a local
  /// tangent plane at the first fix.
  static double trendSpeedMetersPerSecond(List<DwellFix> fixes) =>
      _Trend.of(fixes)?.speed ?? 0;

  /// Net progress of [fixes] in metres per second: their least-squares
  /// velocity less twice its standard error, never negative. The error comes
  /// from the fit's residuals, and is at least what the fixes' own
  /// uncertainty allows.
  static double progressSpeedMetersPerSecond(List<DwellFix> fixes) {
    final trend = _Trend.of(fixes);
    if (trend == null) return 0;
    final sigma = _median(fixes.map((fix) => fix.sigmaMeters));
    final residualVariance = fixes.length > 2
        ? trend.residualSumOfSquares / (2 * (fixes.length - 2))
        : 0.0;
    final variance = math.max(residualVariance, sigma * sigma);
    final standardError = math.sqrt(variance / trend.timeSumOfSquares);
    return math.max(0, trend.speed - 2 * standardError);
  }

  static double _median(Iterable<double> values) {
    final sorted = values.toList()..sort();
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2;
  }
}

/// Least-squares line through fixes in a local tangent plane at the first.
final class _Trend {
  const _Trend({
    required this.speed,
    required this.residualSumOfSquares,
    required this.timeSumOfSquares,
  });

  final double speed;
  final double residualSumOfSquares;
  final double timeSumOfSquares;

  static _Trend? of(List<DwellFix> fixes) {
    if (fixes.length < 2) return null;
    final origin = fixes.first;
    const metersPerDegree = TrackGeodesy.meanEarthRadiusMeters * math.pi / 180;
    final cosine = math.cos(origin.latitude * math.pi / 180);
    final times = <double>[];
    final easts = <double>[];
    final norths = <double>[];
    for (final fix in fixes) {
      times.add(
        fix.capturedAt.difference(origin.capturedAt).inMilliseconds / 1000,
      );
      easts.add(
        TrackGeodesy.longitudeDelta(origin.longitude, fix.longitude) *
            metersPerDegree *
            cosine,
      );
      norths.add((fix.latitude - origin.latitude) * metersPerDegree);
    }
    double mean(List<double> values) =>
        values.reduce((a, b) => a + b) / values.length;
    final meanTime = mean(times);
    final meanEast = mean(easts);
    final meanNorth = mean(norths);
    var timeSumOfSquares = 0.0;
    var east = 0.0;
    var north = 0.0;
    for (var index = 0; index < fixes.length; index += 1) {
      final dt = times[index] - meanTime;
      timeSumOfSquares += dt * dt;
      east += dt * (easts[index] - meanEast);
      north += dt * (norths[index] - meanNorth);
    }
    if (timeSumOfSquares <= 0) return null;
    final eastVelocity = east / timeSumOfSquares;
    final northVelocity = north / timeSumOfSquares;
    var residualSumOfSquares = 0.0;
    for (var index = 0; index < fixes.length; index += 1) {
      final dt = times[index] - meanTime;
      final eastResidual = easts[index] - meanEast - eastVelocity * dt;
      final northResidual = norths[index] - meanNorth - northVelocity * dt;
      residualSumOfSquares +=
          eastResidual * eastResidual + northResidual * northResidual;
    }
    return _Trend(
      speed: math.sqrt(
        eastVelocity * eastVelocity + northVelocity * northVelocity,
      ),
      residualSumOfSquares: residualSumOfSquares,
      timeSumOfSquares: timeSumOfSquares,
    );
  }
}
