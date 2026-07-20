import 'package:flutter/services.dart';

import '../domain/activity_snapshot.dart';
import '../domain/capability_report.dart';
import '../domain/location_sample.dart';
import '../domain/permission_state.dart';
import '../domain/tracker_status.dart';
import '../domain/tracking_config.dart';
import 'tracker_adapter.dart';

final class NativeTrackerAdapter
    implements TrackerAdapter, NativeUserActionAdapter {
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
  Future<void> start({
    required String trackId,
    required TrackingConfig config,
  }) async {
    await _methodChannel.invokeMethod<Object?>(
      'startTracking',
      <String, Object?>{'trackId': trackId, 'config': config.toMap()},
    );
  }

  @override
  Future<void> pause({required String trackId}) async {
    await _methodChannel.invokeMethod<Object?>(
      'pauseTracking',
      <String, Object?>{'trackId': trackId},
    );
  }

  @override
  Future<void> resume({
    required String trackId,
    required TrackingConfig config,
  }) async {
    await _methodChannel.invokeMethod<Object?>(
      'resumeTracking',
      <String, Object?>{'trackId': trackId, 'config': config.toMap()},
    );
  }

  @override
  Future<void> stop({required String trackId, required String reason}) async {
    await _methodChannel
        .invokeMethod<Object?>('stopTracking', <String, Object?>{
      'trackId': trackId,
      'reason': reason,
    });
  }

  @override
  Future<void> updateConfig({
    required String trackId,
    required TrackingConfig config,
  }) async {
    await _methodChannel
        .invokeMethod<Object?>('updateConfig', <String, Object?>{
      'trackId': trackId,
      'config': config.toMap(),
    });
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
  Future<void> dispose() async {}
}
