import 'dart:math' as math;

import 'activity_snapshot.dart';
import 'uncertainty_model.dart';

/// Constants and pure rules of motion policy 2.
///
/// Shared by `MotionGate`, the canonical stop hold (quality policy 2) and
/// derived stop cleaning. The Kotlin and Swift state machines mirror them;
/// `test/fixtures/cross_language/motion_policy_v2.json` keeps all three in
/// step.
///
/// A still episode starts with confident still evidence and survives unknown,
/// tilting, low-confidence and missing activity readings: Google pauses
/// Activity Recognition while a device stays still, and indoor phones report
/// tilting and unknown while they sit in a pocket. It ends on positive moving
/// evidence, a valid Doppler speed, or sustained displacement.
abstract final class MotionPolicyV2 {
  /// Source of Android Activity Transition API events.
  static const transitionSource = 'android_activity_transition';

  /// Source of iOS Core Motion activity, which reports changes only.
  static const coreMotionSource = 'ios_core_motion_activity';

  /// Confident still evidence must stand this long, with no positive moving
  /// evidence, before a still episode is current. A still transition starts an
  /// episode at once.
  static const stillEpisodeMinimumSpan = Duration(seconds: 30);

  /// Consecutive periodic moving readings that end a still episode.
  static const movingConfirmationReadings = 2;

  /// Confidence an in-vehicle reading needs to count as moving evidence.
  /// Seated phones report spurious low-confidence vehicle readings.
  static const vehicleConfidenceThreshold = 75;

  /// Core Motion high confidence, which ends a still episode at once.
  static const coreMotionHighConfidence = 100;

  /// How long a medium-confidence Core Motion moving reading must stay
  /// current before it ends a still episode.
  static const coreMotionMediumPersistence = Duration(seconds: 10);

  /// Floor of the stop-hold radius in metres.
  static const holdRadiusFloorMeters = 25.0;

  /// Two-dimensional chi-square value at 99 %.
  static const holdChiSquare = 9.21;

  /// Doppler speed that confirms a departure, in metres per second.
  static const departureSpeedMetersPerSecond = 1.2;

  /// A confirming Doppler speed must also exceed this many speed accuracies.
  static const departureSpeedAccuracyFactor = 2.0;

  /// How long fixes must stay outside the hold radius before position alone
  /// confirms a departure. Shorter windows let GNSS re-acquisition bursts
  /// after a long stop pass as departures.
  static const sustainedOutsideDuration = Duration(seconds: 60);

  /// A position-confirmed departure must be at least this many hold radii from
  /// the anchor and the farthest fix of its outside run.
  static const sustainedOutsideRadiusFactor = 2.0;

  /// Native entry: floor of the per-fix consistency radius in metres.
  static const entryConsistencyFloorMeters = 25.0;

  /// Native entry: per-fix consistency radius in standard deviations.
  static const entryConsistencySigmaFactor = 3.0;

  /// Native entry when the provider delivers no fix during the episode.
  static const entryWithoutFixes = Duration(seconds: 180);

  /// Whether [activity] is an Android ENTER STILL transition.
  static bool isStillTransitionEnter(ActivitySnapshot activity) =>
      activity.source == transitionSource &&
      activity.type == TrackingActivityType.stationary &&
      activity.confidence >= 100;

  /// Whether [activity] is an Android EXIT STILL transition, which native
  /// code reports with confidence 0.
  static bool isStillTransitionExit(ActivitySnapshot activity) =>
      activity.source == transitionSource &&
      activity.type == TrackingActivityType.stationary &&
      activity.confidence <= 0;

  /// Whether [activity] is an Android ENTER transition into a moving activity.
  static bool isMovingTransitionEnter(ActivitySnapshot activity) =>
      activity.source == transitionSource &&
      activity.type.indicatesMovement &&
      activity.confidence >= 100;

  /// Whether a non-transition reading counts toward moving confirmation.
  static bool isMovingReading(
    ActivitySnapshot activity, {
    required int movingConfidenceThreshold,
  }) {
    if (activity.source == transitionSource) return false;
    if (!activity.type.indicatesMovement) return false;
    final threshold = activity.type == TrackingActivityType.inVehicle
        ? math.max(movingConfidenceThreshold, vehicleConfidenceThreshold)
        : movingConfidenceThreshold;
    return activity.confidence >= threshold;
  }

  /// Whether a non-transition reading is confident still evidence.
  static bool isConfidentStill(
    ActivitySnapshot activity, {
    required int stationaryConfidenceThreshold,
  }) =>
      activity.source != transitionSource &&
      activity.type == TrackingActivityType.stationary &&
      activity.confidence >= stationaryConfidenceThreshold;

  /// Per-axis standard deviation used by the hold radius.
  ///
  /// Missing or invalid accuracy falls back to [fallbackAccuracyMeters], the
  /// route's acceptance limit, so unknown uncertainty widens the hold.
  static double sigmaMeters({
    required double? horizontalAccuracy,
    required bool hasSpeedAccuracy,
    required bool hasVerticalAccuracy,
    required double fallbackAccuracyMeters,
    bool? producedByAccessory,
  }) {
    final origin = UncertaintyModel.inferOriginFromEvidence(
      horizontalAccuracy: horizontalAccuracy,
      hasSpeedAccuracy: hasSpeedAccuracy,
      hasVerticalAccuracy: hasVerticalAccuracy,
      producedByAccessory: producedByAccessory,
    );
    return UncertaintyModel.horizontalSigmaMeters(horizontalAccuracy, origin) ??
        UncertaintyModel.horizontalSigmaMeters(
          fallbackAccuracyMeters,
          FixOriginClass.unknown,
        )!;
  }

  /// Radius around the stop anchor inside which a fix is held, in metres.
  static double holdRadiusMeters({
    required double anchorSigmaMeters,
    required double fixSigmaMeters,
  }) =>
      math.max(
        holdRadiusFloorMeters,
        math.sqrt(
          holdChiSquare *
              (anchorSigmaMeters * anchorSigmaMeters +
                  fixSigmaMeters * fixSigmaMeters),
        ),
      );

  /// Whether a reported Doppler speed confirms that the device is moving.
  ///
  /// Indoors the speed accuracy is often several metres per second, so a
  /// near-zero speed proves nothing; only a clearly measured speed counts.
  static bool dopplerConfirmsDeparture({
    required double? speed,
    required double? speedAccuracy,
  }) {
    if (speed == null || speedAccuracy == null) return false;
    if (!speed.isFinite || !speedAccuracy.isFinite || speedAccuracy < 0) {
      return false;
    }
    return speed >=
        math.max(
          departureSpeedMetersPerSecond,
          departureSpeedAccuracyFactor * speedAccuracy,
        );
  }
}
