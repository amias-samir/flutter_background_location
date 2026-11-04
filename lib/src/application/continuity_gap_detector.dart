import '../domain/fix_quality.dart';
import '../domain/location_sample.dart';
import '../domain/track_point.dart';
import '../domain/tracker_status.dart';
import '../domain/tracking_config.dart';
import '../domain/tracking_configuration_epoch.dart';
import '../domain/tracking_continuity.dart';

/// Detects and classifies the accepted-geometry gap a fix ends, if any.
///
/// Pure, so the live client and a review of a recorded route decide gaps the
/// same way.
abstract final class ContinuityGapDetector {
  /// The gap decision for [sample], an accepted fix of [trackId]'s segment
  /// [currentSegmentId], or null when it ends no gap worth deciding.
  ///
  /// [fallbackLifecycle] and [fallbackSamplingProfile] stand in for a sample
  /// that carries neither.
  static TrackingContinuityDecision? detect({
    required TrackingConfig config,
    required String trackId,
    required LocationSample sample,
    required FixQualityDecision quality,
    required TrackPoint? previousAccepted,
    required TrackPoint? previousRaw,
    required String currentSegmentId,
    required int continuityPolicyVersion,
    required TrackingConfigurationEpoch? policyEpoch,
    required TrackerLifecycle fallbackLifecycle,
    required SamplingProfile fallbackSamplingProfile,
    bool? stayExplainsGap,
  }) {
    if (previousAccepted == null) return null;
    // Rejected callbacks are already retained as point-quality evidence. A
    // continuity gap describes the edge to the next accepted anchor, not each
    // rejected callback itself; recording both inflated gap counts and map
    // markers without adding route information.
    if (!quality.acceptedForGeometry) return null;

    final acceptedGap = sample.capturedAt.difference(
      previousAccepted.capturedAt,
    );
    final rawReceiptGap = previousRaw?.nativeReceivedAt == null ||
            sample.nativeReceivedAt == null
        ? null
        : sample.nativeReceivedAt!.difference(previousRaw!.nativeReceivedAt!);
    final generationChanged = previousRaw?.captureGenerationId != null &&
        sample.captureGenerationId != null &&
        previousRaw!.captureGenerationId != sample.captureGenerationId;
    final monotonicDomainChanged = previousRaw?.monotonicDomainId != null &&
        sample.monotonicDomainId != null &&
        previousRaw!.monotonicDomainId != sample.monotonicDomainId;
    final alreadyAcrossLifecycleBoundary =
        previousAccepted.segmentId != currentSegmentId;
    final hasInterveningRejectedFixes = previousRaw != null &&
        previousRaw.sequence > previousAccepted.sequence &&
        !previousRaw.accepted;
    final acceptedGapDiagnostic =
        acceptedGap > config.acceptedGeometryGapThreshold;
    final rawGapDiagnostic = rawReceiptGap != null &&
        rawReceiptGap > config.callbackHealthWarningThreshold;
    // Continuity policy 4 also decides every accepted gap that could be
    // visible, so a silent phone and one with rejected fixes are judged alike.
    final visibleLengthGap = TrackingPolicyVersions.resolveContinuityPolicy(
              continuityPolicyVersion,
            ) >=
            4 &&
        acceptedGap >= TrackingContinuityGap.visibleProviderGap;

    if (!acceptedGapDiagnostic &&
        !rawGapDiagnostic &&
        !visibleLengthGap &&
        !quality.issues.contains(FixQualityIssue.largeGap) &&
        !generationChanged &&
        !monotonicDomainChanged &&
        !alreadyAcrossLifecycleBoundary &&
        !hasInterveningRejectedFixes) {
      return null;
    }

    final lifecycle = sample.nativeLifecycle ?? fallbackLifecycle;
    final sampling = sample.samplingProfile ?? fallbackSamplingProfile;
    final callbackHealthy = rawReceiptGap == null ||
        rawReceiptGap <= config.callbackHealthWarningThreshold;
    final batchingObserved = acceptedGapDiagnostic && callbackHealthy;
    final previousEpochId = previousAccepted.configurationEpochId;
    final runtimeConfigurationBoundary = policyEpoch != null &&
        policyEpoch.epochNumber > 1 &&
        previousEpochId != null &&
        previousEpochId != policyEpoch.id &&
        !acceptedGapDiagnostic;
    return TrackingContinuityClassifier(
      policy: config.continuityPolicy,
      policyVersion: continuityPolicyVersion,
    ).classify(
      TrackingContinuityEvidence(
        currentAcceptedForGeometry: quality.acceptedForGeometry,
        expectedTrackId: trackId,
        currentTrackId: sample.trackId ?? trackId,
        previousCaptureGenerationId: previousRaw?.captureGenerationId,
        currentCaptureGenerationId: sample.captureGenerationId,
        previousMonotonicDomainId: previousRaw?.monotonicDomainId,
        currentMonotonicDomainId: sample.monotonicDomainId,
        nativeLifecycle: lifecycle,
        samplingProfile: sampling,
        serviceHealthy: lifecycle == TrackerLifecycle.tracking ||
            lifecycle == TrackerLifecycle.starting,
        permissionAndServiceAvailable: lifecycle != TrackerLifecycle.failed,
        hasInterveningRejectedFixes: hasInterveningRejectedFixes,
        providerBatchingObserved: batchingObserved,
        providerAvailable:
            sample.provider != null && sample.provider!.trim().isNotEmpty,
        explicitBoundaryCause: alreadyAcrossLifecycleBoundary
            ? TrackingGapCause.explicitPause
            : null,
        acceptedGeometryGap: acceptedGap,
        rawReceiptGap: rawReceiptGap,
        runtimeConfigurationBoundary: runtimeConfigurationBoundary,
        interveningFixesHeldAtStop: hasInterveningRejectedFixes &&
            (_isStopHoldReason(previousRaw.rejectionReason) ||
                previousRaw.qualityFlags & TrackPointQualityFlag.duringStop !=
                    0),
        stayExplainsGap: stayExplainsGap,
      ),
    );
  }

  static bool _isStopHoldReason(String? reason) =>
      reason == FixQualityIssue.stationaryHold ||
      reason == FixQualityIssue.stationaryOutlier;
}
