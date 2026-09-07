import 'motion_evidence.dart';

/// Native capture lifecycle independent of the Flutter widget lifecycle.
enum TrackerLifecycle {
  /// No native route capture is running.
  idle,

  /// Native capture is being prepared.
  starting,

  /// The active route is collecting location updates.
  tracking,

  /// The route is retained but native collection is stopped.
  paused,

  /// Native capture is performing terminal cleanup.
  stopping,

  /// Capture ended unexpectedly and may be resumable.
  interrupted,

  /// Capture failed and requires host attention.
  failed,
}

/// Motion gate currently used by native sampling logic.
enum MotionState {
  /// Motion evidence is unavailable or inconclusive.
  unknown,

  /// The device is considered to be moving.
  moving,

  /// The device is considered stationary.
  stationary,
}

/// Native sampling profile currently applied to the provider.
enum SamplingProfile {
  /// Uses the configured moving interval and distance filter.
  moving,

  /// Uses the configured stationary interval and distance filter.
  stationary,
}

/// Latest native lifecycle, motion, and sampling state.
final class TrackerStatus {
  /// Creates an immutable native status snapshot.
  const TrackerStatus({
    required this.lifecycle,
    this.trackId,
    this.lastPointAt,
    this.message,
    this.motionState = MotionState.unknown,
    this.samplingProfile = SamplingProfile.moving,
    this.motionEvidence,
  });

  /// Current native capture lifecycle.
  final TrackerLifecycle lifecycle;

  /// Internal route ID currently associated with native capture.
  final String? trackId;

  /// UTC time of the most recently reported native fix.
  final DateTime? lastPointAt;

  /// Sanitized status or failure message, when available.
  final String? message;

  /// Native moving/stationary decision.
  final MotionState motionState;

  /// Provider sampling profile currently in use.
  final SamplingProfile samplingProfile;

  /// Latest bounded native motion-evidence decision, when supported.
  final MotionEvidenceSnapshot? motionEvidence;

  /// Decodes a native status-channel payload.
  factory TrackerStatus.fromMap(Map<Object?, Object?> map) {
    final raw = map['lifecycle'] ?? map['state'] ?? map['status'];
    final normalized = raw?.toString().toLowerCase();
    final lifecycle = TrackerLifecycle.values.firstWhere(
      (candidate) => candidate.name == normalized,
      orElse: () => TrackerLifecycle.idle,
    );
    final timestamp = map['lastPointAt'] ?? map['timestamp'];
    final rawMotionEvidence = map['motionEvidence'];
    return TrackerStatus(
      lifecycle: lifecycle,
      trackId: map['trackId'] as String?,
      lastPointAt: timestamp is num
          ? DateTime.fromMillisecondsSinceEpoch(
              timestamp.toInt(),
              isUtc: true,
            )
          : null,
      message: map['message'] as String?,
      motionState: switch ((map['motionState'] ?? map['motion']).toString()) {
        'moving' => MotionState.moving,
        'stationary' => MotionState.stationary,
        _ => MotionState.unknown,
      },
      samplingProfile:
          (map['samplingProfile'] ?? map['batteryMode']).toString() ==
                  'stationary'
              ? SamplingProfile.stationary
              : SamplingProfile.moving,
      motionEvidence: rawMotionEvidence is Map
          ? MotionEvidenceSnapshot.fromMap(
              rawMotionEvidence.cast<Object?, Object?>(),
            )
          : null,
    );
  }
}
