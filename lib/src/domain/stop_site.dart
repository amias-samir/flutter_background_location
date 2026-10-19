import 'dart:math' as math;

import 'activity_snapshot.dart';
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
