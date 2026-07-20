import '../domain/activity_snapshot.dart';
import '../domain/capability_report.dart';
import '../domain/location_sample.dart';
import '../domain/permission_state.dart';
import '../domain/tracker_status.dart';
import '../domain/tracking_config.dart';

enum NativeUserActionType { pause, stop }

final class PendingNativeUserAction {
  const PendingNativeUserAction({
    required this.actionId,
    required this.trackId,
    required this.action,
    required this.reason,
    required this.timestamp,
  });

  final String actionId;
  final String trackId;
  final NativeUserActionType action;
  final String reason;
  final DateTime timestamp;

  factory PendingNativeUserAction.fromMap(Map<Object?, Object?> map) {
    final rawTimestamp = map['timestamp'];
    final action = NativeUserActionType.values.firstWhere(
      (candidate) => candidate.name == map['action']?.toString(),
      orElse: () => throw const FormatException(
        'Unknown pending native user action.',
      ),
    );
    return PendingNativeUserAction(
      actionId: map['actionId']! as String,
      trackId: map['trackId']! as String,
      action: action,
      reason: map['reason'] as String? ??
          (action == NativeUserActionType.pause
              ? 'notification_paused'
              : 'notification_stopped'),
      timestamp: rawTimestamp is num
          ? DateTime.fromMillisecondsSinceEpoch(
              rawTimestamp.toInt(),
              isUtc: true,
            )
          : DateTime.parse(rawTimestamp! as String).toUtc(),
    );
  }
}

/// Optional adapter capability for native notification lifecycle actions.
abstract interface class NativeUserActionAdapter {
  Future<PendingNativeUserAction?> pendingUserAction();
  Future<void> acknowledgePendingUserAction(String actionId);
}

abstract interface class TrackerAdapter {
  Stream<LocationSample> get locationStream;
  Stream<ActivitySnapshot> get activityStream;
  Stream<TrackerStatus> get statusStream;

  Future<void> initialize();
  Future<TrackingCapabilityReport> capabilities();
  Future<TrackingPermissionState> permissions({bool request = false});
  Future<void> start({required String trackId, required TrackingConfig config});
  Future<void> pause({required String trackId});
  Future<void> resume(
      {required String trackId, required TrackingConfig config});
  Future<void> stop({required String trackId, required String reason});
  Future<void> updateConfig({
    required String trackId,
    required TrackingConfig config,
  });
  Future<bool> isRunning();
  Future<TrackerStatus> runtimeState();
  Future<LocationSample?> lastLocation();
  Future<List<LocationSample>> pendingLocations();
  Future<void> acknowledgeLocations(Iterable<String> eventIds);
  Future<bool> openAppSettings();
  Future<void> dispose();
}
