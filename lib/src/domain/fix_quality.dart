import 'location_sample.dart';
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

  FixQualityDecision evaluate({
    required LocationSample sample,
    required TrackPoint? previous,
    required DateTime now,
  }) {
    final applied = TrackingPolicyVersions.resolveQualityPolicy(version);
    return switch (applied) {
      1 => _evaluateVersion1(sample: sample, previous: previous, now: now),
      _ => throw StateError('Quality policy $applied has no evaluator.'),
    };
  }

  FixQualityDecision _evaluateVersion1({
    required LocationSample sample,
    required TrackPoint? previous,
    required DateTime now,
  }) {
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
    } else if (accuracy > config.maximumAcceptedAccuracyMeters) {
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
      policyVersion: 1,
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
