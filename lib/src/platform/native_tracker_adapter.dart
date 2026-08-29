import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../domain/activity_snapshot.dart';
import '../domain/capability_report.dart';
import '../domain/location_sample.dart';
import '../domain/native_tracking_protocol.dart';
import '../domain/permission_state.dart';
import '../domain/tracker_status.dart';
import '../domain/tracking_config.dart';
import '../domain/tracking_error.dart';
import '../domain/tracking_health.dart';
import '../domain/tracking_readiness.dart';
import '../domain/tracking_settings.dart';
import 'tracker_adapter.dart';

final class NativeTrackerAdapter
    implements
        TrackerAdapter,
        NativeUserActionAdapter,
        NativeProtocolAdapter,
        TrackerSettingsAdapter,
        StagedPermissionAdapter,
        PagedNativeLocationAdapter,
        NativeJournalDiagnosticsAdapter,
        NativeTrackingHealthAdapter,
        TrackScopedNativeDataAdapter,
        CommandLeaseTrackerAdapter {
  NativeTrackerAdapter({
    MethodChannel? methodChannel,
    EventChannel? locationChannel,
    EventChannel? activityChannel,
    EventChannel? statusChannel,
  })  : _methodChannel = methodChannel ?? const MethodChannel(_methodsName),
        _locationChannel =
            locationChannel ?? const EventChannel('$_prefix/location'),
        _activityChannel =
            activityChannel ?? const EventChannel('$_prefix/activity'),
        _statusChannel =
            statusChannel ?? const EventChannel('$_prefix/status') {
    _locations = _locationChannel
        .receiveBroadcastStream()
        .map(_eventMap)
        .map(LocationSample.fromMap)
        .asBroadcastStream();
    _activities = _activityChannel
        .receiveBroadcastStream()
        .map(_eventMap)
        .map(ActivitySnapshot.fromMap)
        .asBroadcastStream();
    _statuses = _statusChannel
        .receiveBroadcastStream()
        .map(_eventMap)
        .map(TrackerStatus.fromMap)
        .asBroadcastStream();
  }

  static const String _prefix = 'flutter_background_location';
  static const String _methodsName = '$_prefix/methods';

  final MethodChannel _methodChannel;
  final EventChannel _locationChannel;
  final EventChannel _activityChannel;
  final EventChannel _statusChannel;
  late final Stream<LocationSample> _locations;
  late final Stream<ActivitySnapshot> _activities;
  late final Stream<TrackerStatus> _statuses;
  NativeCommandLease? _commandLease;

  static Map<Object?, Object?> _eventMap(Object? event) {
    if (event is Map<Object?, Object?>) return event;
    if (event is Map) return event.cast<Object?, Object?>();
    throw const FormatException('Native tracker event must be a map.');
  }

  static Map<Object?, Object?> _nullableMap(Object? value) {
    if (value == null) return const <Object?, Object?>{};
    return _eventMap(value);
  }

  @override
  Stream<LocationSample> get locationStream => _locations;

  @override
  Stream<ActivitySnapshot> get activityStream => _activities;

  @override
  Stream<TrackerStatus> get statusStream => _statuses;

  @override
  Future<void> initialize() async {
    await _methodChannel.invokeMethod<Object?>('initialize');
  }

  @override
  Future<NativeTrackingProtocol> protocolInfo() async {
    try {
      final result = await _methodChannel.invokeMethod<Object?>(
        'getProtocolInfo',
      );
      return NativeTrackingProtocol.fromMap(_nullableMap(result));
    } on MissingPluginException {
      return NativeTrackingProtocol.legacy();
    }
  }

  @override
  Future<TrackingCapabilityReport> capabilities() async {
    try {
      final result = await _methodChannel.invokeMethod<Object?>(
        'getCapabilities',
      );
      return TrackingCapabilityReport.fromMap(_nullableMap(result));
    } on MissingPluginException {
      return const TrackingCapabilityReport(
        platform: 'unknown',
        backgroundTracking: true,
        activityRecognition: true,
        mockDetection: false,
        pauseResume: true,
        adaptiveSampling: true,
        terminatedRecovery: false,
      );
    }
  }

  @override
  Future<TrackingPermissionState> permissions({bool request = false}) async {
    final result = await _methodChannel.invokeMethod<Object?>(
      request ? 'requestPermissions' : 'getPermissionStatus',
    );
    return TrackingPermissionState.fromMap(_nullableMap(result));
  }

  @override
  Future<TrackingPermissionState> requestPermissionStep({
    required TrackingReadinessAction action,
    required int expectedReadinessRevision,
  }) async {
    final protocol = await protocolInfo();
    if (!protocol
        .supports(NativeTrackingCapabilities.stagedPermissionRequests)) {
      throw const TrackingNativeException(
        code: 'capability_unsupported',
        message: 'Staged permission requests are not supported by native code.',
      );
    }

    final current = await permissions();
    if (action == TrackingReadinessAction.requestNotification &&
        current.platform != 'android') {
      return current;
    }
    if (!_isPermissionRequestAction(action)) return current;

    try {
      final result = await _methodChannel.invokeMethod<Object?>(
        'requestPermissions',
        _permissionArgumentsForStep(
          action,
          expectedReadinessRevision,
        ),
      );
      return TrackingPermissionState.fromMap(_nullableMap(result));
    } on MissingPluginException catch (error) {
      throw TrackingNativeException(
        code: 'capability_unsupported',
        message: 'Native staged permission requests are not available.',
        cause: error,
      );
    } on PlatformException catch (error) {
      throw TrackingPermissionStepException(
        code: error.code,
        message: error.message ?? 'The native permission request failed.',
        permissionMayHaveChanged: true,
        cause: error.details,
      );
    }
  }

  static bool _isPermissionRequestAction(TrackingReadinessAction action) =>
      action == TrackingReadinessAction.requestForegroundLocation ||
      action == TrackingReadinessAction.requestBackgroundLocation ||
      action == TrackingReadinessAction.requestNotification ||
      action == TrackingReadinessAction.requestActivityRecognition;

  static Map<String, Object?> _permissionArgumentsForStep(
    TrackingReadinessAction action,
    int revision,
  ) =>
      <String, Object?>{
        'expectedReadinessRevision': revision,
        'location': action == TrackingReadinessAction.requestForegroundLocation,
        'backgroundLocation':
            action == TrackingReadinessAction.requestBackgroundLocation,
        'activityRecognition':
            action == TrackingReadinessAction.requestActivityRecognition,
        'notifications': action == TrackingReadinessAction.requestNotification,
        'background':
            action == TrackingReadinessAction.requestBackgroundLocation,
        'motion': action == TrackingReadinessAction.requestActivityRecognition,
      };

  @override
  Future<void> start({
    required String trackId,
    required TrackingConfig config,
  }) async {
    await _invokeTrackingCommand(
      legacyMethod: 'startTracking',
      leasedMethod: 'startTrackingV2',
      arguments: <String, Object?>{
        'trackId': trackId,
        'config': config.toMap()
      },
    );
  }

  @override
  Future<void> pause({required String trackId}) async {
    await _invokeTrackingCommand(
      legacyMethod: 'pauseTracking',
      leasedMethod: 'pauseTrackingV2',
      arguments: <String, Object?>{'trackId': trackId},
    );
  }

  @override
  Future<void> resume({
    required String trackId,
    required TrackingConfig config,
  }) async {
    await _invokeTrackingCommand(
      legacyMethod: 'resumeTracking',
      leasedMethod: 'resumeTrackingV2',
      arguments: <String, Object?>{
        'trackId': trackId,
        'config': config.toMap()
      },
    );
  }

  @override
  Future<void> stop({required String trackId, required String reason}) async {
    await _invokeTrackingCommand(
      legacyMethod: 'stopTracking',
      leasedMethod: 'stopTrackingV2',
      arguments: <String, Object?>{
        'trackId': trackId,
        'reason': reason,
      },
    );
  }

  @override
  Future<void> updateConfig({
    required String trackId,
    required TrackingConfig config,
  }) async {
    await _invokeTrackingCommand(
      legacyMethod: 'updateConfig',
      leasedMethod: 'updateConfigV2',
      arguments: <String, Object?>{
        'trackId': trackId,
        'config': config.toMap(),
      },
    );
  }

  @override
  Future<NativeCommandLease> acquireCommandLease({
    required String trackId,
    required String sessionControlToken,
  }) async {
    if (!(await protocolInfo()).supports(
      NativeTrackingCapabilities.commandLease,
    )) {
      return _commandLease = NativeCommandLease(
        trackId: trackId,
        sessionControlToken: sessionControlToken,
        supported: false,
      );
    }
    try {
      final response = _nullableMap(
        await _methodChannel.invokeMethod<Object?>(
          'acquireCommandLease',
          <String, Object?>{
            'trackId': trackId,
            'sessionControlToken': sessionControlToken,
          },
        ),
      );
      final leaseToken = response['engineLeaseToken']?.toString();
      if (leaseToken == null || leaseToken.isEmpty) {
        throw const TrackingNativeException(
          code: 'native_command_lease_invalid',
          message: 'Native code returned an invalid command lease.',
        );
      }
      return _commandLease = NativeCommandLease(
        trackId: trackId,
        sessionControlToken: sessionControlToken,
        supported: true,
        engineLeaseToken: leaseToken,
        commandRevision: (response['commandRevision'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException catch (error) {
      throw TrackingNativeException(
        code: error.code,
        message: error.message ?? 'Could not acquire the native command lease.',
        cause: error.details,
      );
    }
  }

  @override
  Future<void> releaseCommandLease({required String trackId}) async {
    final lease = _commandLease;
    if (lease != null && lease.trackId != trackId) return;
    _commandLease = null;
    if (lease == null || !lease.supported) return;
    try {
      await _methodChannel.invokeMethod<Object?>(
        'releaseCommandLease',
        <String, Object?>{
          'engineLeaseToken': lease.engineLeaseToken,
          'sessionControlToken': lease.sessionControlToken,
        },
      );
    } on MissingPluginException {
      // A mixed-version native binary may disappear during engine teardown.
    }
  }

  Future<void> _invokeTrackingCommand({
    required String legacyMethod,
    required String leasedMethod,
    required Map<String, Object?> arguments,
  }) async {
    final lease = _commandLease;
    if (lease == null || !lease.supported) {
      await _methodChannel.invokeMethod<Object?>(legacyMethod, arguments);
      return;
    }
    if (arguments['trackId'] != lease.trackId) {
      throw const TrackingNativeException(
        code: 'native_command_session_mismatch',
        message: 'The lifecycle command does not match the bound session.',
      );
    }
    final commandId = const Uuid().v4();
    final payload = <String, Object?>{
      ...arguments,
      'sessionControlToken': lease.sessionControlToken,
      'engineLeaseToken': lease.engineLeaseToken,
      'commandId': commandId,
      'expectedCommandRevision': lease.commandRevision,
    };
    try {
      final response = _nullableMap(
        await _methodChannel.invokeMethod<Object?>(leasedMethod, payload),
      );
      _commandLease = NativeCommandLease(
        trackId: lease.trackId,
        sessionControlToken: lease.sessionControlToken,
        supported: true,
        engineLeaseToken: lease.engineLeaseToken,
        commandRevision: (response['commandRevision'] as num?)?.toInt() ??
            lease.commandRevision + 1,
      );
    } on PlatformException catch (error) {
      throw TrackingNativeException(
        code: error.code,
        message: error.message ?? 'The native lifecycle command failed.',
        cause: error.details,
      );
    }
  }

  @override
  Future<bool> isRunning() async =>
      await _methodChannel.invokeMethod<bool>('isTracking') ?? false;

  @override
  Future<TrackerStatus> runtimeState() async {
    final result = await _methodChannel.invokeMethod<Object?>('getState');
    return TrackerStatus.fromMap(_nullableMap(result));
  }

  @override
  Future<Map<String, Object?>> nativeHealthState() async =>
      _stringKeyedMap(_nullableMap(
        await _methodChannel.invokeMethod<Object?>('getState'),
      ));

  @override
  Future<LocationSample?> lastLocation() async {
    final result =
        await _methodChannel.invokeMethod<Object?>('getLastLocation');
    return result == null ? null : LocationSample.fromMap(_eventMap(result));
  }

  @override
  Future<PendingNativeUserAction?> pendingUserAction() async {
    try {
      final result = await _methodChannel.invokeMethod<Object?>('getState');
      final state = _nullableMap(result);
      final pending = state['pendingUserAction'];
      return pending == null
          ? null
          : PendingNativeUserAction.fromMap(_eventMap(pending));
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> acknowledgePendingUserAction(String actionId) async {
    try {
      await _methodChannel.invokeMethod<Object?>(
        'acknowledgePendingUserAction',
        <String, Object?>{'actionId': actionId},
      );
    } on MissingPluginException {
      // Platforms without native notification actions have nothing to ack.
    }
  }

  @override
  Future<List<LocationSample>> pendingLocations() async {
    try {
      final result = await _methodChannel.invokeListMethod<Object?>(
        'getPendingLocations',
      );
      return (result ?? const <Object?>[])
          .map((event) => LocationSample.fromMap(_eventMap(event)))
          .toList(growable: false);
    } on MissingPluginException {
      return const <LocationSample>[];
    }
  }

  @override
  Future<NativePendingLocationPage> pendingLocationPage({
    String? cursor,
    int maxRecords = 100,
    int maxEncodedBytes = 256 * 1024,
  }) async {
    final protocol = await protocolInfo();
    if (!protocol.supports(NativeTrackingCapabilities.pagedJournal)) {
      throw const TrackingNativeException(
        code: 'capability_unsupported',
        message: 'Paged native pending locations are not supported.',
      );
    }
    try {
      final result = await _methodChannel.invokeMethod<Object?>(
        'getPendingLocationsPage',
        <String, Object?>{
          if (cursor != null) 'cursor': cursor,
          'maxRecords': maxRecords,
          'maxEncodedBytes': maxEncodedBytes,
        },
      );
      final page = _nullableMap(result);
      final events = switch (page['events']) {
        Iterable<Object?> values => values
            .map((event) => LocationSample.fromMap(_eventMap(event)))
            .toList(growable: false),
        _ => const <LocationSample>[],
      };
      return NativePendingLocationPage(
        events: events,
        nextCursor: page['nextCursor']?.toString(),
        hasMore: page['hasMore'] as bool? ?? false,
        encodedBytes: (page['encodedBytes'] as num?)?.toInt() ?? 0,
        remainingCount: (page['remainingCount'] as num?)?.toInt() ?? 0,
      );
    } on MissingPluginException catch (error) {
      throw TrackingNativeException(
        code: 'capability_unsupported',
        message: 'Native paged pending locations are not available.',
        cause: error,
      );
    } on PlatformException catch (error) {
      throw TrackingNativeException(
        code: error.code,
        message: error.message ?? 'Paged native pending locations failed.',
        cause: error.details,
      );
    }
  }

  @override
  Future<Map<String, Object?>> nativeJournalDiagnostic({
    bool performMaintenance = false,
  }) async {
    final protocol = await protocolInfo();
    if (!protocol.supports(
      NativeTrackingCapabilities.nativeJournalDiagnostics,
    )) {
      return const <String, Object?>{
        'healthy': false,
        'opened': false,
        'errorType': 'capability_unsupported',
        'errorMessage': 'Native journal diagnostics are not supported.',
      };
    }
    try {
      final result = await _methodChannel.invokeMethod<Object?>(
        'getNativeJournalDiagnostic',
        <String, Object?>{'performMaintenance': performMaintenance},
      );
      return _stringKeyedMap(_nullableMap(result));
    } on MissingPluginException {
      return const <String, Object?>{
        'healthy': false,
        'opened': false,
        'errorType': 'capability_unsupported',
        'errorMessage': 'Native journal diagnostics are not available.',
      };
    }
  }

  @override
  Future<int> clearNativeTrackData(String trackId) async {
    if (!(await protocolInfo()).supports(
      NativeTrackingCapabilities.trackScopedNativeClear,
    )) {
      throw const TrackingNativeException(
        code: 'capability_unsupported',
        message: 'Track-scoped native cleanup is not supported.',
      );
    }
    try {
      return await _methodChannel.invokeMethod<int>(
            'clearNativeTrackData',
            <String, Object?>{'trackId': trackId},
          ) ??
          0;
    } on MissingPluginException catch (error) {
      throw TrackingNativeException(
        code: 'capability_unsupported',
        message: 'Track-scoped native cleanup is not available.',
        cause: error,
      );
    } on PlatformException catch (error) {
      throw TrackingNativeException(
        code: error.code,
        message: error.message ?? 'Track-scoped native cleanup failed.',
        cause: error.details,
      );
    }
  }

  @override
  Future<void> acknowledgeLocations(Iterable<String> eventIds) async {
    final values = eventIds.toList(growable: false);
    if (values.isEmpty) return;
    try {
      await _methodChannel.invokeMethod<Object?>(
        'acknowledgeLocations',
        <String, Object?>{'eventIds': values},
      );
    } on MissingPluginException {
      // Older native adapters do not keep a durable pending queue.
    }
  }

  @override
  Future<bool> openAppSettings() async =>
      await _methodChannel.invokeMethod<bool>('openAppSettings') ?? false;

  @override
  Future<TrackingSettingsResult> openSettings(
    TrackingSettingsDestination destination,
  ) async {
    final requiredCapability = switch (destination) {
      TrackingSettingsDestination.application => null,
      TrackingSettingsDestination.locationServices =>
        NativeTrackingCapabilities.locationSettings,
      TrackingSettingsDestination.batteryOptimization =>
        NativeTrackingCapabilities.batteryOptimizationSettings,
    };
    if (requiredCapability != null &&
        !(await protocolInfo()).supports(requiredCapability)) {
      return TrackingSettingsResult(
        destination: destination,
        supported: false,
        opened: false,
        message: 'This native settings destination is not advertised.',
      );
    }
    final method = switch (destination) {
      TrackingSettingsDestination.application => 'openAppSettings',
      TrackingSettingsDestination.locationServices => 'openLocationSettings',
      TrackingSettingsDestination.batteryOptimization =>
        'openBatteryOptimizationSettings',
    };
    try {
      final opened = await _methodChannel.invokeMethod<bool>(method) ?? false;
      return TrackingSettingsResult(
        destination: destination,
        supported: true,
        opened: opened,
      );
    } on MissingPluginException {
      return TrackingSettingsResult(
        destination: destination,
        supported: false,
        opened: false,
        message: 'This native settings destination is not available.',
      );
    }
  }

  @override
  Future<BatteryOptimizationState> batteryOptimizationState() async {
    if (!(await protocolInfo()).supports(
      NativeTrackingCapabilities.batteryOptimizationSettings,
    )) {
      return const BatteryOptimizationState.unsupported();
    }
    try {
      final result = await _methodChannel.invokeMethod<Object?>(
        'getBatteryOptimizationStatus',
      );
      return BatteryOptimizationState.fromMap(_nullableMap(result));
    } on MissingPluginException {
      return const BatteryOptimizationState.unsupported();
    }
  }

  @override
  Future<void> dispose() async {
    final trackId = _commandLease?.trackId;
    if (trackId != null) await releaseCommandLease(trackId: trackId);
  }

  static Map<String, Object?> _stringKeyedMap(Map<Object?, Object?> map) =>
      Map<String, Object?>.unmodifiable(
        map.map((key, value) => MapEntry(key.toString(), value)),
      );
}
