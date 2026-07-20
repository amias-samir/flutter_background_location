enum TrackerLifecycle {
  idle,
  starting,
  tracking,
  paused,
  stopping,
  interrupted,
  failed,
}

enum MotionState { unknown, moving, stationary }

enum SamplingProfile { moving, stationary }

final class TrackerStatus {
  const TrackerStatus({
    required this.lifecycle,
    this.trackId,
    this.lastPointAt,
    this.message,
    this.motionState = MotionState.unknown,
    this.samplingProfile = SamplingProfile.moving,
  });

  final TrackerLifecycle lifecycle;
  final String? trackId;
  final DateTime? lastPointAt;
  final String? message;
  final MotionState motionState;
  final SamplingProfile samplingProfile;

  factory TrackerStatus.fromMap(Map<Object?, Object?> map) {
    final raw = map['lifecycle'] ?? map['state'] ?? map['status'];
    final normalized = raw?.toString().toLowerCase();
    final lifecycle = TrackerLifecycle.values.firstWhere(
      (candidate) => candidate.name == normalized,
      orElse: () => TrackerLifecycle.idle,
    );
    final timestamp = map['lastPointAt'] ?? map['timestamp'];
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
    );
  }
}
