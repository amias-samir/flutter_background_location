import 'dart:math' as math;

import 'activity_snapshot.dart';
import 'location_sample.dart';
import 'motion_policy.dart';
import 'stop_site.dart';
import 'track_point.dart';
import 'tracking_config.dart';
import 'tracking_configuration_epoch.dart';
import 'track_geodesy.dart';

/// Stable issue codes emitted by the canonical fix-quality policy.
abstract final class FixQualityIssue {
  static const invalidCoordinate = 'invalid_coordinate';
  static const missingAccuracy = 'missing_horizontal_accuracy';
  static const nonFiniteAccuracy = 'non_finite_horizontal_accuracy';
  static const negativeAccuracy = 'negative_horizontal_accuracy';
  static const zeroAccuracy = 'zero_horizontal_accuracy';
  static const aboveAccuracyLimit = 'horizontal_accuracy_above_limit';
  static const staleTimestamp = 'stale_provider_timestamp';
  static const futureTimestamp = 'future_provider_timestamp';
  static const nonMonotonicTimestamp = 'non_monotonic_provider_timestamp';
  static const implausibleSpeed = 'implausible_speed';
  static const largeGap = 'large_callback_gap';
  static const mockDetected = 'mock_detected';
  static const mockUnavailable = 'mock_evidence_unavailable';
  static const providerUnavailable = 'provider_evidence_unavailable';

  /// Quality policies 2 and 3: inside the hold radius of the stop anchor while
  /// a stop is current. Also the rejection reason.
  static const stationaryHold = 'stationary_hold';

  /// Quality policies 2 and 3: outside the hold radius while a stop is
  /// current, with no confirmed departure yet. Also the rejection reason.
  static const stationaryOutlier = 'stationary_outlier';
}

/// Stop-hold state for one fix under quality policies 2 and 3.
///
/// The tracking client derives it from its motion state; the policy stays
/// pure. Under quality policy 1, and for capture intents other than adaptive,
/// it is ignored.
final class StopContext {
  const StopContext({
    required this.stillEpisodeActive,
    this.outsideRunStartedAt,
    this.outsideRunFarthestMeters = 0,
    this.site,
    this.outsideRunCount = 0,
    this.movingEvidenceCurrent = false,
    this.stopRecognized = true,
    this.recentMovingReading = false,
  });

  /// Whether a motion-policy-2 still episode is current for this fix.
  final bool stillEpisodeActive;

  /// Capture time of the first fix of the current run outside the hold
  /// radius, if one is in progress.
  final DateTime? outsideRunStartedAt;

  /// Largest anchor distance among the fixes of that run, in metres.
  final double outsideRunFarthestMeters;

  /// Quality policy 3: centre of the current stop, or null when no stop is
  /// current. Quality policy 2 anchors on the previous accepted point instead.
  final StopSiteAnchor? site;

  /// Quality policy 3: number of fixes in the current outside run.
  final int outsideRunCount;

  /// Quality policy 3: whether moving evidence is recent enough to confirm a
  /// departure on the second consecutive fix outside the hold radius.
  final bool movingEvidenceCurrent;

  /// Quality policy 3: whether the stay at [site] is a stop. While it is not
  /// yet one, a pause, a moving fix ends it at once.
  final bool stopRecognized;

  /// Quality policy 3: whether a moving reading arrived within
  /// [StopSitePolicy.quietWindow] before this fix.
  final bool recentMovingReading;
}

/// Versioned canonical decision for one raw native fix.
final class FixQualityDecision {
  FixQualityDecision({
    required this.acceptedForGeometry,
    required this.acceptedForMotionEvidence,
    required Iterable<String> issues,
    required this.policyVersion,
    required this.qualityFlags,
    this.rejectionReason,
  }) : issues = List<String>.unmodifiable(issues);

  final bool acceptedForGeometry;
  final bool acceptedForMotionEvidence;
  final List<String> issues;
  final int policyVersion;
  final int qualityFlags;
  final String? rejectionReason;
}

/// Pure evaluator used as the canonical geometry acceptance policy.
final class FixQualityPolicy {
  /// Evaluates fixes under quality policy [version], normally the version
  /// recorded by the route's active configuration epoch.
  const FixQualityPolicy(
    this.config, {
    this.version = TrackingPolicyVersions.qualityPolicy,
  });

  final TrackingConfig config;

  /// Requested policy version. Decisions report the version actually applied
  /// by [TrackingPolicyVersions.resolveQualityPolicy].
  final int version;

  /// Evaluates [sample] against [previous], the last accepted point of the
  /// current segment.
  ///
  /// [stop] carries the stop-hold state used by quality policy 2.
  FixQualityDecision evaluate({
    required LocationSample sample,
    required TrackPoint? previous,
    required DateTime now,
    StopContext? stop,
  }) {
    final applied = TrackingPolicyVersions.resolveQualityPolicy(version);
    return switch (applied) {
      1 => _evaluateVersion1(sample: sample, previous: previous, now: now),
      2 => _evaluateVersion2(
          sample: sample,
          previous: previous,
          now: now,
          stop: stop,
        ),
      3 => _evaluateVersion3(
          sample: sample,
          previous: previous,
          now: now,
          stop: stop,
        ),
      4 => _evaluateVersion3(
          sample: sample,
          previous: previous,
          now: now,
          stop: stop,
          appliedVersion: 4,
          maximumAccuracyMeters: _ridingAccuracyLimit(sample),
        ),
      _ => throw StateError('Quality policy $applied has no evaluator.'),
    };
  }

  /// Quality policy 4: a riding fix of an adaptive route is accepted up to
  /// the vehicle accuracy envelope.
  ///
  /// A phone in a rider's pocket is shielded by the body: on a motorbike its
  /// fixes often report 20 to 35 m where a phone with a sky view reports a
  /// few metres, and rejecting them cuts the route across bends. A fix is
  /// riding when its Doppler speed is at least [ridingSpeedMetersPerSecond],
  /// or at least [slowRidingSpeedMetersPerSecond] with a fresh in-vehicle or
  /// on-bicycle reading at the moving threshold. A host limit other than the
  /// preset's still applies.
  static const double ridingSpeedMetersPerSecond = 5;

  /// See [ridingSpeedMetersPerSecond].
  static const double slowRidingSpeedMetersPerSecond = 2;

  double _ridingAccuracyLimit(LocationSample sample) {
    final limit = config.maximumAcceptedAccuracyMeters;
    if (config.captureIntent != RouteCaptureIntent.adaptive ||
        limit !=
            TrackingConfig.defaultMaximumAcceptedAccuracyMeters(
              config.accuracy,
              config.captureIntent,
            )) {
      return limit;
    }
    final speed = sample.speed;
    if (speed == null || !speed.isFinite) return limit;
    final reading = sample.capturedActivity;
    final ridingReading = reading != null &&
        reading.evidenceState == ActivityEvidenceState.fresh &&
        (reading.type == TrackingActivityType.inVehicle ||
            reading.type == TrackingActivityType.onBicycle) &&
        reading.confidence >= config.movingConfidenceThreshold;
    final riding = speed >= ridingSpeedMetersPerSecond ||
        (speed >= slowRidingSpeedMetersPerSecond && ridingReading);
    if (!riding) return limit;
    return math.max(
      limit,
      TrackingConfig.defaultMaximumAcceptedAccuracyMeters(
        config.accuracy,
        RouteCaptureIntent.vehicle,
      ),
    );
  }

  /// Version 1 plus stays at a place, for adaptive capture.
  ///
  /// While [StopContext.site] is current and its stay is a pause
  /// ([StopContext.stopRecognized] false), a moving fix is accepted and ends
  /// the pause; a quiet fix is held inside the hold radius and is an outlier
  /// outside it unless it departs for good.
  ///
  /// Once the stay is a stop, a fix that version 1 would accept is held when
  /// it lies inside the hold radius around the stop centre, whatever the
  /// activity: walking inside a place is part of the stop. A fix outside the
  /// radius is accepted as the departure when its Doppler speed is clearly
  /// measured, when moving evidence is current and it is the second
  /// consecutive outside fix, or when fixes stay outside for
  /// [MotionPolicyV2.sustainedOutsideDuration] while moving farther away;
  /// otherwise it is an outlier. Every rejection during a stay carries
  /// [TrackPointQualityFlag.duringStop].
  FixQualityDecision _evaluateVersion3({
    required LocationSample sample,
    required TrackPoint? previous,
    required DateTime now,
    required StopContext? stop,
    int appliedVersion = 3,
    double? maximumAccuracyMeters,
  }) {
    final decision = _evaluateVersion1(
      sample: sample,
      previous: previous,
      now: now,
      appliedVersion: appliedVersion,
      maximumAccuracyMeters: maximumAccuracyMeters,
    );
    final site = stop?.site;
    if (stop == null ||
        site == null ||
        config.captureIntent != RouteCaptureIntent.adaptive) {
      return decision;
    }
    if (!decision.acceptedForGeometry) {
      return FixQualityDecision(
        acceptedForGeometry: false,
        acceptedForMotionEvidence: false,
        issues: decision.issues,
        policyVersion: decision.policyVersion,
        qualityFlags: decision.qualityFlags | TrackPointQualityFlag.duringStop,
        rejectionReason: decision.rejectionReason,
      );
    }
    final distance = _distanceMeters(
      site.latitude,
      site.longitude,
      sample.latitude,
      sample.longitude,
    );
    final radius = MotionPolicyV2.holdRadiusMeters(
      anchorSigmaMeters: site.sigmaMeters,
      fixSigmaMeters: MotionPolicyV2.sigmaMeters(
        horizontalAccuracy: sample.horizontalAccuracy,
        hasSpeedAccuracy: sample.speedAccuracy != null,
        hasVerticalAccuracy: sample.verticalAccuracy != null,
        fallbackAccuracyMeters: config.maximumAcceptedAccuracyMeters,
        producedByAccessory: sample.isProducedByAccessory,
      ),
    );
    if (!stop.stopRecognized &&
        (stop.recentMovingReading ||
            StopSitePolicy.showsMovement(
              speed: sample.speed,
              speedAccuracy: sample.speedAccuracy,
            ))) {
      // A pause ends at the first moving fix: the route continues at once.
      return decision;
    }
    if (distance <= radius) {
      return _held(
        decision,
        FixQualityIssue.stationaryHold,
        flags: TrackPointQualityFlag.duringStop,
      );
    }
    if (MotionPolicyV2.dopplerConfirmsDeparture(
      speed: sample.speed,
      speedAccuracy: sample.speedAccuracy,
    )) {
      return decision;
    }
    if (stop.stopRecognized &&
        stop.movingEvidenceCurrent &&
        stop.outsideRunCount >= 1) {
      return decision;
    }
    final runStartedAt = stop.outsideRunStartedAt ?? sample.capturedAt;
    final sustained = sample.capturedAt.difference(runStartedAt) >=
            MotionPolicyV2.sustainedOutsideDuration &&
        distance >= stop.outsideRunFarthestMeters &&
        distance >= MotionPolicyV2.sustainedOutsideRadiusFactor * radius;
    return sustained
        ? decision
        : _held(
            decision,
            FixQualityIssue.stationaryOutlier,
            flags: TrackPointQualityFlag.duringStop,
          );
  }

  /// Version 1 plus the canonical stop hold for adaptive capture.
  ///
  /// While a still episode is current, a fix that version 1 would accept is
  /// held when it lies inside the hold radius around [previous], the stop
  /// anchor, and rejected as an outlier when it lies outside without a
  /// confirmed departure. A departure is confirmed by a clearly measured
  /// Doppler speed, or by fixes that stay outside for
  /// [MotionPolicyV2.sustainedOutsideDuration] while moving farther away.
  /// Positive moving activity ends the episode before the fix is evaluated.
  /// Held and outlier fixes stay stored as rejected evidence; the anchor to
  /// departure chord counts as measured distance.
  FixQualityDecision _evaluateVersion2({
    required LocationSample sample,
    required TrackPoint? previous,
    required DateTime now,
    required StopContext? stop,
  }) {
    final decision = _evaluateVersion1(
      sample: sample,
      previous: previous,
      now: now,
      appliedVersion: 2,
    );
    if (!decision.acceptedForGeometry ||
        previous == null ||
        stop == null ||
        !stop.stillEpisodeActive ||
        config.captureIntent != RouteCaptureIntent.adaptive) {
      return decision;
    }
    final distance = _distanceMeters(
      previous.latitude,
      previous.longitude,
      sample.latitude,
      sample.longitude,
    );
    final radius = MotionPolicyV2.holdRadiusMeters(
      anchorSigmaMeters: MotionPolicyV2.sigmaMeters(
        horizontalAccuracy: previous.horizontalAccuracy,
        hasSpeedAccuracy: previous.speedAccuracy != null,
        hasVerticalAccuracy: previous.verticalAccuracy != null,
        fallbackAccuracyMeters: config.maximumAcceptedAccuracyMeters,
      ),
      fixSigmaMeters: MotionPolicyV2.sigmaMeters(
        horizontalAccuracy: sample.horizontalAccuracy,
        hasSpeedAccuracy: sample.speedAccuracy != null,
        hasVerticalAccuracy: sample.verticalAccuracy != null,
        fallbackAccuracyMeters: config.maximumAcceptedAccuracyMeters,
        producedByAccessory: sample.isProducedByAccessory,
      ),
    );
    if (distance <= radius) {
      return _held(decision, FixQualityIssue.stationaryHold);
    }
    if (MotionPolicyV2.dopplerConfirmsDeparture(
      speed: sample.speed,
      speedAccuracy: sample.speedAccuracy,
    )) {
      return decision;
    }
    final runStartedAt = stop.outsideRunStartedAt ?? sample.capturedAt;
    final sustained = sample.capturedAt.difference(runStartedAt) >=
            MotionPolicyV2.sustainedOutsideDuration &&
        distance >= stop.outsideRunFarthestMeters &&
        distance >= MotionPolicyV2.sustainedOutsideRadiusFactor * radius;
    return sustained
        ? decision
        : _held(decision, FixQualityIssue.stationaryOutlier);
  }

  static FixQualityDecision _held(
    FixQualityDecision decision,
    String code, {
    int flags = TrackPointQualityFlag.none,
  }) =>
      FixQualityDecision(
        acceptedForGeometry: false,
        acceptedForMotionEvidence: false,
        issues: <String>[...decision.issues, code],
        policyVersion: decision.policyVersion,
        qualityFlags: decision.qualityFlags | flags,
        rejectionReason: code,
      );

  FixQualityDecision _evaluateVersion1({
    required LocationSample sample,
    required TrackPoint? previous,
    required DateTime now,
    int appliedVersion = 1,
    double? maximumAccuracyMeters,
  }) {
    final accuracyLimit =
        maximumAccuracyMeters ?? config.maximumAcceptedAccuracyMeters;
    final issues = <String>[];
    var flags = TrackPointQualityFlag.none;
    String? rejection;
    var motionEligible = true;

    if (!sample.latitude.isFinite ||
        !sample.longitude.isFinite ||
        sample.latitude < -90 ||
        sample.latitude > 90 ||
        sample.longitude < -180 ||
        sample.longitude > 180) {
      issues.add(FixQualityIssue.invalidCoordinate);
      flags |= TrackPointQualityFlag.invalidCoordinate;
      rejection = 'invalid_coordinate';
      motionEligible = false;
    }

    final accuracy = sample.horizontalAccuracy;
    if (accuracy == null) {
      issues.add(FixQualityIssue.missingAccuracy);
      flags |= TrackPointQualityFlag.poorAccuracy;
      motionEligible = false;
    } else if (!accuracy.isFinite) {
      issues.add(FixQualityIssue.nonFiniteAccuracy);
      flags |= TrackPointQualityFlag.poorAccuracy;
      rejection ??= 'poor_accuracy';
      motionEligible = false;
    } else if (accuracy < 0) {
      issues.add(FixQualityIssue.negativeAccuracy);
      flags |= TrackPointQualityFlag.poorAccuracy;
      rejection ??= 'poor_accuracy';
      motionEligible = false;
    } else if (accuracy == 0) {
      issues.add(FixQualityIssue.zeroAccuracy);
      flags |= TrackPointQualityFlag.poorAccuracy;
      motionEligible = false;
    } else if (accuracy > accuracyLimit) {
      issues.add(FixQualityIssue.aboveAccuracyLimit);
      flags |= TrackPointQualityFlag.poorAccuracy;
      rejection ??= 'poor_accuracy';
      motionEligible = false;
    }

    final receiptDelta = sample.providerTimeDeltaMsAtReceipt;
    if (receiptDelta != null &&
        receiptDelta > config.maximumProviderFixAge.inMilliseconds) {
      issues.add(FixQualityIssue.staleTimestamp);
      flags |= TrackPointQualityFlag.staleTimestamp;
      rejection ??= 'stale_timestamp';
      motionEligible = false;
    }
    if ((receiptDelta != null &&
            receiptDelta < -const Duration(minutes: 2).inMilliseconds) ||
        sample.capturedAt.isAfter(now.add(const Duration(minutes: 2)))) {
      issues.add(FixQualityIssue.futureTimestamp);
      flags |= TrackPointQualityFlag.staleTimestamp;
      rejection ??= 'future_timestamp';
      motionEligible = false;
    }

    switch (sample.mockAssessment) {
      case MockLocationAssessment.detected:
        issues.add(FixQualityIssue.mockDetected);
        if (config.mockLocationPolicy != MockLocationPolicy.allow) {
          flags |= TrackPointQualityFlag.mockLocation;
        }
        if (config.mockLocationPolicy == MockLocationPolicy.reject) {
          rejection ??= 'mock_location_detected';
          motionEligible = false;
        }
      case MockLocationAssessment.unavailable:
        issues.add(FixQualityIssue.mockUnavailable);
      case MockLocationAssessment.notDetected:
        break;
    }
    if (sample.provider == null || sample.provider!.isEmpty) {
      issues.add(FixQualityIssue.providerUnavailable);
    }

    if (previous != null) {
      final elapsed = sample.capturedAt.difference(previous.capturedAt);
      if (elapsed <= Duration.zero) {
        issues.add(FixQualityIssue.nonMonotonicTimestamp);
        flags |= TrackPointQualityFlag.staleTimestamp;
        rejection ??= 'stale_timestamp';
        motionEligible = false;
      } else {
        if (elapsed > config.acceptedGeometryGapThreshold) {
          issues.add(FixQualityIssue.largeGap);
          flags |= TrackPointQualityFlag.largeGap;
          motionEligible = false;
        }
        final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
        final speed = _distanceMeters(
              previous.latitude,
              previous.longitude,
              sample.latitude,
              sample.longitude,
            ) /
            seconds;
        if (speed.isFinite &&
            speed > config.maximumPlausibleSpeedMetersPerSecond) {
          issues.add(FixQualityIssue.implausibleSpeed);
          flags |= TrackPointQualityFlag.implausibleSpeed;
          motionEligible = false;
        }
      }
    }

    return FixQualityDecision(
      acceptedForGeometry: rejection == null,
      acceptedForMotionEvidence: rejection == null && motionEligible,
      issues: issues,
      policyVersion: appliedVersion,
      qualityFlags: flags,
      rejectionReason: rejection,
    );
  }

  static double _distanceMeters(
    double latitude1,
    double longitude1,
    double latitude2,
    double longitude2,
  ) {
    return TrackGeodesy.sphericalHaversineMeters(
      latitude1,
      longitude1,
      latitude2,
      longitude2,
    );
  }
}
