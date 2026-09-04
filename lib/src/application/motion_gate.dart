import '../domain/activity_snapshot.dart';
import '../domain/tracker_status.dart';
import '../domain/tracking_config.dart';

final class MotionGate {
  MotionGate(this.config);

  final TrackingConfig config;
  MotionState _state = MotionState.unknown;
  DateTime? _stillSince;
  int _movingEvidence = 0;

  MotionState get state => _state;

  SamplingProfile get samplingProfile => _state == MotionState.stationary
      ? SamplingProfile.stationary
      : SamplingProfile.moving;

  MotionState add(ActivitySnapshot activity, DateTime now) {
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
}
