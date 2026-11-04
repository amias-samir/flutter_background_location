import 'dart:math' as math;

import '../domain/activity_snapshot.dart';
import '../domain/motion_policy.dart';
import '../domain/tracker_status.dart';
import '../domain/tracking_config.dart';
import '../domain/tracking_configuration_epoch.dart';

/// Dart mirror of the native moving/stationary state machine.
///
/// Native code owns the location request; this mirror labels points. Under
/// motion policy 2 it also tells the canonical stop hold whether a still
/// episode is current ([stillEpisodeActive]).
final class MotionGate {
  MotionGate(this.config)
      : policyVersion = config.captureIntent == RouteCaptureIntent.adaptive
            ? TrackingPolicyVersions.resolveMotionPolicy(
                config.motionPolicyVersion,
              )
            : TrackingPolicyVersions.legacyMotionPolicy;

  final TrackingConfig config;

  /// Motion policy this gate applies. Explicit capture intents never relax
  /// sampling, so they keep version 1 labelling.
  final int policyVersion;

  MotionState _state = MotionState.unknown;
  DateTime? _stillSince;
  int _movingEvidence = 0;

  // Motion policy 2.
  DateTime? _stillCandidateSince;
  DateTime? _episodeStartedAt;
  DateTime? _endedAt;
  DateTime? _mediumMovingSince;
  final Map<String, DateTime> _lastReadingAt = <String, DateTime>{};

  MotionState get state => _state;

  SamplingProfile get samplingProfile => _state == MotionState.stationary
      ? SamplingProfile.stationary
      : SamplingProfile.moving;

  /// Whether a motion-policy-2 still episode is current. Always false under
  /// version 1.
  bool get stillEpisodeActive => _episodeStartedAt != null;

  /// Evidence time at which the current still episode started.
  DateTime? get stillEpisodeStartedAt => _episodeStartedAt;

  MotionState add(ActivitySnapshot activity, DateTime now) => policyVersion >= 2
      ? _addVersion2(activity, now)
      : _addVersion1(activity, now);

  /// Advances time-based motion-policy-2 rules to [now], the capture time of
  /// the next fix. Version 1 has no time-based rules.
  MotionState evaluate(DateTime now) {
    if (policyVersion < 2) return _state;
    final mediumSince = _mediumMovingSince;
    if (mediumSince != null &&
        now.difference(mediumSince) >=
            MotionPolicyV2.coreMotionMediumPersistence) {
      _endEpisode(now);
      return _state;
    }
    final candidateSince = _stillCandidateSince;
    if (candidateSince != null &&
        _episodeStartedAt == null &&
        now.difference(candidateSince) >=
            MotionPolicyV2.stillEpisodeMinimumSpan) {
      _episodeStartedAt = candidateSince;
    }
    if (_episodeStartedAt != null &&
        candidateSince != null &&
        now.difference(candidateSince) >=
            config.stationaryConfirmationDuration) {
      _state = MotionState.stationary;
    }
    return _state;
  }

  /// Ends the current still episode because a fix at [at] confirmed a
  /// departure by Doppler speed or sustained displacement.
  void endStillEpisode(DateTime at) {
    if (policyVersion < 2) return;
    _endEpisode(at);
  }

  /// Restores a still episode that stored stop-hold evidence proves was
  /// current before the process restarted.
  void restoreStillEpisode(DateTime startedAt) {
    if (policyVersion < 2 || _episodeStartedAt != null) return;
    _stillCandidateSince = startedAt;
    _episodeStartedAt = startedAt;
  }

  MotionState _addVersion1(ActivitySnapshot activity, DateTime now) {
    final evaluated = activity.evaluatedAt(
      now,
      config.activityFreshnessThreshold,
    );
    if (evaluated.evidenceState != ActivityEvidenceState.fresh) {
      _stillSince = null;
      _movingEvidence = 0;
      if (_state == MotionState.stationary &&
          config.staleActivityFallback ==
              StaleActivityFallback.keepMovingProfile) {
        _state = MotionState.moving;
      }
      return _state;
    }
    if (evaluated.type == TrackingActivityType.stationary &&
        evaluated.confidence >= config.stationaryConfidenceThreshold) {
      _stillSince ??= now;
      _movingEvidence = 0;
      if (now.difference(_stillSince!) >=
          config.stationaryConfirmationDuration) {
        _state = MotionState.stationary;
      }
      return _state;
    }

    _stillSince = null;
    if (evaluated.type.indicatesMovement &&
        evaluated.confidence >= config.movingConfidenceThreshold) {
      _movingEvidence += 1;
      if (_movingEvidence >= config.movingConfirmationCount) {
        _state = MotionState.moving;
        _movingEvidence = 0;
      }
    } else {
      _movingEvidence = 0;
    }
    return _state;
  }

  MotionState _addVersion2(ActivitySnapshot activity, DateTime now) {
    final recordedAt = activity.recordedAt;
    // A reading without a time carries no evidence; silence is neutral.
    if (recordedAt == null) return evaluate(now);
    // The same reading arrives on the activity stream and attached to fixes.
    final previous = _lastReadingAt[activity.source];
    if (previous != null && !recordedAt.isAfter(previous)) return evaluate(now);
    _lastReadingAt[activity.source] = recordedAt;
    // Readings older than the last departure must not reopen the stop.
    final ended = _endedAt;
    if (ended != null && !recordedAt.isAfter(ended)) return evaluate(now);

    if (MotionPolicyV2.isStillTransitionExit(activity) ||
        MotionPolicyV2.isMovingTransitionEnter(activity)) {
      _endEpisode(recordedAt);
      return _state;
    }
    if (MotionPolicyV2.isStillTransitionEnter(activity)) {
      _movingEvidence = 0;
      _mediumMovingSince = null;
      _stillCandidateSince ??= recordedAt;
      _episodeStartedAt ??= _stillCandidateSince;
      return evaluate(now);
    }
    if (activity.source == MotionPolicyV2.transitionSource) {
      // EXIT transitions of moving activities are not still evidence.
      return evaluate(now);
    }

    if (MotionPolicyV2.isMovingReading(
      activity,
      movingConfidenceThreshold: config.movingConfidenceThreshold,
    )) {
      if (activity.source == MotionPolicyV2.coreMotionSource) {
        // Core Motion reports changes only: high confidence ends the episode,
        // medium confidence must stay current for a short time.
        if (activity.confidence >= MotionPolicyV2.coreMotionHighConfidence) {
          _endEpisode(recordedAt);
          return _state;
        }
        _mediumMovingSince ??= recordedAt;
        return evaluate(now);
      }
      _movingEvidence += 1;
      if (_movingEvidence >=
          math.max(
            config.movingConfirmationCount,
            MotionPolicyV2.movingConfirmationReadings,
          )) {
        _endEpisode(recordedAt);
        return _state;
      }
      return evaluate(now);
    }

    // Any other reading interrupts a run of moving readings.
    _movingEvidence = 0;
    _mediumMovingSince = null;
    if (MotionPolicyV2.isConfidentStill(
      activity,
      stationaryConfidenceThreshold: config.stationaryConfidenceThreshold,
    )) {
      _stillCandidateSince ??= recordedAt;
    }
    // Unknown, tilting and low-confidence readings are neutral.
    return evaluate(now);
  }

  void _endEpisode(DateTime at) {
    _episodeStartedAt = null;
    _stillCandidateSince = null;
    _mediumMovingSince = null;
    _movingEvidence = 0;
    _endedAt = at;
    _state = MotionState.moving;
  }
}
