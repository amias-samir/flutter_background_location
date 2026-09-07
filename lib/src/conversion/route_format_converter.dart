import 'dart:convert';

import 'package:xml/xml.dart';

import '../domain/export_models.dart';

/// Converts route content between GeoJSON, GPX, and KML.
///
/// Conversion is performed in memory and does not read or write files. Route
/// parts are retained as separate line/track segments. Elevation and timestamps
/// are preserved when the source format supplies them.
final class RouteFormatConverter {
  const RouteFormatConverter();

  /// Converts [contents] from [sourceFormat] to [targetFormat].
  ///
  /// Throws a [FormatException] when the input is malformed or contains no
  /// usable route coordinates, and an [ArgumentError] when both formats match.
  String convert({
    required String contents,
    required TrackExportFormat sourceFormat,
    required TrackExportFormat targetFormat,
  }) {
    if (sourceFormat == targetFormat) {
      throw ArgumentError.value(
        targetFormat,
        'targetFormat',
        'Source and target formats must be different.',
      );
    }
    if (contents.trim().isEmpty) {
      throw const FormatException('Route content cannot be empty.');
    }

    final route = switch (sourceFormat) {
      TrackExportFormat.geoJson => _parseGeoJson(contents),
      TrackExportFormat.gpx => _parseGpx(contents),
      TrackExportFormat.kml => _parseKml(contents),
    };
    if (route.segments.isEmpty ||
        route.segments.every((segment) => segment.isEmpty)) {
      throw const FormatException('No usable route coordinates were found.');
    }

    return switch (targetFormat) {
      TrackExportFormat.geoJson => _writeGeoJson(route),
      TrackExportFormat.gpx => _writeGpx(route),
      TrackExportFormat.kml => _writeKml(route),
    };
  }

  /// Converts GeoJSON route content to GPX.
  String geoJsonToGpx(String contents) => convert(
        contents: contents,
        sourceFormat: TrackExportFormat.geoJson,
        targetFormat: TrackExportFormat.gpx,
      );

  /// Converts GeoJSON route content to KML.
  String geoJsonToKml(String contents) => convert(
        contents: contents,
        sourceFormat: TrackExportFormat.geoJson,
        targetFormat: TrackExportFormat.kml,
      );

  /// Converts GPX route content to GeoJSON.
  String gpxToGeoJson(String contents) => convert(
        contents: contents,
        sourceFormat: TrackExportFormat.gpx,
        targetFormat: TrackExportFormat.geoJson,
      );

  /// Converts GPX route content to KML.
  String gpxToKml(String contents) => convert(
        contents: contents,
        sourceFormat: TrackExportFormat.gpx,
        targetFormat: TrackExportFormat.kml,
      );

  /// Converts KML route content to GeoJSON.
  String kmlToGeoJson(String contents) => convert(
        contents: contents,
        sourceFormat: TrackExportFormat.kml,
        targetFormat: TrackExportFormat.geoJson,
      );

  /// Converts KML route content to GPX.
  String kmlToGpx(String contents) => convert(
        contents: contents,
        sourceFormat: TrackExportFormat.kml,
        targetFormat: TrackExportFormat.gpx,
      );

  static _RouteDocument _parseGeoJson(String contents) {
    final Object? decoded;
    try {
      decoded = jsonDecode(contents);
    } on FormatException catch (error) {
      throw FormatException('Invalid GeoJSON: ${error.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('GeoJSON root must be an object.');
    }

    final segments = <List<_RouteCoordinate>>[];
    String? name;

    void readGeometry(Object? rawGeometry, Map<String, Object?> properties) {
      if (rawGeometry is! Map) return;
      final geometry = rawGeometry.cast<String, Object?>();
      final type = geometry['type'];
      final coordinates = geometry['coordinates'];
      final rawTimes = properties['coordinateTimes'] ?? properties['times'];
      if (type == 'LineString' && coordinates is List) {
        final segment = _geoJsonSegment(coordinates, rawTimes);
        if (segment.isNotEmpty) segments.add(segment);
      } else if (type == 'MultiLineString' && coordinates is List) {
        for (var index = 0; index < coordinates.length; index += 1) {
          final line = coordinates[index];
          if (line is! List) continue;
          final lineTimes = rawTimes is List && index < rawTimes.length
              ? rawTimes[index]
              : null;
          final segment = _geoJsonSegment(line, lineTimes);
          if (segment.isNotEmpty) segments.add(segment);
        }
      } else if (type == 'GeometryCollection' &&
          geometry['geometries'] is List) {
        for (final child in geometry['geometries']! as List) {
          readGeometry(child, properties);
        }
      }
    }

    final rootType = decoded['type'];
    if (rootType == 'FeatureCollection' && decoded['features'] is List) {
      final pointFallback = <_RouteCoordinate>[];
      for (final rawFeature in decoded['features']! as List) {
        if (rawFeature is! Map) continue;
        final feature = rawFeature.cast<String, Object?>();
        final properties = feature['properties'] is Map
            ? (feature['properties']! as Map).cast<String, Object?>()
            : <String, Object?>{};
        name ??= _firstText(properties, const ['name', 'routeId', 'trackId']);
        final geometry = feature['geometry'];
        if (geometry is Map && geometry['type'] == 'Point') {
          final point = _geoJsonCoordinate(
            geometry['coordinates'],
            time: properties['time'] ?? properties['timestamp'],
          );
          if (point != null) pointFallback.add(point);
        } else {
          readGeometry(geometry, properties);
        }
      }
      if (segments.isEmpty && pointFallback.isNotEmpty) {
        segments.add(pointFallback);
      }
    } else if (rootType == 'Feature') {
      final properties = decoded['properties'] is Map
          ? (decoded['properties']! as Map).cast<String, Object?>()
          : <String, Object?>{};
      name = _firstText(properties, const ['name', 'routeId', 'trackId']);
      readGeometry(decoded['geometry'], properties);
    } else {
      readGeometry(decoded, const <String, Object?>{});
    }
    return _RouteDocument(name: name, segments: segments);
  }

  static List<_RouteCoordinate> _geoJsonSegment(
    List<Object?> coordinates,
    Object? rawTimes,
  ) {
    final times = rawTimes is List ? rawTimes : const <Object?>[];
    return <_RouteCoordinate>[
      for (var index = 0; index < coordinates.length; index += 1)
        if (_geoJsonCoordinate(
          coordinates[index],
          time: index < times.length ? times[index] : null,
        )
            case final point?)
          point,
    ];
  }

  static _RouteCoordinate? _geoJsonCoordinate(
    Object? raw, {
    Object? time,
  }) {
    if (raw is! List || raw.length < 2) return null;
    final longitude = _finiteDouble(raw[0]);
    final latitude = _finiteDouble(raw[1]);
    if (longitude == null || latitude == null || !_valid(latitude, longitude)) {
      return null;
    }
    return _RouteCoordinate(
      latitude: latitude,
      longitude: longitude,
      elevation: raw.length > 2 ? _finiteDouble(raw[2]) : null,
      time: _dateTime(time),
    );
  }

  static _RouteDocument _parseGpx(String contents) {
    final document = _parseXml(contents, 'GPX');
    final name = _firstDescendantText(document.rootElement, 'name');
    final segments = <List<_RouteCoordinate>>[];
    for (final segmentElement in _elements(document, 'trkseg')) {
      final segment = _gpxPoints(_children(segmentElement, 'trkpt'));
      if (segment.isNotEmpty) segments.add(segment);
    }
    if (segments.isEmpty) {
      for (final route in _elements(document, 'rte')) {
        final segment = _gpxPoints(_children(route, 'rtept'));
        if (segment.isNotEmpty) segments.add(segment);
      }
    }
    if (segments.isEmpty) {
      final waypoints = _gpxPoints(_elements(document, 'wpt'));
      if (waypoints.isNotEmpty) segments.add(waypoints);
    }
    return _RouteDocument(name: name, segments: segments);
  }

  static List<_RouteCoordinate> _gpxPoints(Iterable<XmlElement> elements) => [
        for (final element in elements)
          if (_xmlCoordinate(element) case final point?) point,
      ];

  static _RouteCoordinate? _xmlCoordinate(XmlElement element) {
    final latitude = _finiteDouble(element.getAttribute('lat'));
    final longitude = _finiteDouble(element.getAttribute('lon'));
    if (latitude == null || longitude == null || !_valid(latitude, longitude)) {
      return null;
    }
    return _RouteCoordinate(
      latitude: latitude,
      longitude: longitude,
      elevation: _finiteDouble(_childText(element, 'ele')),
      time: _dateTime(_childText(element, 'time')),
    );
  }

  static _RouteDocument _parseKml(String contents) {
    final document = _parseXml(contents, 'KML');
    final name = _firstDescendantText(document.rootElement, 'name');
    final segments = <List<_RouteCoordinate>>[];
    for (final line in _elements(document, 'LineString')) {
      final rawCoordinates = _childText(line, 'coordinates');
      if (rawCoordinates == null) continue;
      final placemark = line.ancestors
          .whereType<XmlElement>()
          .where((element) => element.name.local == 'Placemark')
          .firstOrNull;
      final times = _kmlCoordinateTimes(placemark);
      final segment = <_RouteCoordinate>[];
      final tokens = rawCoordinates.trim().split(RegExp(r'\s+'));
      for (var index = 0; index < tokens.length; index += 1) {
        final values = tokens[index].split(',');
        if (values.length < 2) continue;
        final longitude = _finiteDouble(values[0]);
        final latitude = _finiteDouble(values[1]);
        if (longitude == null ||
            latitude == null ||
            !_valid(latitude, longitude)) {
          continue;
        }
        segment.add(_RouteCoordinate(
          latitude: latitude,
          longitude: longitude,
          elevation: values.length > 2 ? _finiteDouble(values[2]) : null,
          time: index < times.length ? times[index] : null,
        ));
      }
      if (segment.isNotEmpty) segments.add(segment);
    }
    for (final track in _elements(document, 'Track')) {
      final coordinates = _children(track, 'coord').toList(growable: false);
      final times = _children(track, 'when').toList(growable: false);
      final segment = <_RouteCoordinate>[];
      for (var index = 0; index < coordinates.length; index += 1) {
        final values =
            coordinates[index].innerText.trim().split(RegExp(r'\s+'));
        if (values.length < 2) continue;
        final longitude = _finiteDouble(values[0]);
        final latitude = _finiteDouble(values[1]);
        if (longitude == null ||
            latitude == null ||
            !_valid(latitude, longitude)) {
          continue;
        }
        segment.add(_RouteCoordinate(
          latitude: latitude,
          longitude: longitude,
          elevation: values.length > 2 ? _finiteDouble(values[2]) : null,
          time: index < times.length ? _dateTime(times[index].innerText) : null,
        ));
      }
      if (segment.isNotEmpty) segments.add(segment);
    }
    return _RouteDocument(name: name, segments: segments);
  }

  static List<DateTime?> _kmlCoordinateTimes(XmlElement? placemark) {
    if (placemark == null) return const [];
    for (final data in _children(placemark, 'ExtendedData')
        .expand((element) => _children(element, 'Data'))) {
      if (data.getAttribute('name') != 'coordinateTimes') continue;
      final text = _childText(data, 'value');
      if (text == null) return const [];
      try {
        final decoded = jsonDecode(text);
        if (decoded is List) return decoded.map(_dateTime).toList();
      } on FormatException {
        return const [];
      }
    }
    return const [];
  }

  static String _writeGeoJson(_RouteDocument route) {
    final lines = route.segments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    final isSingle = lines.length == 1;
    Object coordinatesFor(List<_RouteCoordinate> segment) => [
          for (final point in segment)
            [
              point.longitude,
              point.latitude,
              if (point.elevation != null) point.elevation,
            ],
        ];
    Object? timesFor(List<_RouteCoordinate> segment) {
      if (!segment.any((point) => point.time != null)) return null;
      return [
        for (final point in segment) point.time?.toUtc().toIso8601String()
      ];
    }

    final properties = <String, Object?>{
      if (route.name != null) 'name': route.name,
      'source': 'flutter_background_location_tracker_converter',
    };
    if (isSingle) {
      final times = timesFor(lines.single);
      if (times != null) properties['coordinateTimes'] = times;
    } else {
      final hasTimes = lines.any((segment) => timesFor(segment) != null);
      if (hasTimes) {
        properties['coordinateTimes'] = [
          for (final segment in lines)
            timesFor(segment) ?? [for (final _ in segment) null],
        ];
      }
    }
    return const JsonEncoder.withIndent('  ').convert({
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': properties,
          'geometry': {
            'type': isSingle ? 'LineString' : 'MultiLineString',
            'coordinates': isSingle
                ? coordinatesFor(lines.single)
                : [for (final segment in lines) coordinatesFor(segment)],
          },
        },
      ],
    });
  }

  static String _writeGpx(_RouteDocument route) {
    final builder = XmlBuilder();
    builder
      ..processing('xml', 'version="1.0" encoding="UTF-8"')
      ..element('gpx', attributes: {
        'version': '1.1',
        'creator': 'flutter_background_location_tracker',
        'xmlns': 'http://www.topografix.com/GPX/1/1',
      }, nest: () {
        builder.element('metadata', nest: () {
          if (route.name != null) builder.element('name', nest: route.name);
        });
        builder.element('trk', nest: () {
          if (route.name != null) builder.element('name', nest: route.name);
          for (final segment
              in route.segments.where((value) => value.isNotEmpty)) {
            builder.element('trkseg', nest: () {
              for (final point in segment) {
                builder.element('trkpt', attributes: {
                  'lat': _decimal(point.latitude),
                  'lon': _decimal(point.longitude),
                }, nest: () {
                  if (point.elevation != null) {
                    builder.element('ele', nest: point.elevation.toString());
                  }
                  if (point.time != null) {
                    builder.element(
                      'time',
                      nest: point.time!.toUtc().toIso8601String(),
                    );
                  }
                });
              }
            });
          }
        });
      });
    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }

  static String _writeKml(_RouteDocument route) {
    final builder = XmlBuilder();
    builder
      ..processing('xml', 'version="1.0" encoding="UTF-8"')
      ..element('kml', attributes: {
        'xmlns': 'http://www.opengis.net/kml/2.2',
      }, nest: () {
        builder.element('Document', nest: () {
          if (route.name != null) builder.element('name', nest: route.name);
          var segmentNumber = 0;
          for (final segment
              in route.segments.where((value) => value.isNotEmpty)) {
            segmentNumber += 1;
            builder.element('Placemark', nest: () {
              builder.element('name', nest: 'Segment $segmentNumber');
              if (segment.any((point) => point.time != null)) {
                builder.element('ExtendedData', nest: () {
                  builder.element('Data', attributes: {
                    'name': 'coordinateTimes',
                  }, nest: () {
                    builder.element('value',
                        nest: jsonEncode([
                          for (final point in segment)
                            point.time?.toUtc().toIso8601String(),
                        ]));
                  });
                });
              }
              builder.element('LineString', nest: () {
                builder.element('tessellate', nest: '1');
                builder.element('coordinates',
                    nest: segment.map((point) {
                      final altitude = point.elevation ?? 0;
                      return '${_decimal(point.longitude)},'
                          '${_decimal(point.latitude)},$altitude';
                    }).join(' '));
              });
            });
          }
        });
      });
    return builder.buildDocument().toXmlString(pretty: true, indent: '  ');
  }

  static XmlDocument _parseXml(String contents, String format) {
    try {
      return XmlDocument.parse(contents);
    } on XmlParserException catch (error) {
      throw FormatException('Invalid $format: ${error.message}');
    }
  }

  static Iterable<XmlElement> _elements(XmlNode node, String localName) =>
      node.descendants
          .whereType<XmlElement>()
          .where((element) => element.name.local == localName);

  static Iterable<XmlElement> _children(XmlNode node, String localName) =>
      node.children
          .whereType<XmlElement>()
          .where((element) => element.name.local == localName);

  static String? _childText(XmlNode node, String localName) {
    for (final child in _children(node, localName)) {
      final value = child.innerText.trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  static String? _firstDescendantText(XmlNode node, String localName) {
    for (final element in _elements(node, localName)) {
      final value = element.innerText.trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  static String? _firstText(Map<String, Object?> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  static double? _finiteDouble(Object? value) {
    final parsed = value is num ? value.toDouble() : double.tryParse('$value');
    return parsed != null && parsed.isFinite ? parsed : null;
  }

  static DateTime? _dateTime(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return DateTime.tryParse(value.trim());
  }

  static bool _valid(double latitude, double longitude) =>
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;

  static String _decimal(double value) => value.toStringAsFixed(7);
}

final class _RouteDocument {
  const _RouteDocument({required this.name, required this.segments});

  final String? name;
  final List<List<_RouteCoordinate>> segments;
}

final class _RouteCoordinate {
  const _RouteCoordinate({
    required this.latitude,
    required this.longitude,
    required this.elevation,
    required this.time,
  });

  final double latitude;
  final double longitude;
  final double? elevation;
  final DateTime? time;
}
