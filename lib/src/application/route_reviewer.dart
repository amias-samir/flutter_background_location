import '../domain/activity_snapshot.dart';
import '../domain/kinematic_policy.dart';
import '../domain/quality_run_rules.dart';
import '../domain/route_review.dart';
import '../domain/track_geodesy.dart';
import '../domain/track_point.dart';
import '../domain/track_segment.dart';
import '../domain/track_stop.dart';
import '../domain/track_stop_places.dart';
import '../domain/tracker_status.dart';
import '../domain/tracking_config.dart';
import '../domain/tracking_configuration_epoch.dart';
import '../domain/tracking_continuity.dart';
import 'continuity_gap_detector.dart';
import 'route_decision_engine.dart';

/// Decides a completed route again under quality policy 5 and continuity
/// policy 4.
final class RouteReviewer {
  const RouteReviewer();

  /// Walking evidence must last this long after the counter's last rise for
  /// the count to have stalled.
  static const stepStallEvidence = Duration(minutes: 2);

  /// Walking evidence counts only from this long after the counter's last
  /// rise, the longest a batched counter may lag.
  static const stepStallGrace = Duration(seconds: 60);

  /// Reviews [points] of [trackId], whose segments are [segments] and whose
  /// configuration epochs are [epochs] by id.
  RouteReview review({
    required String trackId,
    required List<TrackPoint> points,
    required List<TrackSegment> segments,
    required Map<String, TrackingConfigurationEpoch> epochs,
    required TrackingConfig fallbackConfig,
  }) {
    final ordered = points.toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    final segmentStarts = <String, DateTime>{
      for (final segment in segments) segment.id: segment.startedAt,
    };
    final kept = <TrackPoint>[];
    final stops = <TrackStop>[];
    final runs = <_DraftRun>[];
    final gaps = <ReviewedGap>[];
    var distance = 0.0;

    RouteDecisionEngine? engine;
    String? engineSegment;
    String? engineEpoch;
    final segmentPoints = <TrackPoint>[];
    TrackPoint? lastAccepted;
    TrackPoint? lastAcceptedInSegment;
    TrackPoint? lastRaw;
    TrackStop? openStop;
    var stopIndex = 0;

    TrackingConfigurationEpoch? epochOf(TrackPoint point) =>
        point.configurationEpochId == null
            ? null
            : epochs[point.configurationEpochId];
    TrackingConfig configOf(TrackPoint point) =>
        epochOf(point)?.resolvedConfig ?? fallbackConfig;

    void closeOpenStop() {
      final open = openStop;
      if (open == null) return;
      stops[stops.length - 1] = _withEnd(open, open.lastSeenAt);
      openStop = null;
    }

    for (final point in ordered) {
      final segmentId = point.segmentId;
      if (segmentId != engineSegment) {
        // A new segment: a pause or interruption closed the current stop.
        closeOpenStop();
        engine = RouteDecisionEngine(configOf(point));
        engineSegment = segmentId;
        engineEpoch = point.configurationEpochId;
        segmentPoints.clear();
        lastAcceptedInSegment = null;
      } else if (point.configurationEpochId != engineEpoch) {
        // A runtime configuration update: the same segment under new rules.
        engine = RouteDecisionEngine(configOf(point))
          ..restore(
            tail: segmentPoints.map(RouteDecisionInputs.restoredFix).toList(),
            segmentId: segmentId,
            segmentStartedAt: segmentStarts[segmentId],
            openStop: openStop,
          );
        engineEpoch = point.configurationEpochId;
      }
      final current = engine!;
      final sample = RouteDecisionInputs.sampleOf(point);
      final step = current.decide(
        sample,
        segmentId: segmentId,
        segmentStartedAt: segmentStarts[segmentId],
        readings: point.activityReadings,
      );
      final decision = step.decision;
      final reviewed = _withDecision(point, decision.acceptedForGeometry,
          decision.qualityFlags, decision.rejectionReason);
      current.commit(step, reviewed);
      segmentPoints.add(reviewed);

      // Stops, one row per visit, as the repository stores them.
      final change = step.stopChange;
      if (change is TrackStopOpen || change is TrackStopRecord) {
        final stay = change is TrackStopOpen
            ? TrackStop(
                id: 'review-stop-${stopIndex++}',
                trackId: trackId,
                segmentId: segmentId,
                kind: change.kind,
                latitude: change.latitude,
                longitude: change.longitude,
                centreSigmaMeters: change.centreSigmaMeters,
                radiusMeters: change.radiusMeters,
                startedAt: change.startedAt,
                lastSeenAt: point.capturedAt,
                evidenceCount: change.priorEvidenceCount + 1,
                qualityPolicyVersion: change.qualityPolicyVersion,
                firstSequence: change.firstSequence ?? point.sequence,
                lastSequence: point.sequence,
                arrivalPointId: change.arrivalPointId,
              )
            : TrackStop(
                id: 'review-stop-${stopIndex++}',
                trackId: trackId,
                segmentId: segmentId,
                kind: (change as TrackStopRecord).kind,
                latitude: change.latitude,
                longitude: change.longitude,
                centreSigmaMeters: change.centreSigmaMeters,
                radiusMeters: change.radiusMeters,
                startedAt: change.startedAt,
                lastSeenAt: change.lastSeenAt,
                endedAt: point.capturedAt,
                evidenceCount: change.evidenceCount,
                qualityPolicyVersion: change.qualityPolicyVersion,
                firstSequence: change.firstSequence,
                lastSequence: change.lastSequence,
                arrivalPointId: change.arrivalPointId,
                departurePointId: point.id,
              );
        closeOpenStop();
        // Rule Q1: poor fixes on the approach become informational.
        _downgradeBefore(runs, ordered, segmentId, stay.startedAt);
        final previous = stops.isEmpty ? null : stops.last;
        if (previous != null && TrackStopPlaces.continues(previous, stay)) {
          final merged = TrackStopPlaces.combine(<TrackStop>[previous, stay]);
          stops[stops.length - 1] =
              stay.isOpen ? _reopened(merged, stay) : merged;
        } else {
          stops.add(stay);
        }
        openStop = stops.last.isOpen ? stops.last : null;
      } else if (change is TrackStopExtend) {
        final open = openStop;
        if (open != null) {
          stops[stops.length - 1] = _extended(open, point);
          openStop = stops.last;
        }
      } else if (change is TrackStopClose) {
        final open = openStop;
        if (open != null) {
          stops[stops.length - 1] = change.departure
              ? _withEnd(open, point.capturedAt, departurePointId: point.id)
              : _withEnd(open, open.lastSeenAt);
          openStop = null;
        }
      }

      if (reviewed.accepted) {
        final config = configOf(point);
        final gap = ContinuityGapDetector.detect(
          config: config,
          trackId: trackId,
          sample: sample,
          quality: decision,
          previousAccepted: lastAcceptedInSegment ?? lastAccepted,
          previousRaw: lastRaw,
          currentSegmentId: segmentId,
          continuityPolicyVersion: 4,
          policyEpoch: epochOf(point),
          fallbackLifecycle: TrackerLifecycle.tracking,
          fallbackSamplingProfile: SamplingProfile.moving,
          stayExplainsGap: step.stayExplainsGap,
        );
        final before = lastAcceptedInSegment ?? lastAccepted;
        if (gap != null && before != null) {
          final providerGap = point.capturedAt.difference(before.capturedAt);
          final straight = _meters(before, point);
          gaps.add(
            ReviewedGap(
              beforePointId: before.id,
              afterPointId: point.id,
              beforeSegmentId: before.segmentId,
              afterSegmentId: segmentId,
              decision: gap,
              visible: TrackingContinuityGap.visibleFor(
                cause: gap.cause,
                providerGap: providerGap,
                straightLineDistanceMeters: straight,
              ),
              providerGap: providerGap,
              rawReceiptGap: lastRaw?.nativeReceivedAt == null ||
                      point.nativeReceivedAt == null
                  ? null
                  : point.nativeReceivedAt!
                      .difference(lastRaw!.nativeReceivedAt!),
              straightLineDistanceMeters: straight,
              nativeCaptureGeneration: point.captureGenerationId,
              configurationEpochId: point.configurationEpochId,
            ),
          );
        }
        final inSegment = lastAcceptedInSegment;
        if (inSegment != null &&
            gap?.treatment != TrackingGapTreatment.startNewSegment &&
            !(gap?.excludeConnectorFromMeasuredDistance ?? false)) {
          distance += _meters(inSegment, point);
        }
        // A run of rejected fixes between two accepted ones.
        if (inSegment != null &&
            lastRaw != null &&
            !lastRaw.accepted &&
            lastRaw.sequence > inSegment.sequence) {
          final rows = <QualityRunFix>[
            for (final candidate in segmentPoints)
              if (!candidate.accepted &&
                  candidate.sequence > inSegment.sequence &&
                  candidate.sequence < point.sequence)
                QualityRunFix(
                  sequence: candidate.sequence,
                  capturedAt: candidate.capturedAt,
                  qualityFlags: candidate.qualityFlags,
                  horizontalAccuracy: candidate.horizontalAccuracy,
                  speed: candidate.speed,
                  speedAccuracy: candidate.speedAccuracy,
                  rejectionReason: candidate.rejectionReason,
                ),
          ];
          if (rows.isNotEmpty) {
            runs.add(
              _DraftRun(
                firstRawSequence: rows.first.sequence,
                lastRawSequence: rows.last.sequence,
                rejectedCount: rows.length,
                beforePointId: inSegment.id,
                afterPointId: point.id,
                verdict: QualityRunRules.decide(
                  rows: rows,
                  stops: <QualityRunStopWindow>[
                    for (final stop in stops)
                      QualityRunStopWindow(
                        startedAt: stop.startedAt,
                        endedAt: stop.endedAt ?? stop.lastSeenAt,
                      ),
                  ],
                  maximumAcceptedAccuracyMeters:
                      config.maximumAcceptedAccuracyMeters,
                  policyVersion: RouteDecisionEngine.policyVersion,
                ),
              ),
            );
          }
        }
        kept.add(reviewed);
        lastAccepted = reviewed;
        lastAcceptedInSegment = reviewed;
      }
      lastRaw = reviewed;
    }
    closeOpenStop();

    return RouteReview(
      trackId: trackId,
      sourceMaximumSequence: ordered.isEmpty ? 0 : ordered.last.sequence,
      keptPoints: List<TrackPoint>.unmodifiable(kept),
      stops: List<TrackStop>.unmodifiable(stops),
      qualityRuns: List<ReviewedQualityRun>.unmodifiable(
        runs.map((run) => run.finish()),
      ),
      gaps: List<ReviewedGap>.unmodifiable(gaps),
      correctedDistanceMeters: distance,
      stepGenerations: _stepGenerations(ordered, fallbackConfig, configOf),
    );
  }

  /// Step rule 1 for each capture generation of [points]: the count stalled
  /// when walking evidence lasted [stepStallEvidence], starting at least
  /// [stepStallGrace] after its last rise.
  static List<ReviewedStepGeneration> _stepGenerations(
    List<TrackPoint> points,
    TrackingConfig fallbackConfig,
    TrackingConfig Function(TrackPoint) configOf,
  ) {
    final byGeneration = <String, List<TrackPoint>>{};
    for (final point in points) {
      final generation = point.captureGenerationId;
      if (generation == null) continue;
      byGeneration.putIfAbsent(generation, () => <TrackPoint>[]).add(point);
    }
    final result = <ReviewedStepGeneration>[];
    for (final entry in byGeneration.entries) {
      final generationPoints = entry.value;
      int? count;
      DateTime? lastRiseAt;
      for (final point in generationPoints) {
        final steps = point.stepCount;
        if (steps == null) continue;
        if (count == null || steps > count) {
          if (count != null) lastRiseAt = point.capturedAt;
          count = steps;
          lastRiseAt ??= point.capturedAt;
        }
      }
      if (count == null) continue;
      DateTime? stoppedAt;
      final rise = lastRiseAt;
      if (rise != null) {
        final evidence = <DateTime>[
          for (final point in generationPoints)
            if (point.capturedAt.difference(rise) >= stepStallGrace &&
                _walkingEvidence(point, configOf(point)))
              point.capturedAt,
        ];
        if (evidence.length >= 3 &&
            evidence.last.difference(evidence.first) >= stepStallEvidence) {
          stoppedAt = rise;
        }
      }
      result.add(
        ReviewedStepGeneration(
          captureGenerationId: entry.key,
          segmentId: generationPoints.last.segmentId,
          stepCount: count,
          lastRiseAt: lastRiseAt,
          stoppedAt: stoppedAt,
        ),
      );
    }
    return result;
  }

  /// Motion evidence of walking on [point]: a fresh walking or running
  /// reading at the moving threshold, or a precisely measured walking-pace
  /// Doppler speed without a vehicle or bicycle reading.
  static bool _walkingEvidence(TrackPoint point, TrackingConfig config) {
    final type = point.activityType;
    final fresh = point.activityEvidenceState == ActivityEvidenceState.fresh;
    if (fresh &&
        (type == TrackingActivityType.walking ||
            type == TrackingActivityType.running) &&
        point.activityConfidence >= config.movingConfidenceThreshold) {
      return true;
    }
    if (type == TrackingActivityType.inVehicle ||
        type == TrackingActivityType.onBicycle) {
      return false;
    }
    final speed = point.speed;
    final accuracy = point.speedAccuracy;
    return speed != null &&
        accuracy != null &&
        accuracy <= 0.5 &&
        speed >= 0.7 &&
        speed <= 2.5 &&
        KinematicPolicy.classify(speed: speed, speedAccuracy: accuracy) !=
            DopplerClass.degraded;
  }

  /// Rule Q1 for the runs of [segmentId] ending within the arrival allowance
  /// before a stop that opened at [startedAt].
  static void _downgradeBefore(
    List<_DraftRun> runs,
    List<TrackPoint> points,
    String segmentId,
    DateTime startedAt,
  ) {
    final from = startedAt.subtract(QualityRunRules.stopArrivalAllowance);
    final bySequence = <int, TrackPoint>{
      for (final point in points) point.sequence: point,
    };
    for (final run in runs) {
      if (!run.visible) continue;
      final last = bySequence[run.lastRawSequence];
      if (last == null || last.segmentId != segmentId) continue;
      if (last.capturedAt.isBefore(from)) continue;
      // The reviewed decisions of the run's fixes are what the verdict read;
      // only travel shown by a usable Doppler speed keeps it visible.
      final travelled = <TrackPoint>[
        for (var sequence = run.firstRawSequence;
            sequence <= run.lastRawSequence;
            sequence += 1)
          if (bySequence[sequence] case final point?) point,
      ].any(
        (point) => QualityRunRules.showsTravel(
          QualityRunFix(
            sequence: point.sequence,
            capturedAt: point.capturedAt,
            qualityFlags: point.qualityFlags,
            speed: point.speed,
            speedAccuracy: point.speedAccuracy,
            rejectionReason: point.rejectionReason,
          ),
          5,
        ),
      );
      if (!travelled) run.visible = false;
    }
  }

  static TrackPoint _withDecision(
    TrackPoint point,
    bool accepted,
    int qualityFlags,
    String? rejectionReason,
  ) =>
      TrackPoint(
        id: point.id,
        trackId: point.trackId,
        segmentId: point.segmentId,
        sequence: point.sequence,
        latitude: point.latitude,
        longitude: point.longitude,
        altitude: point.altitude,
        horizontalAccuracy: point.horizontalAccuracy,
        verticalAccuracy: point.verticalAccuracy,
        speed: point.speed,
        speedAccuracy: point.speedAccuracy,
        heading: point.heading,
        headingAccuracy: point.headingAccuracy,
        capturedAt: point.capturedAt,
        persistedAt: point.persistedAt,
        activityType: point.activityType,
        activityConfidence: point.activityConfidence,
        activitySource: point.activitySource,
        activityRawType: point.activityRawType,
        activityEvidenceState: point.activityEvidenceState,
        activityAge: point.activityAge,
        activityProbabilities: point.activityProbabilities,
        activityRecordedAt: point.activityRecordedAt,
        activityReadings: point.activityReadings,
        nativeForegroundState: point.nativeForegroundState,
        screenInteractive: point.screenInteractive,
        batterySaverActive: point.batterySaverActive,
        motionEvidenceId: point.motionEvidenceId,
        motionState: point.motionState,
        provider: point.provider,
        isMocked: point.isMocked,
        mockDetectionAvailable: point.mockDetectionAvailable,
        mockEvidence: point.mockEvidence,
        nativeEventId: point.nativeEventId,
        configurationEpochId: point.configurationEpochId,
        nativeReceivedAt: point.nativeReceivedAt,
        providerTimeDeltaMsAtReceipt: point.providerTimeDeltaMsAtReceipt,
        monotonicFixNanos: point.monotonicFixNanos,
        monotonicReceivedNanos: point.monotonicReceivedNanos,
        monotonicDomainId: point.monotonicDomainId,
        captureGenerationId: point.captureGenerationId,
        nativeSessionStartedAt: point.nativeSessionStartedAt,
        nativeLifecycle: point.nativeLifecycle,
        samplingProfile: point.samplingProfile,
        stepCount: point.stepCount,
        qualityPolicyVersion: RouteDecisionEngine.policyVersion,
        accepted: accepted,
        qualityFlags: qualityFlags,
        rejectionReason: rejectionReason,
      );

  static TrackStop _withEnd(
    TrackStop stop,
    DateTime endedAt, {
    String? departurePointId,
  }) =>
      TrackStop(
        id: stop.id,
        trackId: stop.trackId,
        segmentId: stop.segmentId,
        kind: stop.kind,
        latitude: stop.latitude,
        longitude: stop.longitude,
        centreSigmaMeters: stop.centreSigmaMeters,
        radiusMeters: stop.radiusMeters,
        startedAt: stop.startedAt,
        lastSeenAt: stop.lastSeenAt,
        endedAt: endedAt,
        evidenceCount: stop.evidenceCount,
        qualityPolicyVersion: stop.qualityPolicyVersion,
        firstSequence: stop.firstSequence,
        lastSequence: stop.lastSequence,
        arrivalPointId: stop.arrivalPointId,
        departurePointId: departurePointId ?? stop.departurePointId,
      );

  static TrackStop _extended(TrackStop stop, TrackPoint point) => TrackStop(
        id: stop.id,
        trackId: stop.trackId,
        segmentId: stop.segmentId,
        kind: stop.kind,
        latitude: stop.latitude,
        longitude: stop.longitude,
        centreSigmaMeters: stop.centreSigmaMeters,
        radiusMeters: stop.radiusMeters,
        startedAt: stop.startedAt,
        lastSeenAt: point.capturedAt,
        evidenceCount: stop.evidenceCount + 1,
        qualityPolicyVersion: stop.qualityPolicyVersion,
        firstSequence: stop.firstSequence,
        lastSequence: point.sequence,
        arrivalPointId: stop.arrivalPointId,
      );

  /// [merged] kept open because its newest stay, [stay], still is.
  static TrackStop _reopened(TrackStop merged, TrackStop stay) => TrackStop(
        id: merged.id,
        trackId: merged.trackId,
        segmentId: merged.segmentId,
        kind: merged.kind,
        latitude: merged.latitude,
        longitude: merged.longitude,
        centreSigmaMeters: merged.centreSigmaMeters,
        radiusMeters: merged.radiusMeters,
        startedAt: merged.startedAt,
        lastSeenAt: stay.lastSeenAt,
        evidenceCount: merged.evidenceCount,
        qualityPolicyVersion: merged.qualityPolicyVersion,
        firstSequence: merged.firstSequence,
        lastSequence: stay.lastSequence,
        arrivalPointId: merged.arrivalPointId,
      );

  static double _meters(TrackPoint from, TrackPoint to) =>
      TrackGeodesy.sphericalHaversineMeters(
        from.latitude,
        from.longitude,
        to.latitude,
        to.longitude,
      );
}

/// A reviewed run whose severity a later stop may still lower (rule `Q1`).
final class _DraftRun {
  _DraftRun({
    required this.firstRawSequence,
    required this.lastRawSequence,
    required this.rejectedCount,
    required this.beforePointId,
    required this.afterPointId,
    required this.verdict,
  }) : visible = verdict.visible;

  final int firstRawSequence;
  final int lastRawSequence;
  final int rejectedCount;
  final String beforePointId;
  final String afterPointId;
  final QualityRunVerdict verdict;
  bool visible;

  ReviewedQualityRun finish() => ReviewedQualityRun(
        firstRawSequence: firstRawSequence,
        lastRawSequence: lastRawSequence,
        rejectedCount: rejectedCount,
        beforePointId: beforePointId,
        afterPointId: afterPointId,
        verdict: verdict,
        visible: visible,
      );
}
