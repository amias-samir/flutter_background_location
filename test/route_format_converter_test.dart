import 'dart:convert';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  const converter = RouteFormatConverter();
  const geoJson = '''
{
  "type": "FeatureCollection",
  "features": [{
    "type": "Feature",
    "properties": {
      "name": "Morning route",
      "coordinateTimes": [
        ["2026-09-07T01:00:00Z", "2026-09-07T01:01:00Z"],
        ["2026-09-07T02:00:00Z", "2026-09-07T02:01:00Z"]
      ]
    },
    "geometry": {
      "type": "MultiLineString",
      "coordinates": [
        [[85.30, 27.70, 1300], [85.31, 27.71, 1301]],
        [[85.40, 27.80], [85.41, 27.81]]
      ]
    }
  }]
}
''';
  const gpx = '''
<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="test" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata><name>Morning route</name></metadata>
  <trk><name>Morning route</name>
    <trkseg>
      <trkpt lat="27.70" lon="85.30"><ele>1300</ele><time>2026-09-07T01:00:00Z</time></trkpt>
      <trkpt lat="27.71" lon="85.31"><ele>1301</ele><time>2026-09-07T01:01:00Z</time></trkpt>
    </trkseg>
    <trkseg>
      <trkpt lat="27.80" lon="85.40"/>
      <trkpt lat="27.81" lon="85.41"/>
    </trkseg>
  </trk>
</gpx>
''';
  const kml = '''
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2"><Document>
  <name>Morning route</name>
  <Placemark><LineString><coordinates>
    85.30,27.70,1300 85.31,27.71,1301
  </coordinates></LineString></Placemark>
  <Placemark><LineString><coordinates>
    85.40,27.80,0 85.41,27.81,0
  </coordinates></LineString></Placemark>
</Document></kml>
''';

  test('converts all six format directions', () {
    final conversions =
        <({String source, TrackExportFormat from, TrackExportFormat to})>[
      (
        source: geoJson,
        from: TrackExportFormat.geoJson,
        to: TrackExportFormat.gpx
      ),
      (
        source: geoJson,
        from: TrackExportFormat.geoJson,
        to: TrackExportFormat.kml
      ),
      (source: gpx, from: TrackExportFormat.gpx, to: TrackExportFormat.geoJson),
      (source: gpx, from: TrackExportFormat.gpx, to: TrackExportFormat.kml),
      (source: kml, from: TrackExportFormat.kml, to: TrackExportFormat.geoJson),
      (source: kml, from: TrackExportFormat.kml, to: TrackExportFormat.gpx),
    ];

    for (final conversion in conversions) {
      final output = converter.convert(
        contents: conversion.source,
        sourceFormat: conversion.from,
        targetFormat: conversion.to,
      );
      expect(output, isNotEmpty);
      if (conversion.to == TrackExportFormat.geoJson) {
        final decoded = jsonDecode(output) as Map<String, Object?>;
        expect(decoded['type'], 'FeatureCollection');
        final features = decoded['features']! as List;
        final feature = features.single as Map;
        final geometry = feature['geometry']! as Map;
        expect(geometry['type'], 'MultiLineString');
        expect((geometry['coordinates']! as List), hasLength(2));
      } else {
        final document = XmlDocument.parse(output);
        final expected = conversion.to == TrackExportFormat.gpx ? 'gpx' : 'kml';
        expect(document.rootElement.name.local, expected);
      }
    }
  });

  test('convenience methods preserve segment count and timestamps', () {
    final convertedGpx = converter.geoJsonToGpx(geoJson);
    final gpxDocument = XmlDocument.parse(convertedGpx);
    expect(
      gpxDocument.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'trkseg'),
      hasLength(2),
    );
    expect(convertedGpx, contains('2026-09-07T01:00:00.000Z'));

    final convertedKml = converter.gpxToKml(gpx);
    expect(convertedKml, contains('coordinateTimes'));
    final roundTrip = converter.kmlToGpx(convertedKml);
    expect(roundTrip, contains('2026-09-07T01:00:00.000Z'));
  });

  test('accepts a GPX route when no track is present', () {
    const route = '''
<gpx version="1.1"><rte><name>Route</name>
  <rtept lat="27.7" lon="85.3"/><rtept lat="27.8" lon="85.4"/>
</rte></gpx>
''';
    expect(converter.gpxToGeoJson(route), contains('LineString'));
  });

  test('rejects malformed, empty, and same-format conversions', () {
    expect(() => converter.gpxToKml('<gpx>'), throwsFormatException);
    expect(() => converter.kmlToGeoJson('<kml/>'), throwsFormatException);
    expect(
      () => converter.convert(
        contents: geoJson,
        sourceFormat: TrackExportFormat.geoJson,
        targetFormat: TrackExportFormat.geoJson,
      ),
      throwsArgumentError,
    );
  });
}
