import 'tracker_status.dart';

/// Why a meaningful gap exists between route-geometry anchors.
///
/// A cause describes evidence; it does not by itself decide whether canonical
/// route topology should change. That decision is represented separately by
/// [TrackingGapTreatment].
enum TrackingGapCause {
  /// Raw fixes continued, but one or more were rejected from route geometry.
  acceptedFixRejectionRun,

  /// The active stationary profile intentionally reduced callback frequency.
  expectedStationarySuppression,

  /// The provider delivered fixes in a delayed batch from one capture session.
  providerBatching,

  /// The location provider could not supply usable evidence for part of a run.
  providerUnavailable,

  /// The user or host explicitly paused and later resumed capture.
  explicitPause,

  /// Native capture reported a real interruption or stopped session.
  nativeInterruption,

  /// Monotonic/capture identity proves that a producer process restarted.
  processRestart,

  /// Permission or Location Services became unavailable.
  permissionOrServiceLoss,

  /// A host explicitly ended one day of a longer journey.
  overnightBoundary,

  /// Available evidence cannot safely identify the reason for the gap.
  unknown,
}

/// Whether a gap keeps or changes canonical raw route topology.
enum TrackingGapTreatment {
  /// Retain the current segment and persist the gap as quality evidence.
  retainCurrentSegment,

  /// Close the current segment and begin a new lifecycle-evidence segment.
  startNewSegment,
}

/// How the straight connector associated with a gap affects route distance.
enum TrackingGapDistanceTreatment {
  /// Evidence is retained, but the connector is not counted as travelled.
  excluded,

  /// The connector is backed by canonical captured geometry and is measured.
  measured,

  /// A presentation-only connector is reported separately from measured data.
  inferred,
}

/// Fallback used only when continuity evidence is inconclusive.
///
/// Positively established same-generation capture remains continuous under
/// either value. [conservative] is the compatibility-safe default for mixed
/// native/plugin versions that cannot yet provide capture-generation evidence.
enum TrackingContinuityPolicy {
  /// Treat an unknown accepted-point gap as a segment boundary.
  conservative,

  /// Prefer a continuous segment when the route is active but evidence is
  /// incomplete. Explicit lifecycle boundaries still always split.
  preferContinuous;

  /// Parses persisted values without throwing on a newer/unknown policy.
  static TrackingContinuityPolicy parse(
    Object? value, {
    TrackingContinuityPolicy fallback = TrackingContinuityPolicy.conservative,
  }) {
    final normalized = value?.toString().trim();
    return TrackingContinuityPolicy.values.firstWhere(
      (candidate) => candidate.name == normalized,
      orElse: () => fallback,
    );
  }
}

/// Immutable evidence consumed by [TrackingContinuityClassifier].
///
/// Every field is coordinate-free. Null means the producer or repository did
/// not provide that evidence; it must never be interpreted as a positive
/// continuity signal.
final class TrackingContinuityEvidence {
  const TrackingContinuityEvidence({
    required this.currentAcceptedForGeometry,
    this.expectedTrackId,
    this.currentTrackId,
    this.previousCaptureGenerationId,
    this.currentCaptureGenerationId,
    this.previousMonotonicDomainId,
    this.currentMonotonicDomainId,
    this.nativeLifecycle,
    this.samplingProfile,
    this.serviceHealthy,
    this.permissionAndServiceAvailable,
    this.hasInterveningRejectedFixes = false,
    this.providerBatchingObserved = false,
    this.providerAvailable,
    this.explicitBoundaryCause,
    this.acceptedGeometryGap,
    this.rawReceiptGap,
  });

  /// Whether the current point passed the canonical geometry-quality policy.
  final bool currentAcceptedForGeometry;

  /// Durable track expected by the Dart persistence session.
  final String? expectedTrackId;

  /// Track identity attached to the current native event.
  final String? currentTrackId;

  /// Opaque generation attached to the previous raw event.
  final String? previousCaptureGenerationId;

  /// Opaque generation attached to the current raw event.
  final String? currentCaptureGenerationId;

  /// Monotonic clock domain attached to the previous raw event.
  final String? previousMonotonicDomainId;

  /// Monotonic clock domain attached to the current raw event.
  final String? currentMonotonicDomainId;

  /// Native lifecycle observed for the current event/session.
  final TrackerLifecycle? nativeLifecycle;

  /// Sampling profile active around the gap.
  final SamplingProfile? samplingProfile;

  /// Positive, coordinate-free native service-health evidence.
  final bool? serviceHealthy;

  /// Whether permissions and Location Services remained usable.
  final bool? permissionAndServiceAvailable;

  /// Whether raw callbacks exist between the accepted geometry anchors.
  final bool hasInterveningRejectedFixes;

  /// Whether native/provider evidence identifies delayed batched delivery.
  final bool providerBatchingObserved;

  /// Whether the provider was available around the gap, when known.
  final bool? providerAvailable;

  /// A durable explicit boundary. Only lifecycle boundary causes are valid.
  final TrackingGapCause? explicitBoundaryCause;

  /// Provider-time gap between accepted geometry anchors.
  final Duration? acceptedGeometryGap;

  /// Native receipt gap between consecutive raw callbacks.
  final Duration? rawReceiptGap;
}

/// Versioned topology decision for one accepted-geometry gap.
final class TrackingContinuityDecision {
  const TrackingContinuityDecision({
    required this.cause,
    required this.treatment,
    required this.excludeConnectorFromMeasuredDistance,
    required this.policyVersion,
  });

  /// Best supported explanation for the gap.
  final TrackingGapCause cause;

  /// Canonical raw-topology treatment.
  final TrackingGapTreatment treatment;

  /// Whether any presentation connector is excluded from measured distance.
  final bool excludeConnectorFromMeasuredDistance;

  /// Version of the classifier semantics that produced this decision.
  final int policyVersion;
}

/// Durable, coordinate-free topology evidence for one observed route gap.
final class TrackingContinuityGap {
  const TrackingContinuityGap({
    required this.id,
    required this.trackId,
    required this.afterPointId,
    required this.beforeSegmentId,
    required this.afterSegmentId,
    required this.cause,
    required this.treatment,
    required this.distanceTreatment,
    required this.continuityPolicyVersion,
    required this.createdAt,
    this.beforePointId,
    this.providerGap,
    this.rawReceiptGap,
    this.straightLineDistanceMeters,
    this.nativeCaptureGeneration,
    this.configurationEpochId,
  });

  final String id;
  final String trackId;
  final String? beforePointId;
  final String afterPointId;
  final String beforeSegmentId;
  final String afterSegmentId;
  final Duration? providerGap;
  final Duration? rawReceiptGap;
  final double? straightLineDistanceMeters;
  final TrackingGapCause cause;
  final TrackingGapTreatment treatment;
  final TrackingGapDistanceTreatment distanceTreatment;
  final String? nativeCaptureGeneration;
  final String? configurationEpochId;
  final int continuityPolicyVersion;
  final DateTime createdAt;

  factory TrackingContinuityGap.fromDatabase(Map<String, Object?> row) =>
      TrackingContinuityGap(
        id: row['id']! as String,
        trackId: row['track_id']! as String,
        beforePointId: row['before_point_id'] as String?,
        afterPointId: row['after_point_id']! as String,
        beforeSegmentId: row['before_segment_id']! as String,
        afterSegmentId: row['after_segment_id']! as String,
        providerGap: _durationFromMilliseconds(row['provider_gap_ms']),
        rawReceiptGap: _durationFromMilliseconds(row['raw_receipt_gap_ms']),
        straightLineDistanceMeters:
            (row['straight_line_distance_m'] as num?)?.toDouble(),
        cause: TrackingGapCause.values.byName(row['cause']! as String),
        treatment:
            TrackingGapTreatment.values.byName(row['treatment']! as String),
        distanceTreatment: TrackingGapDistanceTreatment.values
            .byName(row['distance_treatment']! as String),
        nativeCaptureGeneration: row['native_capture_generation'] as String?,
        configurationEpochId: row['configuration_epoch_id'] as String?,
        continuityPolicyVersion:
            (row['continuity_policy_version']! as num).toInt(),
        createdAt: DateTime.parse(row['created_at']! as String).toUtc(),
      );

  static Duration? _durationFromMilliseconds(Object? value) =>
      value == null ? null : Duration(milliseconds: (value as num).toInt());
}

/// Pure classifier that keeps quality evidence separate from route topology.
final class TrackingContinuityClassifier {
  const TrackingContinuityClassifier({
    this.policy = TrackingContinuityPolicy.conservative,
    this.policyVersion = 2,
  }) : assert(policyVersion > 0);

  /// Fallback policy for incomplete evidence.
  final TrackingContinuityPolicy policy;

  /// Version persisted with every durable gap decision.
  final int policyVersion;

  /// Classifies one already-detected accepted-geometry gap.
  TrackingContinuityDecision classify(TrackingContinuityEvidence evidence) {
    // A rejected point may be retained as diagnostic evidence, but it can
    // never create, close, or switch a canonical segment.
    if (!evidence.currentAcceptedForGeometry) {
      return _retain(TrackingGapCause.acceptedFixRejectionRun);
    }

    final explicit = evidence.explicitBoundaryCause;
    if (explicit != null) {
      return _split(_normalizedBoundaryCause(explicit));
    }

    if (evidence.permissionAndServiceAvailable == false) {
      return _split(TrackingGapCause.permissionOrServiceLoss);
    }

    final lifecycle = evidence.nativeLifecycle;
    if (lifecycle == TrackerLifecycle.paused) {
      return _split(TrackingGapCause.explicitPause);
    }
    if (lifecycle == TrackerLifecycle.interrupted ||
        lifecycle == TrackerLifecycle.failed ||
        lifecycle == TrackerLifecycle.idle ||
        lifecycle == TrackerLifecycle.stopping) {
      return _split(TrackingGapCause.nativeInterruption);
    }

    if (_differentKnownValues(
      evidence.previousMonotonicDomainId,
      evidence.currentMonotonicDomainId,
    )) {
      return _split(TrackingGapCause.processRestart);
    }

    if (_differentKnownValues(
      evidence.previousCaptureGenerationId,
      evidence.currentCaptureGenerationId,
    )) {
      return _split(TrackingGapCause.nativeInterruption);
    }

    final sameTrack = _sameKnownValues(
      evidence.expectedTrackId,
      evidence.currentTrackId,
    );
    final sameGeneration = _sameKnownValues(
      evidence.previousCaptureGenerationId,
      evidence.currentCaptureGenerationId,
    );
    final continuouslyActive =
        evidence.nativeLifecycle == TrackerLifecycle.tracking &&
            evidence.serviceHealthy == true &&
            evidence.permissionAndServiceAvailable != false;

    // Rejected raw fixes are quality evidence, never topology commands. If the
    // producer is still known active and no contrary generation/domain signal
    // was established above, keep the next accepted anchor in the segment.
    if (sameTrack &&
        continuouslyActive &&
        evidence.hasInterveningRejectedFixes) {
      return _retain(TrackingGapCause.acceptedFixRejectionRun);
    }

    if (sameTrack && sameGeneration && continuouslyActive) {
      if (evidence.hasInterveningRejectedFixes) {
        return _retain(TrackingGapCause.acceptedFixRejectionRun);
      }
      if (evidence.providerBatchingObserved) {
        return _retain(TrackingGapCause.providerBatching);
      }
      if (evidence.samplingProfile == SamplingProfile.stationary) {
        return _retain(TrackingGapCause.expectedStationarySuppression);
      }
      if (evidence.providerAvailable == false) {
        return _retain(TrackingGapCause.providerUnavailable);
      }
      return _retain(TrackingGapCause.unknown);
    }

    if (policy == TrackingContinuityPolicy.preferContinuous &&
        evidence.nativeLifecycle == TrackerLifecycle.tracking &&
        evidence.serviceHealthy != false &&
        evidence.permissionAndServiceAvailable != false) {
      final cause = evidence.hasInterveningRejectedFixes
          ? TrackingGapCause.acceptedFixRejectionRun
          : evidence.samplingProfile == SamplingProfile.stationary
              ? TrackingGapCause.expectedStationarySuppression
              : evidence.providerBatchingObserved
                  ? TrackingGapCause.providerBatching
                  : evidence.providerAvailable == false
                      ? TrackingGapCause.providerUnavailable
                      : TrackingGapCause.unknown;
      return _retain(cause);
    }

    return _split(TrackingGapCause.unknown);
  }

  TrackingContinuityDecision _retain(TrackingGapCause cause) =>
      TrackingContinuityDecision(
        cause: cause,
        treatment: TrackingGapTreatment.retainCurrentSegment,
        // Retained anchors are canonical points in the same recorded segment.
        // The map/export line already traverses this edge, so excluding it
        // under-reports the distance whenever intervening fixes were rejected.
        excludeConnectorFromMeasuredDistance: false,
        policyVersion: policyVersion,
      );

  TrackingContinuityDecision _split(TrackingGapCause cause) =>
      TrackingContinuityDecision(
        cause: cause,
        treatment: TrackingGapTreatment.startNewSegment,
        excludeConnectorFromMeasuredDistance: true,
        policyVersion: policyVersion,
      );

  static bool _sameKnownValues(String? left, String? right) =>
      left != null && left.isNotEmpty && left == right;

  static bool _differentKnownValues(String? left, String? right) =>
      left != null &&
      left.isNotEmpty &&
      right != null &&
      right.isNotEmpty &&
      left != right;

  static TrackingGapCause _normalizedBoundaryCause(TrackingGapCause cause) =>
      switch (cause) {
        TrackingGapCause.explicitPause ||
        TrackingGapCause.nativeInterruption ||
        TrackingGapCause.processRestart ||
        TrackingGapCause.permissionOrServiceLoss ||
        TrackingGapCause.overnightBoundary =>
          cause,
        _ => TrackingGapCause.nativeInterruption,
      };
}
