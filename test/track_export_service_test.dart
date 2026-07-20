import 'dart:convert';

import 'package:flutter_background_location/src/domain/activity_snapshot.dart';
import 'package:flutter_background_location/src/domain/export_models.dart';
import 'package:flutter_background_location/src/domain/track_point.dart';
import 'package:flutter_background_location/src/domain/tracker_status.dart';
import 'package:flutter_background_location/src/export/track_export_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'test_support.dart';

final class _MemoryWriter implements ExportFileWriter {
  @override
  Future<void> delete(String path) async {}

  @override
  Future<String> write({
    required String fileName,
    required String contents,
  }) async =>
      '/exports/$fileName';
}

Iterable<XmlElement> _elements(XmlDocument document, String localName) =>
    document.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == localName);

void main() {
  late RepositoryHarness harness;
  late TrackExportService exporter;

  setUp(() async {
    harness = RepositoryHarness();
    await harness.initialize();
    exporter = TrackExportService(
      repository: harness.repository,
      fileWriter: _MemoryWriter(),
    );
  });

  tearDown(() => harness.repository.close());

  test('all formats parse and preserve a single-point track', () async {
    final trackId = await harness.createActiveTrack(trackId: 'one-point');
    await harness.append(
      trackId: trackId,
      latitude: 27.7172,
      longitude: 85.324,
      capturedAt: harness.now,
      isMocked: true,
      mockDetectionAvailable: true,
    );
    await harness.repository.completeTrack(trackId, reason: 'finished');

    final geoJson = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.geoJson,
    );
    final json = jsonDecode(geoJson.contents) as Map<String, Object?>;
    final features = json['features']! as List<Object?>;
    final route = features.first! as Map<String, Object?>;
    expect(json['type'], 'FeatureCollection');
    expect(route['geometry'], isNull);
    expect(features, hasLength(2));
    expect(geoJson.pointCount, 1);
    expect(geoJson.segmentCount, 1);

    final kml = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.kml,
    );
    final kmlDocument = XmlDocument.parse(kml.contents);
    expect(_elements(kmlDocument, 'LineString'), isEmpty);
    expect(_elements(kmlDocument, 'Point'), hasLength(1));

    final gpx = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.gpx,
    );
    final gpxDocument = XmlDocument.parse(gpx.contents);
    expect(_elements(gpxDocument, 'trkseg'), hasLength(1));
    expect(_elements(gpxDocument, 'trkpt'), hasLength(1));
    expect(
        _elements(gpxDocument, 'mockAssessment').single.innerText, 'detected');
  });

  test('GeoJSON retains singleton geometry without point metadata', () async {
    final trackId = await harness.createActiveTrack(trackId: 'bare-point');
    await harness.append(
      trackId: trackId,
      latitude: 27.7172,
      longitude: 85.324,
      capturedAt: harness.now,
    );
    await harness.repository.completeTrack(trackId, reason: 'finished');

    final artifact = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.geoJson,
      options: const TrackExportOptions(includePointProperties: false),
    );
    final json = jsonDecode(artifact.contents) as Map<String, Object?>;
    final features = json['features']! as List<Object?>;
    final singleton = features[1]! as Map<String, Object?>;
    final geometry = singleton['geometry']! as Map<String, Object?>;

    expect(features, hasLength(2));
    expect(geometry['type'], 'Point');
    expect(geometry['coordinates'], <Object?>[85.324, 27.7172]);
  });

  test('all formats preserve segments and exclude rejected points by default',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'multi-segment');
    await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
      capturedAt: harness.now,
    );
    await harness.append(
      trackId: trackId,
      latitude: 50,
      longitude: 50,
      capturedAt: harness.now.add(const Duration(seconds: 1)),
      accepted: false,
      qualityFlags: TrackPointQualityFlag.poorAccuracy,
      rejectionReason: 'poor_accuracy',
    );
    await harness.repository.pauseTrack(trackId, reason: 'overnight');

    harness.now = harness.now.add(const Duration(days: 1));
    await harness.repository.prepareResume(trackId);
    await harness.repository.markTrackActive(trackId);
    await harness.append(
      trackId: trackId,
      latitude: 28,
      longitude: 86,
      capturedAt: harness.now,
      activityType: TrackingActivityType.inVehicle,
      activityConfidence: 90,
      motionState: MotionState.moving,
    );
    await harness.append(
      trackId: trackId,
      latitude: 28.001,
      longitude: 86.001,
      capturedAt: harness.now.add(const Duration(seconds: 15)),
      activityType: TrackingActivityType.inVehicle,
      activityConfidence: 90,
      motionState: MotionState.moving,
    );
    await harness.repository.completeTrack(trackId, reason: 'finished');

    final geoJson = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.geoJson,
    );
    final json = jsonDecode(geoJson.contents) as Map<String, Object?>;
    final features = json['features']! as List<Object?>;
    final route = features.first! as Map<String, Object?>;
    final geometry = route['geometry']! as Map<String, Object?>;
    final lines = geometry['coordinates']! as List<Object?>;
    final pointSequences = features.skip(1).map((feature) {
      final properties = (feature! as Map<String, Object?>)['properties']!
          as Map<String, Object?>;
      return properties['sequence'];
    });
    expect(geometry['type'], 'MultiLineString');
    expect(lines, hasLength(1),
        reason: 'The one-point segment must not become a LineString.');
    expect(lines.single! as List<Object?>, hasLength(2));
    expect(pointSequences, <Object?>[1, 3, 4]);
    expect(geoJson.pointCount, 3);
    expect(geoJson.segmentCount, 2);

    final kml = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.kml,
    );
    final kmlDocument = XmlDocument.parse(kml.contents);
    expect(_elements(kmlDocument, 'LineString'), hasLength(1));
    expect(_elements(kmlDocument, 'Point'), hasLength(1));

    final gpx = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.gpx,
    );
    final gpxDocument = XmlDocument.parse(gpx.contents);
    final segments = _elements(gpxDocument, 'trkseg').toList();
    expect(segments, hasLength(2));
    expect(_elements(gpxDocument, 'trkpt'), hasLength(3));
    expect(_elements(XmlDocument.parse(segments[0].toXmlString()), 'trkpt'),
        hasLength(1));
    expect(_elements(XmlDocument.parse(segments[1].toXmlString()), 'trkpt'),
        hasLength(2));
  });

  test('incomplete tracks require an explicit snapshot option', () async {
    final trackId = await harness.createActiveTrack(trackId: 'active-track');
    await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
    );

    await expectLater(
      exporter.renderTrack(
        trackId: trackId,
        format: TrackExportFormat.geoJson,
      ),
      throwsStateError,
    );
    final snapshot = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.geoJson,
      options: const TrackExportOptions(allowIncompleteTrackSnapshot: true),
    );
    expect(jsonDecode(snapshot.contents), isA<Map<String, Object?>>());
  });

  test('invalid rejected coordinates remain diagnostics, not geometry',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'diagnostics');
    await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
    );
    await harness.append(
      trackId: trackId,
      latitude: 99,
      longitude: 85.3,
      accepted: false,
      qualityFlags: TrackPointQualityFlag.invalidCoordinate,
      rejectionReason: 'invalid_coordinate',
    );
    await harness.repository.completeTrack(trackId, reason: 'finished');
    const options = TrackExportOptions(includeRejectedPoints: true);

    final geoJson = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.geoJson,
      options: options,
    );
    final json = jsonDecode(geoJson.contents) as Map<String, Object?>;
    final features = json['features']! as List<Object?>;
    final rejected = features.cast<Map<String, Object?>>().singleWhere(
          (feature) =>
              (feature['properties']! as Map<String, Object?>)['accepted'] ==
              false,
        );
    expect(rejected['geometry'], isNull);
    expect(geoJson.pointCount, 2);

    final kml = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.kml,
      options: options,
    );
    final kmlDocument = XmlDocument.parse(kml.contents);
    expect(_elements(kmlDocument, 'Point'), hasLength(1));
    expect(kml.contents, isNot(contains('99.0000000')));

    final gpx = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.gpx,
      options: options,
    );
    final gpxDocument = XmlDocument.parse(gpx.contents);
    expect(_elements(gpxDocument, 'trkpt'), hasLength(1));
    expect(gpx.contents, isNot(contains('lat="99.0000000"')));
  });

  test('local timestamp export includes an explicit UTC offset', () async {
    final trackId = await harness.createActiveTrack(trackId: 'local-time');
    await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
    );
    await harness.repository.completeTrack(trackId, reason: 'finished');

    final artifact = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.gpx,
      options: const TrackExportOptions(useUtcTimestamps: false),
    );
    final document = XmlDocument.parse(artifact.contents);
    for (final time in _elements(document, 'time')) {
      expect(time.innerText, matches(RegExp(r'[+-]\d{2}:\d{2}$')));
    }
  });
}
