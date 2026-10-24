import 'derived_geometry.dart';
import 'quality_run_rules.dart';
import 'track_point.dart';
import 'track_stop.dart';
import 'tracking_continuity.dart';

/// A completed route recorded under quality policy 4 or earlier, decided
/// again from its stored fixes under the current rules.
///
/// Nothing a route recorded is changed: its points, their acceptance and its
/// measured distance stay as stored. A review is a separate, versioned layer
/// (route database schema 18) that the route's totals and stops read while it
/// is current, and that deleting it removes.
final class RouteReview {
  const RouteReview({
    required this.trackId,
    required this.sourceMaximumSequence,
    required this.keptPoints,
    required this.stops,
    required this.qualityRuns,
    required this.gaps,
    required this.correctedDistanceMeters,
    required this.stepGenerations,
  });

  /// Version of the review rules: quality policy 5, continuity policy 4 and
  /// step rule 1. A higher version reviews routes again.
  static const int version = 1;

  /// Derived-geometry algorithm of a review's run.
  static const algorithm = DerivedGeometryAlgorithm.routeQualityReview;

  /// Quality policy a review decides fixes under.
  static const int qualityPolicyVersion = 5;

  /// Continuity policy a review classifies gaps under.
  static const int continuityPolicyVersion = 4;

  /// Rejection reason of a fix the review does not keep, in a view of the
  /// reviewed route.
  static const notKeptReason = 'not_kept_by_review';

  final String trackId;

  /// Newest point sequence the review covered.
  final int sourceMaximumSequence;

  /// The fixes the current rules keep, at their raw coordinates.
  final List<TrackPoint> keptPoints;

  /// Stops of the reviewed route, one per visit, all closed.
  final List<TrackStop> stops;
  final List<ReviewedQualityRun> qualityRuns;
  final List<ReviewedGap> gaps;

  /// Measured length of [keptPoints] within segments.
  final double correctedDistanceMeters;
  final List<ReviewedStepGeneration> stepGenerations;

  /// When the first capture generation's step counter stopped counting while
  /// the device was still walking; null when every count is complete.
  DateTime? get stepCountStoppedAt {
    DateTime? earliest;
    for (final generation in stepGenerations) {
      final stoppedAt = generation.stoppedAt;
      if (stoppedAt == null) continue;
      if (earliest == null || stoppedAt.isBefore(earliest)) {
        earliest = stoppedAt;
      }
    }
    return earliest;
  }
}

/// A rejected-fix run of a reviewed route.
final class ReviewedQualityRun {
  const ReviewedQualityRun({
    required this.firstRawSequence,
    required this.lastRawSequence,
    required this.rejectedCount,
    required this.beforePointId,
    required this.afterPointId,
    required this.verdict,
    required this.visible,
  });

  final int firstRawSequence;
  final int lastRawSequence;
  final int rejectedCount;
  final String beforePointId;
  final String afterPointId;
  final QualityRunVerdict verdict;

  /// Whether the run counts as a quality event: [verdict] as decided, unless
  /// a stop that opened soon after it made it informational (rule `Q1`).
  final bool visible;
}

/// A continuity gap of a reviewed route.
final class ReviewedGap {
  const ReviewedGap({
    required this.beforePointId,
    required this.afterPointId,
    required this.beforeSegmentId,
    required this.afterSegmentId,
    required this.decision,
    required this.visible,
    this.providerGap,
    this.rawReceiptGap,
    this.straightLineDistanceMeters,
    this.nativeCaptureGeneration,
    this.configurationEpochId,
  });

  final String beforePointId;
  final String afterPointId;
  final String beforeSegmentId;
  final String afterSegmentId;
  final TrackingContinuityDecision decision;
  final bool visible;
  final Duration? providerGap;
  final Duration? rawReceiptGap;
  final double? straightLineDistanceMeters;
  final String? nativeCaptureGeneration;
  final String? configurationEpochId;
}

/// Step counting of one capture generation of a reviewed route.
final class ReviewedStepGeneration {
  const ReviewedStepGeneration({
    required this.captureGenerationId,
    required this.stepCount,
    this.segmentId,
    this.lastRiseAt,
    this.stoppedAt,
  });

  final String captureGenerationId;
  final String? segmentId;

  /// The generation's final cumulative count.
  final int stepCount;

  /// When the count last increased.
  final DateTime? lastRiseAt;

  /// When the counter stopped counting although the device kept walking
  /// (step rule 1); null when the count is complete.
  final DateTime? stoppedAt;
}
