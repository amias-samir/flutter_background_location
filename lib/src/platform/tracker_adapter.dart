import '../domain/activity_snapshot.dart';
import '../domain/capability_report.dart';
import '../domain/location_sample.dart';
import '../domain/native_tracking_protocol.dart';
import '../domain/permission_state.dart';
import '../domain/tracker_status.dart';
import '../domain/tracking_config.dart';
import '../domain/tracking_readiness.dart';
import '../domain/tracking_settings.dart';

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

/// Optional adapter capability for native method-channel negotiation.
abstract interface class NativeProtocolAdapter {
  Future<NativeTrackingProtocol> protocolInfo();
}

/// Optional adapter capability for opening settings and diagnostics screens.
abstract interface class TrackerSettingsAdapter {
  Future<TrackingSettingsResult> openSettings(
    TrackingSettingsDestination destination,
  );

  Future<BatteryOptimizationState> batteryOptimizationState();
}

/// Optional adapter capability for one-step, visible-gesture permission prompts.
abstract interface class StagedPermissionAdapter {
  Future<TrackingPermissionState> requestPermissionStep({
    required TrackingReadinessAction action,
    required int expectedReadinessRevision,
  });
}

/// A bounded page of durable native location events.
///
/// Native journals can grow while Flutter is detached. This page shape lets the
/// Dart client drain those journals without materializing every pending fix in
/// one platform-channel response.
final class NativePendingLocationPage {
  NativePendingLocationPage({
    required Iterable<LocationSample> events,
    this.nextCursor,
    required this.hasMore,
    required this.encodedBytes,
    required this.remainingCount,
  }) : events = List<LocationSample>.unmodifiable(events);

  /// Events in durable insertion order.
  final List<LocationSample> events;

  /// Opaque cursor for the next page.
  final String? nextCursor;

  /// Whether another page is available after [nextCursor].
  final bool hasMore;

  /// Approximate encoded payload bytes included in this page.
  final int encodedBytes;

  /// Number of events remaining after this page, when the native side can
  /// compute it cheaply.
  final int remainingCount;
}

/// Optional adapter capability for bounded native journal draining.
abstract interface class PagedNativeLocationAdapter {
  Future<NativePendingLocationPage> pendingLocationPage({
    String? cursor,
    int maxRecords = 100,
    int maxEncodedBytes = 256 * 1024,
  });
}

/// Optional adapter capability for redacted native journal diagnostics.
abstract interface class NativeJournalDiagnosticsAdapter {
  Future<Map<String, Object?>> nativeJournalDiagnostic({
    bool performMaintenance = false,
  });
}

/// Optional destructive native-journal capability used by confirmed erase.
abstract interface class TrackScopedNativeDataAdapter {
  Future<int> clearNativeTrackData(String trackId);
}

/// A process-local lease bound to one durable tracking session.
final class NativeCommandLease {
  const NativeCommandLease({
    required this.trackId,
    required this.sessionControlToken,
    required this.supported,
    this.engineLeaseToken,
    this.commandRevision = 0,
  });

  final String trackId;
  final String sessionControlToken;
  final bool supported;
  final String? engineLeaseToken;
  final int commandRevision;
}

/// Optional adapter capability that fences lifecycle commands across engines.
///
/// The tokens coordinate package instances only; they are not authorization
/// credentials and do not replace host-side user authentication.
abstract interface class CommandLeaseTrackerAdapter {
  Future<NativeCommandLease> acquireCommandLease({
    required String trackId,
    required String sessionControlToken,
  });

  Future<void> releaseCommandLease({required String trackId});
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
