import 'dart:convert';
import 'dart:io';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'test_support.dart';

/// LBO-00A: opt-in diagnostic fields in GeoJSON point features and GPX `fbl:`
/// extensions, so a field test can be explained from its exports alone.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const owner = TrackingOwner(userId: 'user-1', organizationId: 'org-1');
  const diagnosticKeys = <String>{
    'verticalAccuracy',
    'speed',
    'speedAccuracy',
    'heading',
    'headingAccuracy',
    'provider',
    'samplingProfile',
    'activitySource',
    'activityRawType',
    'activityEvidenceState',
    'activityAgeMs',
    'receiptDelayMs',
    'qualityPolicyVersion',
  };

  late RepositoryHarness harness;
  late String trackId;

  setUp(() async {
    harness = RepositoryHarness();
    await harness.initialize();
    trackId = await harness.createActiveTrack(trackId: 'diagnostics-route');
    final t0 = harness.now;
    Future<void> append({
      required int second,
      required double north,
      required bool accepted,
      String? rejectionReason,
    }) async {
      final at = t0.add(Duration(seconds: second));
      await harness.repository.appendPoint(
        PointWriteRequest(
          trackId: trackId,
          sample: LocationSample(
            latitude: 0.5 + north / 111195,
            longitude: 0.5,
            capturedAt: at,
            horizontalAccuracy: 3.5,
            verticalAccuracy: 3,
            speed: 0,
            speedAccuracy: 2.5,
            heading: 90,
            headingAccuracy: 45,
            provider: 'fused',
            eventId: 'event-$second',
            nativeReceivedAt: at.add(const Duration(milliseconds: 250)),
            samplingProfile: SamplingProfile.stationary,
            mockDetectionAvailable: true,
          ),
          activity: ActivitySnapshot(
            type: TrackingActivityType.stationary,
            confidence: 100,
            recordedAt: at.subtract(const Duration(minutes: 25)),
            evidenceState: ActivityEvidenceState.stale,
            source: 'android_activity_recognition',
            rawType: 'still',
            age: const Duration(minutes: 25),
          ),
          motionState: MotionState.stationary,
          accepted: accepted,
          qualityFlags: TrackPointQualityFlag.none,
          rejectionReason: rejectionReason,
          qualityPolicyVersion: 2,
        ),
      );
    }

    await append(second: 0, north: 0, accepted: true);
    await append(
      second: 10,
      north: 6,
      accepted: false,
      rejectionReason: FixQualityIssue.stationaryHold,
    );
    await append(second: 20, north: 40, accepted: true);
    // Only completed tracks can be exported.
    await harness.repository.completeTrack(trackId, reason: 'finished');
  });

  tearDown(() => harness.repository.close());

  TrackExportService exporter() => TrackExportService(
        repository: harness.repository,
        fileWriter: _DiscardingWriter(),
      );

  test('GeoJSON point features carry diagnostics only when asked', () async {
    Future<List<Map<String, Object?>>> featureProperties(
      TrackExportOptions options,
    ) async {
      final artifact = await exporter().renderTrack(
        trackId: trackId,
        format: TrackExportFormat.geoJson,
        options: options,
      );
      final json = jsonDecode(artifact.contents) as Map<String, Object?>;
      return <Map<String, Object?>>[
        for (final feature in json['features']! as List<Object?>)
          if ((feature! as Map)['geometry'] case {'type': 'Point'})
            ((feature as Map)['properties']! as Map).cast<String, Object?>(),
      ];
    }

    final plain = await featureProperties(
      const TrackExportOptions(
        includeGeoJsonPointFeatures: true,
        includeRejectedPoints: true,
      ),
    );
    expect(plain, hasLength(3));
    for (final properties in plain) {
      expect(properties.keys.toSet().intersection(diagnosticKeys), isEmpty);
    }

    final diagnostic = await featureProperties(
      const TrackExportOptions(
        includeGeoJsonPointFeatures: true,
        includeRejectedPoints: true,
        includeDiagnosticProperties: true,
      ),
    );
    expect(diagnostic, hasLength(3));
    final held = diagnostic.singleWhere(
      (properties) => properties['accepted'] == false,
    );
    expect(held['rejectionReason'], FixQualityIssue.stationaryHold);
    expect(held.keys, containsAll(diagnosticKeys));
    expect(held['samplingProfile'], 'stationary');
    expect(held['activityRawType'], 'still');
    expect(held['activityEvidenceState'], 'stale');
    expect(held['activityAgeMs'], 25 * 60 * 1000);
    expect(held['receiptDelayMs'], 250);
    expect(held['speedAccuracy'], 2.5);
    expect(held['qualityPolicyVersion'], 2);
  });

  test('GPX fbl extensions carry diagnostics only when asked', () async {
    Iterable<XmlElement> extensions(String gpx) => XmlDocument.parse(gpx)
        .findAllElements('trkpt')
        .expand((point) => point.findElements('extensions'))
        .expand((extension) => extension.childElements);

    final plain = await exporter().renderTrack(
      trackId: trackId,
      format: TrackExportFormat.gpx,
    );
    expect(
      extensions(plain.contents).map((element) => element.localName).toSet(),
      isNot(contains('speedAccuracy')),
    );

    final diagnostic = await exporter().renderTrack(
      trackId: trackId,
      format: TrackExportFormat.gpx,
      options: const TrackExportOptions(includeDiagnosticProperties: true),
    );
    final elements = extensions(diagnostic.contents).toList();
    final names = elements.map((element) => element.localName).toSet();
    expect(names, containsAll(<String>['samplingProfile', 'speedAccuracy']));
    expect(
      elements.firstWhere((e) => e.localName == 'activityAgeMs').innerText,
      '${25 * 60 * 1000}',
    );
  });

  test('the incremental exporter writes the same diagnostics', () async {
    final root = await Directory.systemTemp.createTemp('fbl-diagnostics-');
    addTearDown(() => root.delete(recursive: true));
    final service = TrackExportServiceV2(
      repository: harness.repository,
      owner: owner,
      useAndroidNativeDestination: false,
      exportDirectoryProvider: () async => Directory('${root.path}/exports'),
      shareCacheDirectoryProvider: () async => Directory('${root.path}/cache'),
    );
    final operation = await service.exportTrackV2(
      TrackExportRequest(
        trackId: trackId,
        format: TrackExportFormat.gpx,
        fileName: 'diagnostics',
        options: const TrackExportOptions(includeDiagnosticProperties: true),
      ),
    );
    final result = await operation.result;
    final gpx = await File(result.destination.localFilePath!).readAsString();
    final names = XmlDocument.parse(gpx)
        .findAllElements('trkpt')
        .expand((point) => point.findElements('extensions'))
        .expand((extension) => extension.childElements)
        .map((element) => element.localName)
        .toSet();
    expect(names, containsAll(<String>['samplingProfile', 'receiptDelayMs']));
  });
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
