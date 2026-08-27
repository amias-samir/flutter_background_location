import 'activity_snapshot.dart';
import 'track.dart';
import 'track_point.dart';
import 'tracker_status.dart';
import 'tracking_health.dart';
import 'tracking_readiness.dart';

/// Lifecycle commands currently safe for the host UI to show.
final class TrackingLifecycleActions {
  const TrackingLifecycleActions({
    required this.canStartNew,
    required this.canPause,
    required this.canResume,
    required this.canComplete,
    required this.commandInProgress,
  });

  final bool canStartNew;
  final bool canPause;
  final bool canResume;
  final bool canComplete;
  final bool commandInProgress;

  factory TrackingLifecycleActions.fromState({
    required TrackerStatus status,
    required Track? currentTrack,
    required TrackingReadiness readiness,
  }) {
    final trackStatus = currentTrack?.status;
    final commandInProgress = status.lifecycle == TrackerLifecycle.starting ||
        status.lifecycle == TrackerLifecycle.stopping ||
        trackStatus == TrackStatus.starting ||
        trackStatus == TrackStatus.stopping;
    final resumable = trackStatus == TrackStatus.paused ||
        trackStatus == TrackStatus.interrupted;
    final active = trackStatus == TrackStatus.active;
    return TrackingLifecycleActions(
      canStartNew: !commandInProgress &&
          readiness.canStart &&
          (currentTrack == null ||
              trackStatus == TrackStatus.completed ||
              trackStatus == TrackStatus.failed),
      canPause: !commandInProgress &&
          active &&
          status.lifecycle == TrackerLifecycle.tracking,
      canResume: !commandInProgress && resumable && readiness.canStart,
      canComplete: !commandInProgress && (active || resumable),
      commandInProgress: commandInProgress,
    );
  }
}

/// Replaying, coordinate-safe current tracking session snapshot.
final class TrackingSessionSnapshot {
  const TrackingSessionSnapshot({
    required this.revision,
    required this.observedAt,
    required this.status,
    required this.currentTrack,
    required this.activity,
    required this.lastPoint,
    required this.readiness,
    required this.allowedActions,
    this.health,
    this.fixState = TrackingFixState.idle,
    this.blockerCode,
    this.blockerRecoveryToken,
  });

  final int revision;
  final DateTime observedAt;
  final TrackerStatus status;
  final Track? currentTrack;
  final ActivitySnapshot activity;
  final TrackPoint? lastPoint;
  final TrackingReadiness readiness;
  final TrackingLifecycleActions allowedActions;
  final TrackingHealthSnapshot? health;
  final TrackingFixState fixState;

  /// Redacted reason that current-session actions are unavailable.
  final String? blockerCode;

  /// Ephemeral opaque token required to resolve [blockerCode].
  ///
  /// It contains no route or owner metadata and becomes stale when the
  /// underlying conflict changes.
  final String? blockerRecoveryToken;
}

/// Computes route-list actions for a selected stored route.
final class TrackAvailableActions {
  const TrackAvailableActions({
    required this.canView,
    required this.canExport,
    required this.canDelete,
  });

  final bool canView;
  final bool canExport;
  final bool canDelete;
}

TrackAvailableActions availableActionsFor(Track track) {
  final terminal = track.status == TrackStatus.completed ||
      track.status == TrackStatus.failed;
  return TrackAvailableActions(
    canView: track.acceptedPointCount > 0 || track.rejectedPointCount > 0,
    canExport: track.status == TrackStatus.completed,
    canDelete: terminal,
  );
}
