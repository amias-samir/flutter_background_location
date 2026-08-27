import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_background_location_tracker/src/domain/activity_snapshot.dart';
import 'package:flutter_background_location_tracker/src/domain/export_models.dart';
import 'package:flutter_background_location_tracker/src/domain/location_sample.dart';
import 'package:flutter_background_location_tracker/src/domain/track_point.dart';
import 'package:flutter_background_location_tracker/src/domain/tracker_status.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_config.dart';
import 'package:flutter_background_location_tracker/src/export/track_export_service.dart';
import 'package:flutter_background_location_tracker/src/platform/native_tracker_adapter.dart';
import 'package:flutter_background_location_tracker/src/platform/tracker_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native method-channel v1 payloads match characterization fixture',
      () async {
    final fixture = jsonDecode(readFixture('native_channel_v1.json'))
        as Map<String, Object?>;
    final responses = fixture['responses']! as Map<String, Object?>;
    final expectedCalls = fixture['expectedCalls']! as List<Object?>;
    final channel = const MethodChannel('test/native_channel_v1');
    final calls = <Map<String, Object?>>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(<String, Object?>{
        'method': call.method,
        'arguments': _normalize(call.arguments),
      });
      return responses[call.method];
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final adapter = NativeTrackerAdapter(methodChannel: channel);
    await adapter.initialize();
    final capabilities = await adapter.capabilities();
    expect(capabilities.platform, 'android');
    expect(capabilities.rebootRestartBestEffort, isTrue);

    final status = await adapter.permissions();
    expect(status.canTrackInBackground, isTrue);
    final requested = await adapter.permissions(request: true);
    expect(requested.canTrackInBackground, isTrue);

    const config = TrackingConfig();
    await adapter.start(trackId: 'track-1', config: config);
    await adapter.pause(trackId: 'track-1');
    await adapter.resume(trackId: 'track-1', config: config);
    await adapter.stop(trackId: 'track-1', reason: 'fixture_done');
    await adapter.updateConfig(trackId: 'track-1', config: config);
    expect(await adapter.isRunning(), isTrue);

    final runtime = await adapter.runtimeState();
    expect(runtime.lifecycle, TrackerLifecycle.tracking);
    expect(runtime.trackId, 'track-1');

    final lastLocation = await adapter.lastLocation();
    expect(lastLocation?.eventId, 'event-1');
    expect(lastLocation?.capturedActivity?.type, TrackingActivityType.walking);

    final pendingAction = await adapter.pendingUserAction();
    expect(pendingAction?.action, NativeUserActionType.pause);
    expect(pendingAction?.reason, 'notification_paused');

    final pending = await adapter.pendingLocations();
    expect(pending.map((sample) => sample.eventId), <String>[
      'event-1',
      'event-2',
    ]);
    expect(pending.last.mockAssessment, MockLocationAssessment.detected);

    await adapter.acknowledgeLocations(<String>['event-1', 'event-2']);
    expect(await adapter.openAppSettings(), isTrue);
    await adapter.acknowledgePendingUserAction('action-1');

    expect(calls, expectedCalls);
  });

  test('export golden fixtures characterize resumed routes and rejected points',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    addTearDown(harness.repository.close);

    final trackId = await _createCharacterizationRoute(harness);
    final exporter = TrackExportService(
      repository: harness.repository,
      fileWriter: _DiscardingWriter(),
    );

    final geoJson = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.geoJson,
    );
    expect(
      geoJson.contents,
      _readGolden('exports/characterization_route.geojson'),
    );
    expect(geoJson.pointCount, 4);
    expect(geoJson.segmentCount, 2);

    final kml = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.kml,
    );
    expect(kml.contents, _readGolden('exports/characterization_route.kml'));

    final gpx = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.gpx,
    );
    expect(gpx.contents, _readGolden('exports/characterization_route.gpx'));
  });
}

String _readGolden(String relativePath) =>
    readFixture(relativePath).replaceFirst(RegExp(r'\n$'), '');

Object? _normalize(Object? value) {
  if (value is Map) {
    return value.map(
      (key, child) => MapEntry(key.toString(), _normalize(child)),
    );
  }
  if (value is Iterable) {
    return value.map(_normalize).toList(growable: false);
  }
  return value;
}

Future<String> _createCharacterizationRoute(RepositoryHarness harness) async {
  final trackId = await harness.createActiveTrack(
    trackId: 'characterization-route',
  );
  await harness.append(
    trackId: trackId,
    latitude: 27.7,
    longitude: 85.3,
    capturedAt: harness.now,
  );
  await harness.append(
    trackId: trackId,
    latitude: 27.7,
    longitude: 85.3,
    capturedAt: harness.now.add(const Duration(seconds: 15)),
  );

  harness.now = harness.now.add(const Duration(minutes: 1));
  await harness.repository.pauseTrack(trackId, reason: 'fixture_pause');

  harness.now = DateTime.utc(2026, 7, 20, 8, 10);
  await harness.repository.prepareResume(trackId);
  await harness.repository.markTrackActive(trackId);
  await harness.append(
    trackId: trackId,
    latitude: 95,
    longitude: 85.4,
    capturedAt: harness.now.add(const Duration(seconds: 1)),
    accepted: false,
    qualityFlags: TrackPointQualityFlag.invalidCoordinate,
    rejectionReason: 'invalid_coordinate',
  );
  await harness.append(
    trackId: trackId,
    latitude: 27.8,
    longitude: 85.4,
    capturedAt: harness.now.add(const Duration(seconds: 15)),
    activityType: TrackingActivityType.inVehicle,
    activityConfidence: 88,
    motionState: MotionState.moving,
  );
  await harness.append(
    trackId: trackId,
    latitude: 27.8,
    longitude: 85.4,
    capturedAt: harness.now.add(const Duration(seconds: 30)),
    activityType: TrackingActivityType.inVehicle,
    activityConfidence: 88,
    motionState: MotionState.moving,
  );

  harness.now = DateTime.utc(2026, 7, 20, 8, 11);
  await harness.repository.completeTrack(trackId, reason: 'fixture_done');
  return trackId;
}

final class _DiscardingWriter implements ExportFileWriter {
  @override
  Future<void> delete(String path) async {}

  @override
  Future<String> write({
    required String fileName,
    required String contents,
    String? mimeType,
  }) async =>
      fileName;
}
