import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_background_location_tracker/src/export/incremental_track_export.dart';
import 'package:flutter_background_location_tracker/src/storage/sqlite_track_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'test_support.dart';

// Stop records in GeoJSON, GPX and KML exports. Every coordinate is generated.

const _owner = TrackingOwner(
  userId: 'stop-export-user',
  organizationId: 'stop-export-organization',
);
const _metersPerDegree = 111195.07973436875;

/// Writes, as quality policy 3 would, an arrival fix, a stop held from 5 s to
/// 430 s after [from], its departure and one onward fix.
Future<TrackStop> _recordStop(
  SqliteTrackRepository repository,
  String trackId,
  DateTime from, {
  required String prefix,
  required double latitude,
}) async {
  PointWriteRequest fix(int second,
          {required bool accepted, double north = 0}) =>
      PointWriteRequest(
        trackId: trackId,
        sample: LocationSample(
          latitude: latitude + north / _metersPerDegree,
          longitude: 0.5,
          capturedAt: from.add(Duration(seconds: second)),
          horizontalAccuracy: 4,
          provider: 'fused',
          eventId: '$prefix-$second',
          trackId: trackId,
        ),
        activity: const ActivitySnapshot.unknown(),
        motionState: MotionState.unknown,
        accepted: accepted,
        qualityFlags: accepted
            ? TrackPointQualityFlag.none
            : TrackPointQualityFlag.duringStop,
        rejectionReason: accepted ? null : FixQualityIssue.stationaryHold,
        qualityPolicyVersion: 3,
      );

  final arrival = await repository.appendPoint(fix(0, accepted: true));
  await repository.appendPointWithStop(
    fix(130, accepted: false, north: 3),
    null,
    TrackStopOpen(
      kind: TrackStopKind.dwell,
      latitude: latitude,
      longitude: 0.5,
      centreSigmaMeters: 2.5,
      radiusMeters: 25,
      startedAt: from.add(const Duration(seconds: 5)),
      qualityPolicyVersion: 3,
      arrivalPointId: arrival.id,
      priorEvidenceCount: 3,
    ),
  );
  await repository.appendPointWithStop(
    fix(400, accepted: false, north: -2),
    null,
    const TrackStopExtend(),
  );
  final departure = await repository.appendPointWithStop(
    fix(430, accepted: true, north: 60),
    null,
    const TrackStopClose(departure: true),
  );
  await repository.appendPoint(fix(460, accepted: true, north: 120));
  return departure.stop!;
}

Iterable<XmlElement> _elements(XmlNode node, String localName) =>
    node.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == localName);

String _child(XmlElement element, String localName) =>
    _elements(element, localName).first.innerText.trim();

List<Map<String, Object?>> _geoJsonStops(String contents) {
  final document = jsonDecode(contents) as Map<String, Object?>;
  return <Map<String, Object?>>[
    for (final feature in document['features']! as List<Object?>)
      if (((feature! as Map<String, Object?>)['properties']
              as Map<String, Object?>)['featureType'] ==
          'stop')
        feature as Map<String, Object?>,
  ];
}

List<XmlElement> _kmlStops(String contents) => _elements(
      XmlDocument.parse(contents),
      'Placemark',
    ).where((placemark) => _child(placemark, 'name') == 'Stop').toList();

Map<String, String> _kmlData(XmlElement placemark) => <String, String>{
      for (final data in _elements(placemark, 'Data'))
        data.getAttribute('name')!: _child(data, 'value'),
    };

/// The GPX root's direct children, by local name, in document order.
List<String> _gpxChildren(String contents) => XmlDocument.parse(contents)
    .rootElement
    .childElements
    .map((element) => element.name.local)
    .toList();

Map<String, String> _gpxExtensions(XmlElement waypoint) => <String, String>{
      for (final element
          in _elements(waypoint, 'extensions').single.childElements)
        element.name.local: element.innerText.trim(),
    };

final class _MemorySink implements IncrementalExportSink {
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  IncrementalExportDescriptor? _descriptor;

  String get contents => utf8.decode(_bytes.takeBytes());

  @override
  Future<void> open(IncrementalExportDescriptor value) async {
    _descriptor = value;
  }

  @override
  Future<void> addUtf8(List<int> value) async => _bytes.add(value);

  @override
  Future<TrackExportDestination> commit() async => TrackExportDestination(
        displayName: _descriptor!.fileName,
        mimeType: _descriptor!.mimeType,
        localFilePath: '/memory/${_descriptor!.fileName}',
        userVisible: false,
      );

  @override
  Future<void> abort() async {}
}

final class _UnusedWriter implements ExportFileWriter {
  @override
  Future<void> delete(String path) async {}

  @override
  Future<String> write({
    required String fileName,
    required String contents,
    String? mimeType,
  }) async =>
      '/unused/$fileName';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final t0 = DateTime.utc(2026, 10, 19, 5);

  group('track exports', () {
    late RepositoryHarness harness;
    late String trackId;
    late TrackStop stop;
    late TrackExportService legacy;

    setUp(() async {
      harness = RepositoryHarness()..now = t0;
      await harness.initialize();
      trackId = await harness.createActiveTrack(trackId: 'stop-export');
      stop = await _recordStop(
        harness.repository,
        trackId,
        t0,
        prefix: 'day',
        latitude: 0.5,
      );
      harness.now = t0.add(const Duration(minutes: 10));
      await harness.repository.completeTrack(trackId, reason: 'finished');
      legacy = TrackExportService(
        repository: harness.repository,
        fileWriter: _UnusedWriter(),
      );
    });

    tearDown(() => harness.repository.close());

    Future<String> render(
      TrackExportFormat format, [
      TrackExportOptions options = const TrackExportOptions(),
    ]) async =>
        (await legacy.renderTrack(
          trackId: trackId,
          format: format,
          options: options,
        ))
            .contents;

    Future<String> stream(TrackExportFormat format) async {
      late _MemorySink sink;
      await IncrementalTrackExportService(
        repository: harness.repository,
        pointPageSize: 1,
        segmentPageSize: 1,
        sinkFactory: () => sink = _MemorySink(),
      )
          .start(
            // The repository harness creates routes for this owner.
            owner: const TrackingOwner(
              userId: 'user-1',
              organizationId: 'org-1',
            ),
            trackId: trackId,
            format: format,
          )
          .result;
      return sink.contents;
    }

    test('GeoJSON adds one Point feature per stop', () async {
      final contents = await render(TrackExportFormat.geoJson);
      final feature = _geoJsonStops(contents).single;
      expect(
        (feature['geometry']! as Map<String, Object?>)['coordinates'],
        <double>[stop.longitude, stop.latitude],
      );
      final properties = feature['properties']! as Map<String, Object?>;
      expect(properties['stopId'], stop.id);
      expect(properties['kind'], TrackStopKind.dwell);
      expect(
          DateTime.parse(properties['startedAt']! as String), stop.startedAt);
      expect(DateTime.parse(properties['endedAt']! as String), stop.endedAt);
      expect(properties['durationSeconds'], 425);
      expect(properties['evidenceCount'], 5);
      expect(properties['radiusMeters'], 25.0);

      final route = (jsonDecode(contents) as Map<String, Object?>)['features']!
          as List<Object?>;
      final line = (route.first! as Map<String, Object?>)['geometry']!
          as Map<String, Object?>;
      expect(line['coordinates'], hasLength(3),
          reason: 'held fixes stay out of the route');
    });

    test('GPX adds a waypoint per stop before the track', () async {
      final contents = await render(TrackExportFormat.gpx);
      final children = _gpxChildren(contents);
      expect(children, <String>['metadata', 'wpt', 'trk']);
      final waypoint = _elements(XmlDocument.parse(contents), 'wpt').single;
      expect(double.parse(waypoint.getAttribute('lat')!), stop.latitude);
      expect(double.parse(waypoint.getAttribute('lon')!), stop.longitude);
      expect(DateTime.parse(_child(waypoint, 'time')), stop.startedAt);
      expect(_child(waypoint, 'name'), 'Stop');
      expect(_child(waypoint, 'desc'), 'Stayed 7 min');
      expect(_child(waypoint, 'type'), 'stop');
      final extensions = _gpxExtensions(waypoint);
      expect(extensions['durationSeconds'], '425');
      expect(DateTime.parse(extensions['endedAt']!), stop.endedAt);
      expect(extensions['kind'], TrackStopKind.dwell);
      expect(extensions['stopId'], stop.id);
      expect(extensions, isNot(contains('featureType')));
      expect(_elements(XmlDocument.parse(contents), 'trkpt'), hasLength(3));
    });

    test('KML adds a timed Placemark per stop', () async {
      final placemark = _kmlStops(await render(TrackExportFormat.kml)).single;
      expect(DateTime.parse(_child(placemark, 'begin')), stop.startedAt);
      expect(DateTime.parse(_child(placemark, 'end')), stop.endedAt);
      expect(_child(placemark, 'description'), 'Stayed 7 min');
      final data = _kmlData(placemark);
      expect(data['durationSeconds'], '425');
      expect(data['featureType'], 'stop');
      final coordinates = _child(placemark, 'coordinates').split(',');
      expect(double.parse(coordinates[0]), stop.longitude);
      expect(double.parse(coordinates[1]), stop.latitude);
    });

    test('includeStops false leaves stops out of every format', () async {
      const options = TrackExportOptions(includeStops: false);
      expect(
        _geoJsonStops(await render(TrackExportFormat.geoJson, options)),
        isEmpty,
      );
      expect(
        _gpxChildren(await render(TrackExportFormat.gpx, options)),
        <String>['metadata', 'trk'],
      );
      expect(_kmlStops(await render(TrackExportFormat.kml, options)), isEmpty);
    });

    test('streamed exports write the same stops', () async {
      expect(
        jsonDecode(await stream(TrackExportFormat.geoJson)),
        jsonDecode(await render(TrackExportFormat.geoJson)),
      );

      final streamedGpx = await stream(TrackExportFormat.gpx);
      final legacyGpx = await render(TrackExportFormat.gpx);
      expect(_gpxChildren(streamedGpx), _gpxChildren(legacyGpx));
      final streamedWaypoint =
          _elements(XmlDocument.parse(streamedGpx), 'wpt').single;
      final legacyWaypoint =
          _elements(XmlDocument.parse(legacyGpx), 'wpt').single;
      expect(streamedWaypoint.attributes.map((value) => value.toString()),
          legacyWaypoint.attributes.map((value) => value.toString()));
      for (final name in <String>['time', 'name', 'desc', 'type']) {
        expect(_child(streamedWaypoint, name), _child(legacyWaypoint, name));
      }
      expect(_gpxExtensions(streamedWaypoint), _gpxExtensions(legacyWaypoint));

      final streamedKml = _kmlStops(await stream(TrackExportFormat.kml)).single;
      final legacyKml = _kmlStops(await render(TrackExportFormat.kml)).single;
      for (final name in <String>[
        'begin',
        'end',
        'description',
        'coordinates'
      ]) {
        expect(_child(streamedKml, name), _child(legacyKml, name));
      }
      expect(_kmlData(streamedKml), _kmlData(legacyKml));
    });
  });

  group('facade exports', () {
    late RepositoryHarness harness;
    late FakeTrackerAdapter adapter;
    late FakeExportFileWriter writer;

    setUp(() async {
      harness = RepositoryHarness()..now = t0;
      await harness.initialize();
      adapter = FakeTrackerAdapter();
      writer = FakeExportFileWriter();
    });

    tearDown(() => harness.repository.close());

    test('a Trip export lists the stops of every leg in order', () async {
      final controller = await TrackingClient.openWithTrips(
        owner: _owner,
        repository: harness.repository,
        trackerAdapter: adapter,
        exportFileWriter: writer,
        clock: () => harness.now,
      );
      addTearDown(controller.dispose);
      final started = await controller.startTrip(
        const TripStartRequest(
          routeId: 'stop_export_trip',
          operationId: 'start-stop-trip',
        ),
      );
      final first = await _recordStop(
        harness.repository,
        started.leg.trackId,
        t0,
        prefix: 'day-1',
        latitude: 0.5,
      );
      harness.now = t0.add(const Duration(minutes: 10));
      await controller.endCurrentDay(operationId: 'end-stop-day-1');

      final day2 = t0.add(const Duration(days: 1));
      harness.now = day2;
      final leg2 = (await controller.continueTrip(
        started.trip.id,
        operationId: 'continue-stop-day-2',
      ))
          .leg;
      final second = await _recordStop(
        harness.repository,
        leg2.trackId,
        day2,
        prefix: 'day-2',
        latitude: 0.6,
      );
      harness.now = day2.add(const Duration(minutes: 10));
      await controller.completeTrip(
        started.trip.id,
        operationId: 'complete-stop-trip',
      );

      final ids = <String>[first.id, second.id];
      expect(
        (await (controller as TrackingStopController)
                .listTripStops(started.trip.id))
            .map((stop) => stop.id),
        ids,
      );
      for (final format in TrackExportFormat.values) {
        final result = await controller.exportTrip(
          tripId: started.trip.id,
          format: format,
          fileName: 'stop_trip_${format.name}',
        );
        final contents = writer.files[result.path]!;
        switch (format) {
          case TrackExportFormat.geoJson:
            expect(
              _geoJsonStops(contents).map(
                (feature) =>
                    (feature['properties']! as Map<String, Object?>)['stopId'],
              ),
              ids,
            );
          case TrackExportFormat.gpx:
            expect(
              _elements(XmlDocument.parse(contents), 'wpt')
                  .map((waypoint) => _gpxExtensions(waypoint)['stopId']),
              ids,
            );
            expect(_gpxChildren(contents).indexOf('trk'), 3);
          case TrackExportFormat.kml:
            expect(
              _kmlStops(contents)
                  .map((placemark) => _kmlData(placemark)['stopId']),
              ids,
            );
        }
      }
    });

    test('a derived-geometry export writes the derived route and its stops',
        () async {
      final controller = await TrackingClient.open(
        owner: _owner,
        repository: harness.repository,
        trackerAdapter: adapter,
        exportFileWriter: writer,
        clock: () => harness.now,
      );
      addTearDown(controller.dispose);
      final track = (await controller.startNewTrack(
        const TrackStartRequest(owner: _owner, routeId: 'derived_stop_route'),
      ))
          .track;
      final stop = await _recordStop(
        harness.repository,
        track.id,
        t0,
        prefix: 'derived',
        latitude: 0.5,
      );
      harness.now = t0.add(const Duration(minutes: 10));
      await controller.completeCurrentTrack(reason: 'finished');

      final geometry = controller as TrackingGeometryController;
      final run = await geometry.deriveGeometry(
        track.id,
        request: const DerivedGeometryRequest(smoothingFactor: 0.5),
      );
      final derived = await geometry.loadTrackGeometry(
        track.id,
        geometry: TrackGeometrySelection.derived(run.id),
      );
      final derivedLatitudes = <double>[
        for (final segment in derived.segments)
          for (final point in segment.points)
            if (point.accepted) point.latitude,
      ];
      final raw = await harness.repository.loadTrackBundle(track.id);
      final rawLatitudes = <double>[
        for (final segment in raw.segments)
          for (final point in segment.points)
            if (point.accepted) point.latitude,
      ];
      expect(derivedLatitudes, isNot(rawLatitudes),
          reason: 'smoothing moves the onward fixes');

      final result = await controller.exportTrack(
        trackId: track.id,
        format: TrackExportFormat.gpx,
        fileName: 'derived_stop_route',
        options: TrackExportOptions(
          geometry: TrackGeometrySelection.derived(run.id),
        ),
      );
      final document = XmlDocument.parse(writer.files[result.path]!);
      expect(
        _elements(document, 'trkpt')
            .map((point) => double.parse(point.getAttribute('lat')!)),
        // GPX writes seven decimals.
        <Matcher>[for (final value in derivedLatitudes) closeTo(value, 1e-7)],
      );
      expect(
        _elements(document, 'wpt')
            .map((waypoint) => _gpxExtensions(waypoint)['stopId']),
        <String>[stop.id],
      );

      // Rejected points have no derived coordinates, as in V2 exports.
      await expectLater(
        controller.exportTrack(
          trackId: track.id,
          format: TrackExportFormat.gpx,
          options: TrackExportOptions(
            geometry: TrackGeometrySelection.derived(run.id),
            includeRejectedPoints: true,
          ),
        ),
        throwsA(
          isA<TrackingStorageException>().having(
            (error) => error.code,
            'code',
            'derived_geometry_rejected_points_unsupported',
          ),
        ),
      );
    });
  });
}
