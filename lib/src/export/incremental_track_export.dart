import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path_util;
import 'package:uuid/uuid.dart';

import '../domain/export_models.dart';
import '../domain/derived_geometry.dart';
import '../domain/activity_snapshot.dart';
import '../domain/track.dart';
import '../domain/track_data_page.dart';
import '../domain/track_point.dart';
import '../domain/track_segment.dart';
import '../domain/tracking_error.dart';
import '../domain/tracking_start.dart';
import '../storage/track_repository.dart';
import 'track_export_service.dart';

/// Internal descriptor used by the S1 incremental sink foundation.
///
/// The public V2 destination/operation contract lands with S1-02. This source
/// file is deliberately not exported from the package barrel before then.
final class IncrementalExportDescriptor {
  const IncrementalExportDescriptor({
    required this.fileName,
    required this.mimeType,
  });

  final String fileName;
  final String mimeType;
}

/// Internal bounded-byte sink lifecycle used by incremental encoders.
abstract interface class IncrementalExportSink {
  Future<void> open(IncrementalExportDescriptor descriptor);
  Future<void> addUtf8(List<int> bytes);
  Future<TrackExportDestination> commit();
  Future<void> abort();
}

typedef IncrementalExportSinkFactory = IncrementalExportSink Function();
typedef IncrementalTrackExportProgress = TrackExportProgress;
typedef IncrementalTrackExportResult = TrackExportResultV2;
typedef IncrementalTrackExportOperation = TrackExportOperation;

/// Streams route exports from owner-scoped repository pages into a byte sink.
final class IncrementalTrackExportService {
  IncrementalTrackExportService({
    required this.repository,
    required this.sinkFactory,
    this.segmentPageSize = 100,
    this.pointPageSize = 500,
  }) {
    if (segmentPageSize < 1 || segmentPageSize > 200) {
      throw ArgumentError.value(segmentPageSize, 'segmentPageSize');
    }
    if (pointPageSize < 1 || pointPageSize > 1000) {
      throw ArgumentError.value(pointPageSize, 'pointPageSize');
    }
  }

  final TrackRepository repository;
  final IncrementalExportSinkFactory sinkFactory;
  final int segmentPageSize;
  final int pointPageSize;

  IncrementalTrackExportOperation start({
    required TrackingOwner owner,
    required String trackId,
    required TrackExportFormat format,
    TrackExportOptions options = const TrackExportOptions(),
    String? fileName,
    bool Function()? isOwnerScopeCurrent,
  }) {
    final operation = _IncrementalTrackExportOperation();
    unawaited(
      _run(
        operation,
        owner: owner,
        trackId: trackId,
        format: format,
        options: options,
        fileName: fileName,
        isOwnerScopeCurrent: isOwnerScopeCurrent ?? _alwaysCurrent,
      ),
    );
    return operation;
  }

  static bool _alwaysCurrent() => true;

  Future<void> _run(
    _IncrementalTrackExportOperation operation, {
    required TrackingOwner owner,
    required String trackId,
    required TrackExportFormat format,
    required TrackExportOptions options,
    required String? fileName,
    required bool Function() isOwnerScopeCurrent,
  }) async {
    IncrementalExportSink? sink;
    String? managedExportId;
    ManagedExportRepository? inventory;
    try {
      if (repository is! StreamingTrackRepository) {
        throw const TrackingStorageException(
          code: 'capability_unsupported',
          message: 'This repository does not support incremental route reads.',
        );
      }
      if (repository is! ManagedExportRepository) {
        throw const TrackingStorageException(
          code: 'capability_unsupported',
          message: 'This repository does not support managed export inventory.',
        );
      }
      final streaming = repository as StreamingTrackRepository;
      inventory = repository as ManagedExportRepository;
      final track = await repository.getTrack(trackId);
      if (track == null || !owner.owns(track)) {
        throw const TrackingOwnershipException(
          code: 'track_not_found_in_owner_scope',
          message: 'The route is not available in the current owner scope.',
        );
      }
      if (track.status != TrackStatus.completed &&
          !options.allowIncompleteTrackSnapshot) {
        throw TrackingStorageException(
          code: 'export_track_incomplete',
          message: 'Only completed routes can be exported by default.',
          trackId: track.id,
        );
      }
      operation.checkpoint(isOwnerScopeCurrent);
      final snapshot = await streaming.createTrackDataSnapshot(
        owner: owner,
        trackId: track.id,
      );
      operation.checkpoint(isOwnerScopeCurrent);
      final geometry = options.geometry;
      if (geometry is DerivedTrackGeometry) {
        if (options.includeRejectedPoints) {
          throw const TrackingStorageException(
            code: 'derived_geometry_rejected_points_unsupported',
            message: 'Derived exports cannot include rejected raw points.',
          );
        }
        if (repository is! DerivedGeometryRepository) {
          throw const TrackingStorageException(
            code: 'capability_unsupported',
            message: 'This repository does not support derived geometry.',
          );
        }
        final run = await (repository as DerivedGeometryRepository)
            .getDerivedGeometryRun(
          owner: owner,
          trackId: track.id,
          runId: geometry.runId,
        );
        if (run == null ||
            run.status != DerivedGeometryRunStatus.completed ||
            run.sourceMaximumSequence < snapshot.upperSequence) {
          throw const TrackingStorageException(
            code: 'derived_geometry_unavailable',
            message: 'The selected derivation does not cover this snapshot.',
          );
        }
      }

      final extension = _extension(format);
      final fallback = _defaultFileName(track, extension);
      final resolvedName = resolveExportFileName(
        format: format,
        fallbackFileName: fallback,
        requestedFileName: fileName,
      );
      final mimeType = _mimeType(format);
      managedExportId = await inventory.beginManagedExport(
        owner: owner,
        trackId: track.id,
        format: format,
      );
      operation.checkpoint(isOwnerScopeCurrent);
      sink = sinkFactory();
      await sink.open(
        IncrementalExportDescriptor(
          fileName: resolvedName,
          mimeType: mimeType,
        ),
      );
      operation.markSinkOpened(sink);

      final encoder = _PagedTrackEncoder(
        repository: streaming,
        owner: owner,
        track: track,
        snapshot: snapshot,
        options: options,
        segmentPageSize: segmentPageSize,
        pointPageSize: pointPageSize,
        operation: operation,
        isOwnerScopeCurrent: isOwnerScopeCurrent,
      );
      final counts = switch (format) {
        TrackExportFormat.geoJson => await encoder.writeGeoJson(),
        TrackExportFormat.kml => await encoder.writeKml(),
        TrackExportFormat.gpx => await encoder.writeGpx(),
      };
      operation.checkpoint(isOwnerScopeCurrent);
      final destination = await sink.commit();
      operation.checkpoint(isOwnerScopeCurrent);
      await inventory.commitManagedExport(
        owner: owner,
        exportId: managedExportId,
        destination: destination,
      );
      operation.markSinkCommitted();
      operation.complete(
        TrackExportResultV2(
          managedExportId: managedExportId,
          trackId: track.id,
          format: format,
          destination: destination,
          pointCount: counts.points,
          segmentCount: counts.segments,
          byteLength: operation.bytesWritten,
        ),
      );
    } on Object catch (error, stackTrace) {
      if (sink != null) {
        try {
          await sink.abort();
        } on Object {
          // Preserve the primary export/cancellation failure.
        }
      }
      if (inventory != null && managedExportId != null) {
        try {
          await inventory.abortManagedExport(
            owner: owner,
            exportId: managedExportId,
          );
        } on Object {
          // Preserve the primary export/cancellation failure.
        }
      }
      operation.completeError(error, stackTrace);
    } finally {
      await operation.closeProgress();
    }
  }
}

/// Incremental filesystem sink using a temporary file and atomic rename.
final class FileSystemIncrementalExportSink implements IncrementalExportSink {
  FileSystemIncrementalExportSink(
    this.directoryPath, {
    this.userVisible = false,
  });

  final String directoryPath;
  final bool userVisible;
  RandomAccessFile? _file;
  File? _temporary;
  File? _destination;
  IncrementalExportDescriptor? _descriptor;
  bool _committed = false;

  @override
  Future<void> open(IncrementalExportDescriptor descriptor) async {
    if (_file != null || _committed) {
      throw StateError('Incremental export sink is already open.');
    }
    final directory = Directory(directoryPath);
    await directory.create(recursive: true);
    final safeName = sanitizeExportFileName(descriptor.fileName);
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
    _destination = destination;
    _temporary = temporary;
    _descriptor = descriptor;
    _file = await temporary.open(mode: FileMode.write);
  }

  @override
  Future<void> addUtf8(List<int> bytes) async {
    final file = _file;
    if (file == null || _committed) {
      throw StateError('Incremental export sink is not writable.');
    }
    await file.writeFrom(bytes);
  }

  @override
  Future<TrackExportDestination> commit() async {
    final file = _file;
    final temporary = _temporary;
    final destination = _destination;
    if (file == null ||
        temporary == null ||
        destination == null ||
        _committed) {
      throw StateError('Incremental export sink cannot be committed.');
    }
    await file.flush();
    await file.close();
    _file = null;
    await temporary.rename(destination.path);
    _committed = true;
    return TrackExportDestination(
      displayName: path_util.basename(destination.path),
      mimeType: _descriptor!.mimeType,
      localFilePath: destination.path,
      displayPath: destination.path,
      userVisible: userVisible,
    );
  }

  @override
  Future<void> abort() async {
    if (_committed) {
      final destination = _destination;
      _committed = false;
      if (destination != null && await destination.exists()) {
        await destination.delete();
      }
      return;
    }
    final file = _file;
    _file = null;
    if (file != null) {
      try {
        await file.close();
      } on Object {
        // Continue removing the partial file.
      }
    }
    final temporary = _temporary;
    if (temporary != null && await temporary.exists()) {
      await temporary.delete();
    }
  }
}

final class _IncrementalTrackExportOperation implements TrackExportOperation {
  final StreamController<TrackExportProgress> _progress =
      StreamController<TrackExportProgress>.broadcast();
  final Completer<TrackExportResultV2> _result =
      Completer<TrackExportResultV2>();
  final Completer<void> _finished = Completer<void>();
  bool _cancelled = false;
  bool _sinkOpened = false;
  bool _sinkCommitted = false;
  IncrementalExportSink? _activeSink;
  int pointsWritten = 0;
  int bytesWritten = 0;

  @override
  Stream<TrackExportProgress> get progress => _progress.stream;

  @override
  Future<TrackExportResultV2> get result => _result.future;

  @override
  Future<void> cancel() async {
    _cancelled = true;
    if (!_finished.isCompleted) await _finished.future;
  }

  void markSinkOpened(IncrementalExportSink sink) {
    _activeSink = sink;
    _sinkOpened = true;
  }

  void markSinkCommitted() {
    _sinkCommitted = true;
    _activeSink = null;
  }

  void checkpoint(bool Function() isOwnerScopeCurrent) {
    if (_cancelled) {
      throw const TrackingException(
        code: 'export_cancelled',
        message: 'The incremental export was cancelled.',
      );
    }
    if (!isOwnerScopeCurrent()) {
      throw const TrackingOwnershipException(
        code: 'owner_scope_changed',
        message: 'The owner scope changed during export.',
      );
    }
  }

  Future<void> addChunk(
    IncrementalExportSink sink,
    String value, {
    int processedPoints = 0,
  }) async {
    final bytes = utf8.encode(value);
    await sink.addUtf8(bytes);
    pointsWritten += processedPoints;
    bytesWritten += bytes.length;
    emitProgress();
  }

  void addProcessedPoints(int count) {
    pointsWritten += count;
    emitProgress();
  }

  void emitProgress() {
    if (_progress.isClosed) return;
    _progress.add(
      TrackExportProgress(
        pointsWritten: pointsWritten,
        bytesWritten: bytesWritten,
      ),
    );
  }

  void complete(TrackExportResultV2 value) {
    if (!_result.isCompleted) _result.complete(value);
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (!_result.isCompleted) _result.completeError(error, stackTrace);
  }

  Future<void> closeProgress() async {
    if (!_progress.isClosed) await _progress.close();
    if (!_finished.isCompleted) _finished.complete();
  }
}

final class _PagedTrackEncoder {
  _PagedTrackEncoder({
    required this.repository,
    required this.owner,
    required this.track,
    required this.snapshot,
    required this.options,
    required this.segmentPageSize,
    required this.pointPageSize,
    required this.operation,
    required this.isOwnerScopeCurrent,
  });

  final StreamingTrackRepository repository;
  final TrackingOwner owner;
  final Track track;
  final TrackDataSnapshot snapshot;
  final TrackExportOptions options;
  final int segmentPageSize;
  final int pointPageSize;
  final _IncrementalTrackExportOperation operation;
  final bool Function() isOwnerScopeCurrent;

  IncrementalExportSink get sink => operation._sinkForEncoding;

  Future<_ExportCounts> writeGeoJson() async {
    final scan = await _scanRoute();
    operation.checkpoint(isOwnerScopeCurrent);
    await operation.addChunk(
      sink,
      '{"type":"FeatureCollection","features":['
      '{"type":"Feature","properties":${jsonEncode(_trackProperties(track, options))},'
      '"geometry":',
    );
    if (scan.lineSegments == 0) {
      await operation.addChunk(sink, 'null}');
      await _markAllSelectedPointsProcessed();
    } else {
      final multi = scan.lineSegments > 1;
      await operation.addChunk(
        sink,
        multi
            ? '{"type":"MultiLineString","coordinates":['
            : '{"type":"LineString","coordinates":',
      );
      var wroteLine = false;
      await _walkSegments((segment) async {
        final segmentScan = await _scanSegment(segment.id);
        final includeLine = segmentScan.validCoordinates >= 2;
        if (includeLine) {
          if (multi && wroteLine) await operation.addChunk(sink, ',');
          await operation.addChunk(sink, '[');
        }
        var wroteCoordinate = false;
        await _walkPointPages(segment.id, (points) async {
          final selected = points.where(_isSelected).toList(growable: false);
          final buffer = StringBuffer();
          for (final point in selected) {
            operation.checkpoint(isOwnerScopeCurrent);
            if (includeLine && _hasValidCoordinate(point)) {
              if (wroteCoordinate) buffer.write(',');
              buffer.write(jsonEncode(_geoJsonCoordinate(point)));
              wroteCoordinate = true;
            }
          }
          if (buffer.isNotEmpty) {
            await operation.addChunk(sink, buffer.toString());
          }
          operation.addProcessedPoints(selected.length);
        });
        if (includeLine) {
          await operation.addChunk(sink, ']');
          wroteLine = true;
        }
      });
      await operation.addChunk(sink, multi ? ']}}' : '}}');
    }

    if (options.includeGeoJsonPointFeatures) {
      await _walkSegments((segment) async {
        await _walkPointPages(segment.id, (points) async {
          final buffer = StringBuffer();
          for (final point in points.where(_isSelected)) {
            operation.checkpoint(isOwnerScopeCurrent);
            buffer
              ..write(',')
              ..write(jsonEncode(_geoJsonPointFeature(point)));
          }
          if (buffer.isNotEmpty) {
            await operation.addChunk(sink, buffer.toString());
          }
        });
      });
    }
    await operation.addChunk(sink, ']}');
    return _ExportCounts(points: scan.selectedPoints, segments: scan.segments);
  }

  Future<_ExportCounts> writeKml() async {
    var pointCount = 0;
    var segmentCount = 0;
    await operation.addChunk(
      sink,
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<kml xmlns="http://www.opengis.net/kml/2.2"><Document>'
      '<name>${_xmlText(_trackName(track))}</name>'
      '<ExtendedData><Data name="geometrySource"><value>'
      '${_xmlText(_geometryLabel(options.geometry))}'
      '</value></Data></ExtendedData>',
    );
    await _walkSegments((segment) async {
      segmentCount += 1;
      final scan = await _scanSegment(segment.id);
      pointCount += scan.selectedPoints;
      if (scan.validCoordinates == 0) {
        operation.addProcessedPoints(scan.selectedPoints);
        return;
      }
      final line = scan.validCoordinates >= 2;
      final title = line
          ? 'Segment ${segment.segmentNumber}'
          : 'Segment ${segment.segmentNumber} point';
      await operation.addChunk(
        sink,
        '<Placemark><name>${_xmlText(title)}</name>'
        '<ExtendedData><Data name="segmentNumber"><value>'
        '${segment.segmentNumber}</value></Data><Data name="pointCount"><value>'
        '${scan.validCoordinates}</value></Data></ExtendedData>'
        '${line ? '<LineString><tessellate>1</tessellate><coordinates>' : '<Point><coordinates>'}',
      );
      final bufferState = _CommaState(separator: '\n');
      await _walkPointPages(segment.id, (points) async {
        final selected = points.where(_isSelected).toList(growable: false);
        final buffer = StringBuffer();
        for (final point in selected) {
          operation.checkpoint(isOwnerScopeCurrent);
          if (_hasValidCoordinate(point)) {
            bufferState.write(buffer, _kmlCoordinate(point));
          }
        }
        if (buffer.isNotEmpty) {
          await operation.addChunk(sink, buffer.toString());
        }
        operation.addProcessedPoints(selected.length);
      });
      await operation.addChunk(
        sink,
        line
            ? '</coordinates></LineString></Placemark>'
            : '</coordinates></Point></Placemark>',
      );
    });
    await operation.addChunk(sink, '</Document></kml>');
    return _ExportCounts(points: pointCount, segments: segmentCount);
  }

  Future<_ExportCounts> writeGpx() async {
    var pointCount = 0;
    var segmentCount = 0;
    final name = _xmlText(_trackName(track));
    await operation.addChunk(
      sink,
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<gpx version="1.1" creator="flutter_background_location" '
      'xmlns="http://www.topografix.com/GPX/1/1" '
      'xmlns:fbl="https://github.com/flutter-background-location/extensions/1" '
      'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
      'xsi:schemaLocation="http://www.topografix.com/GPX/1/1 '
      'http://www.topografix.com/GPX/1/1/gpx.xsd">'
      '<metadata><name>$name</name><time>${_formatTime(track.startedAt, options)}</time>'
      '<desc>${_xmlText(_geometryLabel(options.geometry))}</desc>'
      '</metadata><trk><name>$name</name>',
    );
    await _walkSegments((segment) async {
      segmentCount += 1;
      await operation.addChunk(sink, '<trkseg>');
      await _walkPointPages(segment.id, (points) async {
        final selected = points.where(_isSelected).toList(growable: false);
        pointCount += selected.length;
        final buffer = StringBuffer();
        for (final point in selected) {
          operation.checkpoint(isOwnerScopeCurrent);
          if (_hasValidCoordinate(point)) {
            buffer.write(_gpxPoint(point));
          }
        }
        if (buffer.isNotEmpty) {
          await operation.addChunk(sink, buffer.toString());
        }
        operation.addProcessedPoints(selected.length);
      });
      await operation.addChunk(sink, '</trkseg>');
    });
    await operation.addChunk(sink, '</trk></gpx>');
    return _ExportCounts(points: pointCount, segments: segmentCount);
  }

  Future<_RouteScan> _scanRoute() async {
    var segments = 0;
    var selectedPoints = 0;
    var lineSegments = 0;
    await _walkSegments((segment) async {
      segments += 1;
      final scan = await _scanSegment(segment.id);
      selectedPoints += scan.selectedPoints;
      if (scan.validCoordinates >= 2) lineSegments += 1;
    });
    return _RouteScan(
      segments: segments,
      selectedPoints: selectedPoints,
      lineSegments: lineSegments,
    );
  }

  Future<_SegmentScan> _scanSegment(String segmentId) async {
    var selectedPoints = 0;
    var validCoordinates = 0;
    await _walkPointPages(segmentId, (points) async {
      for (final point in points) {
        if (!_isSelected(point)) continue;
        selectedPoints += 1;
        if (_hasValidCoordinate(point)) validCoordinates += 1;
      }
    });
    return _SegmentScan(
      selectedPoints: selectedPoints,
      validCoordinates: validCoordinates,
    );
  }

  Future<void> _markAllSelectedPointsProcessed() =>
      _walkSegments((segment) async {
        await _walkPointPages(segment.id, (points) async {
          operation.addProcessedPoints(points.where(_isSelected).length);
        });
      });

  Future<void> _walkSegments(
    Future<void> Function(TrackSegment segment) visit,
  ) async {
    String? cursor;
    do {
      operation.checkpoint(isOwnerScopeCurrent);
      final page = await repository.listSegmentPage(
        owner: owner,
        trackId: track.id,
        limit: segmentPageSize,
        cursor: cursor,
        snapshot: snapshot,
      );
      for (final segment in page.items) {
        operation.checkpoint(isOwnerScopeCurrent);
        await visit(segment);
      }
      cursor = page.nextCursor;
      if (!page.hasMore) break;
    } while (true);
  }

  Future<void> _walkPointPages(
    String segmentId,
    Future<void> Function(List<TrackPoint> points) visit,
  ) async {
    String? cursor;
    do {
      operation.checkpoint(isOwnerScopeCurrent);
      final page = await repository.listPointPage(
        owner: owner,
        trackId: track.id,
        segmentId: segmentId,
        limit: pointPageSize,
        cursor: cursor,
        acceptedOnly: !options.includeRejectedPoints,
        snapshot: snapshot,
      );
      var items = page.items;
      final geometry = options.geometry;
      if (geometry is DerivedTrackGeometry) {
        final derivedStore = repository as DerivedGeometryRepository;
        final coordinates =
            await derivedStore.derivedCoordinatesForSourcePoints(
          owner: owner,
          trackId: track.id,
          runId: geometry.runId,
          sourcePointIds: items.map((point) => point.id),
        );
        items = items.map((point) {
          final derived = coordinates[point.id]!;
          return point.withCoordinates(
            latitude: derived.latitude,
            longitude: derived.longitude,
          );
        }).toList(growable: false);
      }
      await visit(items);
      cursor = page.nextCursor;
      if (!page.hasMore) break;
    } while (true);
  }

  bool _isSelected(TrackPoint point) =>
      point.accepted || options.includeRejectedPoints;

  Map<String, Object?> _geoJsonPointFeature(TrackPoint point) =>
      <String, Object?>{
        'type': 'Feature',
        'properties': _pointProperties(point, options),
        'geometry': _hasValidCoordinate(point)
            ? <String, Object?>{
                'type': 'Point',
                'coordinates': _geoJsonCoordinate(point),
              }
            : null,
      };

  String _gpxPoint(TrackPoint point) {
    final buffer = StringBuffer()
      ..write('<trkpt lat="${_coordinate(point.latitude)}" ')
      ..write('lon="${_coordinate(point.longitude)}">');
    if (point.altitude?.isFinite ?? false) {
      buffer.write('<ele>${point.altitude}</ele>');
    }
    buffer.write('<time>${_formatTime(point.capturedAt, options)}</time>');
    if (options.includePointProperties) {
      buffer
        ..write('<extensions><fbl:sequence>${point.sequence}</fbl:sequence>')
        ..write(
            '<fbl:mockAssessment>${point.mockAssessment.name}</fbl:mockAssessment>');
      if (options.includeActivityMetadata) {
        buffer
          ..write(
              '<fbl:activity>${_xmlText(point.activityType.value)}</fbl:activity>')
          ..write(
              '<fbl:activityConfidence>${point.activityConfidence}</fbl:activityConfidence>');
      }
      buffer.write('</extensions>');
    }
    buffer.write('</trkpt>');
    return buffer.toString();
  }
}

extension on _IncrementalTrackExportOperation {
  IncrementalExportSink get _sinkForEncoding {
    final sink = _activeSink;
    if (!_sinkOpened || _sinkCommitted || sink == null) {
      throw StateError('Incremental export sink is unavailable.');
    }
    return sink;
  }
}

final class _ExportCounts {
  const _ExportCounts({required this.points, required this.segments});
  final int points;
  final int segments;
}

final class _RouteScan {
  const _RouteScan({
    required this.segments,
    required this.selectedPoints,
    required this.lineSegments,
  });
  final int segments;
  final int selectedPoints;
  final int lineSegments;
}

final class _SegmentScan {
  const _SegmentScan({
    required this.selectedPoints,
    required this.validCoordinates,
  });
  final int selectedPoints;
  final int validCoordinates;
}

final class _CommaState {
  _CommaState({required this.separator});
  final String separator;
  bool _hasValue = false;

  void write(StringBuffer buffer, String value) {
    if (_hasValue) buffer.write(separator);
    buffer.write(value);
    _hasValue = true;
  }
}

Map<String, Object?> _trackProperties(
  Track track,
  TrackExportOptions options,
) =>
    <String, Object?>{
      'trackId': track.id,
      'routeId': track.routeId,
      'startedAt': track.startedAt.toUtc().toIso8601String(),
      'completedAt': track.endedAt?.toUtc().toIso8601String(),
      'status': track.status.name,
      'segmentCount': track.segmentCount,
      'acceptedPointCount': track.acceptedPointCount,
      'rejectedPointCount': track.rejectedPointCount,
      'distanceMeters': track.totalDistanceMeters,
      'geometrySource': _geometryLabel(options.geometry),
    };

String _geometryLabel(TrackGeometrySelection selection) => switch (selection) {
      RawTrackGeometry() => 'raw',
      DerivedTrackGeometry(:final runId) => 'derived:$runId',
    };

Map<String, Object?> _pointProperties(
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

List<double> _geoJsonCoordinate(TrackPoint point) => <double>[
      point.longitude,
      point.latitude,
      if (point.altitude?.isFinite ?? false) point.altitude!,
    ];

bool _hasValidCoordinate(TrackPoint point) =>
    point.latitude.isFinite &&
    point.longitude.isFinite &&
    point.latitude >= -90 &&
    point.latitude <= 90 &&
    point.longitude >= -180 &&
    point.longitude <= 180;

String _kmlCoordinate(TrackPoint point) =>
    '${_coordinate(point.longitude)},${_coordinate(point.latitude)},'
    '${point.altitude?.isFinite ?? false ? point.altitude : 0}';

String _coordinate(double value) => value.toStringAsFixed(7);

String _formatTime(DateTime value, TrackExportOptions options) {
  if (options.useUtcTimestamps) return value.toUtc().toIso8601String();
  final local = value.toLocal();
  final offset = local.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final minutes = offset.inMinutes.abs();
  final hoursPart = (minutes ~/ 60).toString().padLeft(2, '0');
  final minutesPart = (minutes % 60).toString().padLeft(2, '0');
  return '${local.toIso8601String()}$sign$hoursPart:$minutesPart';
}

String _trackName(Track track) =>
    track.routeId == null ? 'Track ${track.id}' : 'Route ${track.routeId}';

String _xmlText(String value) =>
    const HtmlEscape(HtmlEscapeMode.element).convert(value);

String _extension(TrackExportFormat format) => switch (format) {
      TrackExportFormat.geoJson => 'geojson',
      TrackExportFormat.kml => 'kml',
      TrackExportFormat.gpx => 'gpx',
    };

String _mimeType(TrackExportFormat format) => switch (format) {
      TrackExportFormat.geoJson => 'application/geo+json',
      TrackExportFormat.kml => 'application/vnd.google-earth.kml+xml',
      TrackExportFormat.gpx => 'application/gpx+xml',
    };

String _defaultFileName(Track track, String extension) {
  final date = track.startedAt.toUtc().toIso8601String().split('T').first;
  final safeId = (track.routeId ?? track.id).replaceAll(
    RegExp(r'[^A-Za-z0-9_-]'),
    '_',
  );
  return 'track_${date}_$safeId.$extension';
}
