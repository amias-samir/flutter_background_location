import 'dart:convert';

import 'package:flutter_background_location_tracker/src/domain/activity_snapshot.dart';
import 'package:flutter_background_location_tracker/src/domain/export_models.dart';
import 'package:flutter_background_location_tracker/src/domain/track_point.dart';
import 'package:flutter_background_location_tracker/src/domain/tracker_status.dart';
import 'package:flutter_background_location_tracker/src/export/track_export_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'test_support.dart';

final class _MemoryWriter implements ExportFileWriter {
  String? lastFileName;
  String? lastMimeType;

  @override
  Future<void> delete(String path) async {}

  @override
  Future<String> write({
    required String fileName,
    required String contents,
    String? mimeType,
  }) async {
    lastFileName = fileName;
    lastMimeType = mimeType;
    return '/exports/$fileName';
  }
}

Iterable<XmlElement> _elements(XmlDocument document, String localName) =>
    document.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == localName);

void main() {
  late RepositoryHarness harness;
  late TrackExportService exporter;
  late _MemoryWriter writer;

  setUp(() async {
    harness = RepositoryHarness();
    await harness.initialize();
    writer = _MemoryWriter();
    exporter = TrackExportService(
      repository: harness.repository,
      fileWriter: writer,
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
    expect(features, hasLength(1));
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

  test('GeoJSON can include point features for diagnostics', () async {
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
      options: const TrackExportOptions(includeGeoJsonPointFeatures: true),
    );
    final json = jsonDecode(artifact.contents) as Map<String, Object?>;
    final features = json['features']! as List<Object?>;
    final singleton = features[1]! as Map<String, Object?>;
    final geometry = singleton['geometry']! as Map<String, Object?>;

    expect(features, hasLength(2));
    expect(geometry['type'], 'Point');
    expect(geometry['coordinates'], <Object?>[85.324, 27.7172]);
  });

  test('GeoJSON exports multiple route segments as a MultiLineString',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'multi-line');
    await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
      capturedAt: harness.now,
    );
    await harness.append(
      trackId: trackId,
      latitude: 27.701,
      longitude: 85.301,
      capturedAt: harness.now.add(const Duration(seconds: 15)),
    );
    await harness.repository.pauseTrack(trackId, reason: 'break');
    await harness.repository.prepareResume(trackId);
    await harness.repository.markTrackActive(trackId);
    await harness.append(
      trackId: trackId,
      latitude: 27.8,
      longitude: 85.4,
      capturedAt: harness.now.add(const Duration(minutes: 1)),
    );
    await harness.append(
      trackId: trackId,
      latitude: 27.801,
      longitude: 85.401,
      capturedAt: harness.now.add(const Duration(minutes: 1, seconds: 15)),
    );
    await harness.repository.completeTrack(trackId, reason: 'finished');

    final artifact = await exporter.renderTrack(
      trackId: trackId,
      format: TrackExportFormat.geoJson,
    );
    final json = jsonDecode(artifact.contents) as Map<String, Object?>;
    final features = json['features']! as List<Object?>;
    final route = features.single! as Map<String, Object?>;
    final geometry = route['geometry']! as Map<String, Object?>;
    final lines = geometry['coordinates']! as List<Object?>;

    expect(geometry['type'], 'MultiLineString');
    expect(lines, hasLength(2));
    expect(lines.first! as List<Object?>, hasLength(2));
    expect(lines.last! as List<Object?>, hasLength(2));
  });

  test('exportTrack accepts a user supplied file name', () async {
    final trackId = await harness.createActiveTrack(trackId: 'renamed-track');
    await harness.append(
      trackId: trackId,
      latitude: 27.7172,
      longitude: 85.324,
      capturedAt: harness.now,
    );
    await harness.repository.completeTrack(trackId, reason: 'finished');

    final result = await exporter.exportTrack(
      trackId: trackId,
      format: TrackExportFormat.gpx,
      fileName: 'morning ride',
    );

    expect(writer.lastFileName, 'morning ride.gpx');
    expect(writer.lastMimeType, 'application/gpx+xml');
    expect(result.fileName, 'morning ride.gpx');
  });

  test('exportTrack corrects mismatched custom extensions', () async {
    final trackId = await harness.createActiveTrack(trackId: 'geojson-name');
    await harness.append(
      trackId: trackId,
      latitude: 27.7172,
      longitude: 85.324,
      capturedAt: harness.now,
    );
    await harness.repository.completeTrack(trackId, reason: 'finished');

    final result = await exporter.exportTrack(
      trackId: trackId,
      format: TrackExportFormat.geoJson,
      fileName: 'route.kml',
    );

    expect(writer.lastFileName, 'route.geojson');
    expect(result.fileName, 'route.geojson');
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
    expect(features, hasLength(1));
    expect(geometry['type'], 'LineString');
    expect(lines, hasLength(2),
        reason: 'The one-point segment must not become a LineString.');
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
    const options = TrackExportOptions(
      includeRejectedPoints: true,
      includeGeoJsonPointFeatures: true,
    );

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
