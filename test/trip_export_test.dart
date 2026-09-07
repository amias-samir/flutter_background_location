import 'dart:convert';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'test_support.dart';

const _owner = TrackingOwner(
  userId: 'trip-export-user',
  organizationId: 'trip-export-organization',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('three-day Trip exports once in chronological order in every format',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final adapter = FakeTrackerAdapter();
    final writer = FakeExportFileWriter();
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
        routeId: 'multi_day_export',
        operationId: 'start-export-trip',
      ),
    );
    var currentTrackId = started.leg.trackId;
    await _emitDay(adapter, harness, currentTrackId, day: 1);
    await controller.endCurrentDay(operationId: 'end-export-day-1');

    harness.now = harness.now.add(const Duration(days: 1));
    currentTrackId = (await controller.continueTrip(
      started.trip.id,
      operationId: 'continue-export-day-2',
    ))
        .leg
        .trackId;
    await _emitDay(adapter, harness, currentTrackId, day: 2);
    await controller.endCurrentDay(operationId: 'end-export-day-2');

    harness.now = harness.now.add(const Duration(days: 1));
    currentTrackId = (await controller.continueTrip(
      started.trip.id,
      operationId: 'continue-export-day-3',
    ))
        .leg
        .trackId;
    await _emitDay(adapter, harness, currentTrackId, day: 3);
    await controller.completeTrip(
      started.trip.id,
      operationId: 'complete-export-trip',
    );

    for (final format in TrackExportFormat.values) {
      final result = await controller.exportTrip(
        tripId: started.trip.id,
        format: format,
        fileName: 'whole_trip_${format.name}',
        options: const TrackExportOptions(
          geometryContinuity:
              RouteGeometryContinuity.connectAllChronologicalPoints,
        ),
      );
      final contents = writer.files[result.path]!;
      expect(result.pointCount, 6);
      expect(result.sourceSegmentCount, 3);
      expect(result.geometryPartCount, 1);
      expect(result.gapCount, 2);
      expect(result.inferredConnectorCount, 2);
      expect(result.lifecycleRevision, greaterThanOrEqualTo(6));

      switch (format) {
        case TrackExportFormat.geoJson:
          final document = jsonDecode(contents) as Map<String, Object?>;
          final features = document['features']! as List<Object?>;
          final route = features.first! as Map<String, Object?>;
          final geometry = route['geometry']! as Map<String, Object?>;
          expect(geometry['type'], 'LineString');
          expect(geometry['coordinates'], hasLength(6));
          expect(features, hasLength(3));
        case TrackExportFormat.kml:
          final document = XmlDocument.parse(contents);
          expect(_elements(document, 'LineString'), hasLength(1));
          expect(_elements(document, 'Placemark'), hasLength(3));
        case TrackExportFormat.gpx:
          final document = XmlDocument.parse(contents);
          expect(_elements(document, 'trkseg'), hasLength(1));
          expect(_elements(document, 'trkpt'), hasLength(6));
          expect(_elements(document, 'gap'), hasLength(2));
      }
    }
  });
}

Future<void> _emitDay(
  FakeTrackerAdapter adapter,
  RepositoryHarness harness,
  String trackId, {
  required int day,
}) async {
  for (var point = 0; point < 2; point += 1) {
    final capturedAt = harness.now.add(Duration(seconds: point * 10));
    adapter.emitLocation(
      LocationSample(
        latitude: day.toDouble(),
        longitude: day + point * 0.001,
        horizontalAccuracy: 5,
        capturedAt: capturedAt,
        provider: 'synthetic',
        eventId: 'day-$day-point-$point',
        trackId: trackId,
        nativeReceivedAt: capturedAt,
        providerTimeDeltaMsAtReceipt: 0,
        monotonicDomainId: 'trip-export-process',
        captureGenerationId: 'trip-export-generation-$day',
        nativeLifecycle: TrackerLifecycle.tracking,
        samplingProfile: SamplingProfile.moving,
      ),
    );
  }
  for (var attempt = 0; attempt < 200; attempt += 1) {
    final track = await harness.repository.getTrack(trackId);
    if (track?.acceptedPointCount == 2) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('The synthetic day was not persisted.');
}

Iterable<XmlElement> _elements(XmlDocument document, String localName) =>
    document.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == localName);
