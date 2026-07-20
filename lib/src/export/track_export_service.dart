import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path_util;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

import '../domain/activity_snapshot.dart';
import '../domain/export_models.dart';
import '../domain/track.dart';
import '../domain/track_point.dart';
import '../storage/track_repository.dart';

abstract interface class ExportFileWriter {
  Future<String> write({
    required String fileName,
    required String contents,
    String? mimeType,
  });

  Future<void> delete(String path);
}

/// Writes exports to a user-visible folder.
///
/// Android uses MediaStore so files appear in
/// `Download/flutter_background_location` without broad storage permissions.
/// iOS has no shared Downloads folder, so it writes to
/// `Documents/flutter_background_location`.
final class PublicDownloadsExportWriter implements ExportFileWriter {
  PublicDownloadsExportWriter({
    this.directoryName = 'flutter_background_location',
    MethodChannel? methodChannel,
  }) : _methodChannel = methodChannel ?? const MethodChannel(_methodsName);

  static const String _methodsName = 'flutter_background_location/methods';

  final String directoryName;
  final MethodChannel _methodChannel;

  @override
  Future<String> write({
    required String fileName,
    required String contents,
    String? mimeType,
  }) async {
    final safeName = sanitizeExportFileName(fileName);
    if (Platform.isAndroid) {
      final path = await _methodChannel.invokeMethod<String>(
        'exportToDownloads',
        <String, Object?>{
          'directoryName': directoryName,
          'fileName': safeName,
          'mimeType': mimeType ?? 'application/octet-stream',
          'contents': contents,
        },
      );
      if (path == null || path.isEmpty) {
        throw StateError('Android export did not return a destination path.');
      }
      return path;
    }

    final directory = await _fallbackExportDirectory();
    return FileSystemExportWriter(directory.path).write(
      fileName: safeName,
      contents: contents,
      mimeType: mimeType,
    );
  }

  @override
  Future<void> delete(String exportPath) async {
    if (Platform.isAndroid) {
      await _methodChannel.invokeMethod<Object?>(
        'deleteDownloadExport',
        <String, Object?>{
          'directoryName': directoryName,
          'fileName': sanitizeExportFileName(path_util.basename(exportPath)),
        },
      );
      return;
    }

    final directory = await _fallbackExportDirectory();
    await FileSystemExportWriter(directory.path).delete(exportPath);
  }

  Future<Directory> _fallbackExportDirectory() async {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) {
      return Directory(path_util.join(downloads.path, directoryName));
    }
    final documents = await getApplicationDocumentsDirectory();
    return Directory(path_util.join(documents.path, directoryName));
  }
}

final class FileSystemExportWriter implements ExportFileWriter {
  FileSystemExportWriter(this.directoryPath);

  final String directoryPath;

  @override
  Future<String> write({
    required String fileName,
    required String contents,
    String? mimeType,
  }) async {
    final directory = Directory(directoryPath);
    await directory.create(recursive: true);
    final safeName = sanitizeExportFileName(fileName);
    var destination = File(path_util.join(directory.path, safeName));
    var counter = 1;
    final extension = path_util.extension(safeName);
    final base = path_util.basenameWithoutExtension(safeName);
    while (await destination.exists()) {
      destination = File(
        path_util.join(directory.path, '${base}_$counter$extension'),
      );
      counter += 1;
    }
    final temporary = File('${destination.path}.${const Uuid().v4()}.tmp');
    try {
      await temporary.writeAsString(
        contents,
        encoding: utf8,
        flush: true,
      );
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
    return destination.path;
  }

  @override
  Future<void> delete(String exportPath) async {
    final root = path_util.normalize(path_util.absolute(directoryPath));
    final candidate = path_util.normalize(path_util.absolute(exportPath));
    if (!path_util.isWithin(root, candidate)) {
      throw ArgumentError.value(exportPath, 'path', 'Not an export path');
    }
    final file = File(candidate);
    if (await file.exists()) await file.delete();
  }
}

final class TrackExportService {
  TrackExportService({required this.repository, required this.fileWriter});

  final TrackRepository repository;
  final ExportFileWriter fileWriter;

  Future<TrackExportResult> exportTrack({
    required String trackId,
    required TrackExportFormat format,
    TrackExportOptions options = const TrackExportOptions(),
    String? fileName,
  }) async {
    final artifact = await renderTrack(
      trackId: trackId,
      format: format,
      options: options,
    );
    final exportName = resolveExportFileName(
      format: format,
      fallbackFileName: artifact.fileName,
      requestedFileName: fileName,
    );
    final path = await fileWriter.write(
      fileName: exportName,
      contents: artifact.contents,
      mimeType: artifact.mimeType,
    );
    return TrackExportResult(
      trackId: artifact.trackId,
      format: artifact.format,
      fileName: path_util.basename(path),
      mimeType: artifact.mimeType,
      path: path,
      pointCount: artifact.pointCount,
      segmentCount: artifact.segmentCount,
    );
  }

  Future<TrackExportArtifact> renderTrack({
    required String trackId,
    required TrackExportFormat format,
    TrackExportOptions options = const TrackExportOptions(),
  }) async {
    final bundle = await repository.loadTrackBundle(trackId);
    if (bundle.track.status != TrackStatus.completed &&
        !options.allowIncompleteTrackSnapshot) {
      throw StateError('Only completed tracks can be exported.');
    }
    return switch (format) {
      TrackExportFormat.geoJson => _geoJson(bundle, options),
      TrackExportFormat.kml => _kml(bundle, options),
      TrackExportFormat.gpx => _gpx(bundle, options),
    };
  }

  Future<void> deleteExport(TrackExportResult result) =>
      fileWriter.delete(result.path);

  static TrackExportArtifact _geoJson(
    TrackBundle bundle,
    TrackExportOptions options,
  ) {
    final selectedSegmentPoints = _selectedSegments(bundle, options);
    final segmentPoints = _geometrySegments(selectedSegmentPoints);
    final lines = segmentPoints
        .where((points) => points.length >= 2)
        .map(
          (points) => points
              .map(
                (point) => <double>[
                  point.longitude,
                  point.latitude,
                  if (point.altitude?.isFinite ?? false) point.altitude!,
                ],
              )
              .toList(growable: false),
        )
        .toList(growable: false);
    final features = <Map<String, Object?>>[
      <String, Object?>{
        'type': 'Feature',
        'properties': _trackProperties(bundle.track),
        'geometry': _geoJsonRouteGeometry(lines),
      },
    ];
    if (options.includeGeoJsonPointFeatures) {
      for (final points in selectedSegmentPoints) {
        for (final point in points) {
          final hasCoordinate = _hasValidCoordinate(point);
          features.add(<String, Object?>{
            'type': 'Feature',
            'properties': _pointProperties(point, options),
            'geometry': hasCoordinate
                ? <String, Object?>{
                    'type': 'Point',
                    'coordinates': <double>[
                      point.longitude,
                      point.latitude,
                      if (point.altitude?.isFinite ?? false) point.altitude!,
                    ],
                  }
                : null,
          });
        }
      }
    }
    final contents = const JsonEncoder.withIndent('  ').convert(
      <String, Object?>{'type': 'FeatureCollection', 'features': features},
    );
    return _artifact(
      bundle,
      TrackExportFormat.geoJson,
      'application/geo+json',
      'geojson',
      contents,
      selectedSegmentPoints,
    );
  }

  static Map<String, Object?>? _geoJsonRouteGeometry(
    List<List<List<double>>> lines,
  ) {
    if (lines.isEmpty) return null;
    if (lines.length == 1) {
      return <String, Object?>{
        'type': 'LineString',
        'coordinates': lines.single,
      };
    }
    return <String, Object?>{
      'type': 'MultiLineString',
      'coordinates': lines,
    };
  }

  static TrackExportArtifact _kml(
    TrackBundle bundle,
    TrackExportOptions options,
  ) {
    final selectedSegmentPoints = _selectedSegments(bundle, options);
    final segmentPoints = _geometrySegments(selectedSegmentPoints);
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'kml',
      attributes: <String, String>{
        'xmlns': 'http://www.opengis.net/kml/2.2',
      },
      nest: () {
        builder.element('Document', nest: () {
          builder.element('name', nest: 'Track ${bundle.track.id}');
          for (var index = 0; index < segmentPoints.length; index += 1) {
            final points = segmentPoints[index];
            if (points.length >= 2) {
              builder.element('Placemark', nest: () {
                builder.element('name', nest: 'Segment ${index + 1}');
                _kmlExtendedData(builder, index + 1, points);
                builder.element('LineString', nest: () {
                  builder.element('tessellate', nest: '1');
                  builder.element(
                    'coordinates',
                    nest: points.map(_kmlCoordinate).join('\n'),
                  );
                });
              });
            } else if (points.length == 1) {
              final point = points.single;
              builder.element('Placemark', nest: () {
                builder.element('name', nest: 'Segment ${index + 1} point');
                _kmlExtendedData(builder, index + 1, points);
                builder.element('Point', nest: () {
                  builder.element('coordinates', nest: _kmlCoordinate(point));
                });
              });
            }
          }
        });
      },
    );
    final contents = builder.buildDocument().toXmlString(pretty: true);
    XmlDocument.parse(contents);
    return _artifact(
      bundle,
      TrackExportFormat.kml,
      'application/vnd.google-earth.kml+xml',
      'kml',
      contents,
      selectedSegmentPoints,
    );
  }

  static TrackExportArtifact _gpx(
    TrackBundle bundle,
    TrackExportOptions options,
  ) {
    final selectedSegmentPoints = _selectedSegments(bundle, options);
    final segmentPoints = _geometrySegments(selectedSegmentPoints);
    final builder = XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');
    builder.element(
      'gpx',
      attributes: <String, String>{
        'version': '1.1',
        'creator': 'flutter_background_location',
        'xmlns': 'http://www.topografix.com/GPX/1/1',
        'xmlns:fbl':
            'https://github.com/flutter-background-location/extensions/1',
        'xsi:schemaLocation': 'http://www.topografix.com/GPX/1/1 '
            'http://www.topografix.com/GPX/1/1/gpx.xsd',
        'xmlns:xsi': 'http://www.w3.org/2001/XMLSchema-instance',
      },
      nest: () {
        builder.element('metadata', nest: () {
          builder.element('name', nest: 'Track ${bundle.track.id}');
          builder.element(
            'time',
            nest: _formatTime(bundle.track.startedAt, options),
          );
        });
        builder.element('trk', nest: () {
          builder.element('name', nest: 'Track ${bundle.track.id}');
          for (final points in segmentPoints) {
            builder.element('trkseg', nest: () {
              for (final point in points) {
                builder.element(
                  'trkpt',
                  attributes: <String, String>{
                    'lat': _coordinate(point.latitude),
                    'lon': _coordinate(point.longitude),
                  },
                  nest: () {
                    if (point.altitude?.isFinite ?? false) {
                      builder.element('ele', nest: point.altitude.toString());
                    }
                    builder.element(
                      'time',
                      nest: _formatTime(point.capturedAt, options),
                    );
                    if (options.includePointProperties) {
                      builder.element('extensions', nest: () {
                        builder.element(
                          'fbl:sequence',
                          nest: point.sequence.toString(),
                        );
                        builder.element(
                          'fbl:mockAssessment',
                          nest: point.mockAssessment.name,
                        );
                        if (options.includeActivityMetadata) {
                          builder.element(
                            'fbl:activity',
                            nest: point.activityType.value,
                          );
                          builder.element(
                            'fbl:activityConfidence',
                            nest: point.activityConfidence.toString(),
                          );
                        }
                      });
                    }
                  },
                );
              }
            });
          }
        });
      },
    );
    final contents = builder.buildDocument().toXmlString(pretty: true);
    XmlDocument.parse(contents);
    return _artifact(
      bundle,
      TrackExportFormat.gpx,
      'application/gpx+xml',
      'gpx',
      contents,
      selectedSegmentPoints,
    );
  }

  static List<List<TrackPoint>> _selectedSegments(
    TrackBundle bundle,
    TrackExportOptions options,
  ) =>
      bundle.segments
          .map(
            (segment) => segment.points
                .where(
                    (point) => point.accepted || options.includeRejectedPoints)
                .toList(growable: false),
          )
          .toList(growable: false);

  static List<List<TrackPoint>> _geometrySegments(
    List<List<TrackPoint>> selected,
  ) =>
      selected
          .map(
            (points) =>
                points.where(_hasValidCoordinate).toList(growable: false),
          )
          .toList(growable: false);

  static bool _hasValidCoordinate(TrackPoint point) =>
      point.latitude.isFinite &&
      point.longitude.isFinite &&
      point.latitude >= -90 &&
      point.latitude <= 90 &&
      point.longitude >= -180 &&
      point.longitude <= 180;

  static Map<String, Object?> _trackProperties(Track track) =>
      <String, Object?>{
        'trackId': track.id,
        'startedAt': track.startedAt.toUtc().toIso8601String(),
        'completedAt': track.endedAt?.toUtc().toIso8601String(),
        'status': track.status.name,
        'segmentCount': track.segmentCount,
        'acceptedPointCount': track.acceptedPointCount,
        'rejectedPointCount': track.rejectedPointCount,
        'distanceMeters': track.totalDistanceMeters,
      };

  static Map<String, Object?> _pointProperties(
    TrackPoint point,
    TrackExportOptions options,
  ) =>
      <String, Object?>{
        'trackId': point.trackId,
        'segmentId': point.segmentId,
        'sequence': point.sequence,
        'capturedAt': _formatTime(point.capturedAt, options),
        'accuracy': point.horizontalAccuracy?.isFinite ?? false
            ? point.horizontalAccuracy
            : null,
        'mockAssessment': point.mockAssessment.name,
        'mockEvidence': point.mockEvidence,
        'accepted': point.accepted,
        'qualityFlags': point.qualityFlags,
        if (point.rejectionReason != null)
          'rejectionReason': point.rejectionReason,
        if (options.includeActivityMetadata) ...<String, Object?>{
          'activity': point.activityType.value,
          'activityConfidence': point.activityConfidence,
          'motionState': point.motionState.name,
        },
      };

  static void _kmlExtendedData(
    XmlBuilder builder,
    int segmentNumber,
    List<TrackPoint> points,
  ) {
    builder.element('ExtendedData', nest: () {
      for (final entry in <String, String>{
        'segmentNumber': segmentNumber.toString(),
        'pointCount': points.length.toString(),
      }.entries) {
        builder.element(
          'Data',
          attributes: <String, String>{'name': entry.key},
          nest: () => builder.element('value', nest: entry.value),
        );
      }
    });
  }

  static String _kmlCoordinate(TrackPoint point) =>
      '${_coordinate(point.longitude)},${_coordinate(point.latitude)},'
      '${point.altitude?.isFinite ?? false ? point.altitude : 0}';

  static String _coordinate(double value) => value.toStringAsFixed(7);

  static String _formatTime(DateTime value, TrackExportOptions options) {
    if (options.useUtcTimestamps) return value.toUtc().toIso8601String();
    final local = value.toLocal();
    final offset = local.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final minutes = offset.inMinutes.abs();
    final hoursPart = (minutes ~/ 60).toString().padLeft(2, '0');
    final minutesPart = (minutes % 60).toString().padLeft(2, '0');
    return '${local.toIso8601String()}$sign$hoursPart:$minutesPart';
  }

  static TrackExportArtifact _artifact(
    TrackBundle bundle,
    TrackExportFormat format,
    String mimeType,
    String extension,
    String contents,
    List<List<TrackPoint>> segments,
  ) {
    final date =
        bundle.track.startedAt.toUtc().toIso8601String().split('T').first;
    final safeId = bundle.track.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return TrackExportArtifact(
      trackId: bundle.track.id,
      format: format,
      fileName: 'track_${date}_$safeId.$extension',
      mimeType: mimeType,
      contents: contents,
      pointCount: segments.fold<int>(0, (sum, points) => sum + points.length),
      segmentCount: segments.length,
    );
  }
}

String resolveExportFileName({
  required TrackExportFormat format,
  required String fallbackFileName,
  String? requestedFileName,
}) {
  final extension = _extensionForFormat(format);
  final fallback = sanitizeExportFileName(fallbackFileName);
  final requested = requestedFileName?.trim();
  if (requested == null || requested.isEmpty) return fallback;

  final safe = sanitizeExportFileName(requested);
  final currentExtension = path_util.extension(safe);
  if (currentExtension.toLowerCase() == extension) return safe;
  if (currentExtension.isEmpty) return '$safe$extension';
  return '${path_util.basenameWithoutExtension(safe)}$extension';
}

String sanitizeExportFileName(String fileName) {
  final sanitized = path_util
      .basename(fileName)
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .trim()
      .replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
    throw ArgumentError.value(fileName, 'fileName', 'Unsafe export file name');
  }
  return sanitized;
}

String _extensionForFormat(TrackExportFormat format) => switch (format) {
      TrackExportFormat.geoJson => '.geojson',
      TrackExportFormat.kml => '.kml',
      TrackExportFormat.gpx => '.gpx',
    };
