import 'dart:math' as math;

import 'fix_quality.dart';
import 'kinematic_policy.dart';
import 'track_point.dart';

/// One rejected fix of a rejected-fix run.
final class QualityRunFix {
  const QualityRunFix({
    required this.sequence,
    required this.capturedAt,
    required this.qualityFlags,
    this.horizontalAccuracy,
    this.speed,
    this.speedAccuracy,
    this.rejectionReason,
  });

  final int sequence;
  final DateTime capturedAt;
  final int qualityFlags;
  final double? horizontalAccuracy;
  final double? speed;
  final double? speedAccuracy;
  final String? rejectionReason;
}

/// When a stop lasted, for deciding whether poor fixes were at its place.
final class QualityRunStopWindow {
  const QualityRunStopWindow({required this.startedAt, required this.endedAt});

  final DateTime startedAt;

  /// The stop's end, or its last held fix while it is current.
  final DateTime endedAt;
}

/// How a rejected-fix run between two accepted fixes is recorded.
final class QualityRunVerdict {
  const QualityRunVerdict({
    required this.visible,
    required this.stopEvidence,
    required this.duration,
    required this.thresholdReason,
    this.maximumUncertaintyMeters,
    this.medianUncertaintyMeters,
  });

  /// Whether the run left a visible hole in the route (`visibleGap`) rather
  /// than being informational.
  final bool visible;

  /// Whether every rejection was expected stop evidence.
  final bool stopEvidence;
  final Duration duration;
  final String thresholdReason;
  final double? maximumUncertaintyMeters;
  final double? medianUncertaintyMeters;
}

/// Decides how a rejected-fix run is recorded, the same way for a live route
/// and for a review of a recorded one.
abstract final class QualityRunRules {
  /// A rejected fix moving at least this fast was travelling, not at a stop.
  static const double stopTravelSpeedMetersPerSecond = 3.0;

  /// Poor fixes this long before a stop began arrived at its place.
  static const stopArrivalAllowance = Duration(minutes: 5);

  static const Set<String> _stopHoldReasons = <String>{
    FixQualityIssue.stationaryHold,
    FixQualityIssue.stationaryOutlier,
  };

  /// Whether [fix] is expected stop evidence rather than a quality problem.
  static bool isStopEvidence(QualityRunFix fix) =>
      _stopHoldReasons.contains(fix.rejectionReason) ||
      fix.qualityFlags & TrackPointQualityFlag.duringStop != 0;

  /// Whether [fix] shows travel. From quality policy 5 only a usable Doppler
  /// speed does: a chipset's 3.6 ± 7 m/s proves nothing.
  static bool showsTravel(QualityRunFix fix, int policyVersion) {
    final speed = fix.speed;
    if (speed == null || speed < stopTravelSpeedMetersPerSecond) return false;
    if (policyVersion < 5) return true;
    return KinematicPolicy.isUsable(
      KinematicPolicy.classify(speed: speed, speedAccuracy: fix.speedAccuracy),
    );
  }

  /// The verdict for [rows], the rejected fixes of one run in sequence order,
  /// given the [stops] recorded so far.
  static QualityRunVerdict decide({
    required List<QualityRunFix> rows,
    required List<QualityRunStopWindow> stops,
    required double maximumAcceptedAccuracyMeters,
    required int policyVersion,
  }) {
    final accuracy = rows
        .map((row) => row.horizontalAccuracy)
        .whereType<double>()
        .where((value) => value.isFinite && value >= 0)
        .toList()
      ..sort();
    final duration = rows.last.capturedAt.difference(rows.first.capturedAt);
    final maximum = accuracy.isEmpty ? null : accuracy.last;
    final median = accuracy.isEmpty
        ? null
        : accuracy.length.isOdd
            ? accuracy[accuracy.length ~/ 2]
            : (accuracy[accuracy.length ~/ 2 - 1] +
                    accuracy[accuracy.length ~/ 2]) /
                2;
    // Fixes the stop hold kept out of a still device's geometry, and any other
    // rejection while a quality-policy-3 stop was current, are expected stop
    // evidence, not a quality gap; only the remaining rejections decide
    // whether the run is visible.
    final qualityRows = rows.where((row) => !isStopEvidence(row)).toList();
    final qualityAccuracy = qualityRows
        .map((row) => row.horizontalAccuracy)
        .whereType<double>()
        .where((value) => value.isFinite && value >= 0);
    final qualityMaximum =
        qualityAccuracy.isEmpty ? null : qualityAccuracy.reduce(math.max);
    final qualityDuration = qualityRows.isEmpty
        ? Duration.zero
        : qualityRows.last.capturedAt.difference(qualityRows.first.capturedAt);
    var visible = qualityRows.length >= 3 ||
        qualityDuration >= const Duration(seconds: 30) ||
        (qualityMaximum != null &&
            qualityMaximum > maximumAcceptedAccuracyMeters * 1.5);
    // Quality policy 3 and later: one dropped fix is not a hole in the
    // route, and poor fixes while the device was at a place are stop
    // evidence.
    if (visible && policyVersion >= 3) {
      visible = qualityRows.length >= 2 &&
          !atRecordedStop(qualityRows, stops, policyVersion);
    }
    final reasons = rows
        .map((row) => row.rejectionReason)
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();
    return QualityRunVerdict(
      visible: visible,
      stopEvidence: qualityRows.isEmpty,
      duration: duration.isNegative ? Duration.zero : duration,
      thresholdReason: reasons.isEmpty ? 'rejected_fix_run' : reasons.join(','),
      maximumUncertaintyMeters: maximum,
      medianUncertaintyMeters: median,
    );
  }

  /// Rejections that don't show travel, within [stopArrivalAllowance] before
  /// one of [stops] or during it.
  static bool atRecordedStop(
    List<QualityRunFix> rows,
    List<QualityRunStopWindow> stops,
    int policyVersion,
  ) {
    if (rows.any((row) => showsTravel(row, policyVersion))) return false;
    final firstAt = rows.first.capturedAt;
    final lastAt = rows.last.capturedAt;
    for (final stop in stops) {
      final from = stop.startedAt.subtract(stopArrivalAllowance);
      if (!lastAt.isBefore(from) && !firstAt.isAfter(stop.endedAt)) {
        return true;
      }
    }
    return false;
  }

  /// Rule `Q1` of quality policy 5: whether a visible run of [rows] ending
  /// within [stopArrivalAllowance] before a stop that opens becomes
  /// informational: when none of its quality rows shows travel.
  static bool downgradedByStop(List<QualityRunFix> rows) => !rows.any(
        (row) => !isStopEvidence(row) && showsTravel(row, 5),
      );
}
