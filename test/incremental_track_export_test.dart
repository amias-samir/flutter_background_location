import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_background_location_tracker/src/domain/export_models.dart';
import 'package:flutter_background_location_tracker/src/application/derived_geometry_service.dart';
import 'package:flutter_background_location_tracker/src/domain/derived_geometry.dart';
import 'package:flutter_background_location_tracker/src/domain/route_geometry.dart';
import 'package:flutter_background_location_tracker/src/domain/track_point.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_error.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_start.dart';
import 'package:flutter_background_location_tracker/src/export/incremental_track_export.dart';
import 'package:flutter_background_location_tracker/src/export/track_export_service.dart';
import 'package:flutter_background_location_tracker/src/storage/track_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'test_support.dart';

final class _MemoryIncrementalSink implements IncrementalExportSink {
  _MemoryIncrementalSink({this.writeDelay = Duration.zero});

  final Duration writeDelay;
  final BytesBuilder bytes = BytesBuilder(copy: false);
  IncrementalExportDescriptor? descriptor;
  bool committed = false;
  bool aborted = false;

  String get contents => utf8.decode(bytes.takeBytes());

  @override
  Future<void> open(IncrementalExportDescriptor value) async {
    descriptor = value;
  }

  @override
  Future<void> addUtf8(List<int> value) async {
    if (writeDelay > Duration.zero) await Future<void>.delayed(writeDelay);
    bytes.add(value);
  }

  @override
  Future<TrackExportDestination> commit() async {
    committed = true;
    return TrackExportDestination(
      displayName: descriptor!.fileName,
      mimeType: descriptor!.mimeType,
      localFilePath: '/memory/${descriptor!.fileName}',
      userVisible: false,
    );
  }

  @override
  Future<void> abort() async {
    aborted = true;
  }
}

Iterable<XmlElement> _elements(XmlDocument document, String localName) =>
    document.descendants
        .whereType<XmlElement>()
        .where((element) => element.name.local == localName);

void main() {
  late RepositoryHarness harness;

  setUp(() async {
    harness = RepositoryHarness();
    await harness.initialize();
  });

  tearDown(() => harness.repository.close());

  test('S1-01 incremental formats parse and match legacy route semantics',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'stream-route');
    await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
    );
    await harness.append(
      trackId: trackId,
      latitude: 99,
      longitude: 85.31,
      accepted: false,
      qualityFlags: TrackPointQualityFlag.invalidCoordinate,
      rejectionReason: 'invalid_coordinate',
    );
    await harness.append(
      trackId: trackId,
      latitude: 27.701,
      longitude: 85.301,
    );
    await harness.repository.pauseTrack(trackId, reason: 'break');
    await harness.repository.prepareResume(trackId);
    await harness.repository.markTrackActive(trackId);
    await harness.append(
      trackId: trackId,
      latitude: 27.8,
      longitude: 85.4,
    );
    await harness.repository.completeTrack(trackId, reason: 'finished');

    const owner = TrackingOwner(
      userId: 'user-1',
      organizationId: 'org-1',
    );
    const options = TrackExportOptions(
      includeRejectedPoints: true,
      includeGeoJsonPointFeatures: true,
    );
    final legacy = TrackExportService(
      repository: harness.repository,
      fileWriter: _UnusedWriter(),
    );

    for (final format in TrackExportFormat.values) {
      late _MemoryIncrementalSink sink;
      final service = IncrementalTrackExportService(
        repository: harness.repository,
        pointPageSize: 1,
        segmentPageSize: 1,
        sinkFactory: () => sink = _MemoryIncrementalSink(),
      );
      final progress = <IncrementalTrackExportProgress>[];
      final operation = service.start(
        owner: owner,
        trackId: trackId,
        format: format,
        options: options,
        fileName: 'edited route',
      );
      final subscription = operation.progress.listen(progress.add);
      final result = await operation.result;
      await subscription.cancel();
      final incrementalContents = sink.contents;
      final legacyArtifact = await legacy.renderTrack(
        trackId: trackId,
        format: format,
        options: options,
      );

      expect(result.pointCount, legacyArtifact.pointCount);
      expect(result.segmentCount, legacyArtifact.segmentCount);
      expect(result.byteLength, utf8.encode(incrementalContents).length);
      expect(result.destination.displayName, startsWith('edited route.'));
      final inventory = await harness.repository.getManagedExport(
        owner: owner,
        exportId: result.managedExportId,
      );
      expect(inventory?.state, ManagedExportState.committed);
      expect(
          inventory?.destination?.displayName, result.destination.displayName);
      expect(sink.committed, isTrue);
      expect(sink.aborted, isFalse);
      expect(progress, isNotEmpty);
      expect(progress.last.pointsWritten, result.pointCount);
      expect(progress.last.bytesWritten, result.byteLength);

      switch (format) {
        case TrackExportFormat.geoJson:
          expect(
            jsonDecode(incrementalContents),
            jsonDecode(legacyArtifact.contents),
          );
        case TrackExportFormat.kml:
          final streamed = XmlDocument.parse(incrementalContents);
          final materialized = XmlDocument.parse(legacyArtifact.contents);
          for (final element in <String>['Placemark', 'LineString', 'Point']) {
            expect(
              _elements(streamed, element).length,
              _elements(materialized, element).length,
            );
          }
          String normalizedCoordinates(XmlElement element) => element.innerText
              .trim()
              .split(RegExp(r'\s+'))
              .where((value) => value.isNotEmpty)
              .join('|');
          expect(
            _elements(streamed, 'coordinates').map(normalizedCoordinates),
            _elements(materialized, 'coordinates').map(normalizedCoordinates),
          );
        case TrackExportFormat.gpx:
          final streamed = XmlDocument.parse(incrementalContents);
          final materialized = XmlDocument.parse(legacyArtifact.contents);
          for (final element in <String>['trkseg', 'trkpt']) {
            expect(
              _elements(streamed, element).length,
              _elements(materialized, element).length,
            );
          }
          for (final element in <String>[
            'time',
            'sequence',
            'mockAssessment',
          ]) {
            expect(
              _elements(streamed, element).map((value) => value.innerText),
              _elements(materialized, element).map((value) => value.innerText),
            );
          }
      }
    }
  });

  test('S1-01 cancellation aborts the sink and never commits output', () async {
    final trackId = await harness.createActiveTrack(trackId: 'cancel-route');
    for (var index = 0; index < 30; index += 1) {
      await harness.append(
        trackId: trackId,
        latitude: 27.7 + index / 10000,
        longitude: 85.3,
      );
    }
    await harness.repository.completeTrack(trackId, reason: 'finished');
    late _MemoryIncrementalSink sink;
    final service = IncrementalTrackExportService(
      repository: harness.repository,
      pointPageSize: 1,
      sinkFactory: () => sink = _MemoryIncrementalSink(
        writeDelay: const Duration(milliseconds: 5),
      ),
    );
    final operation = service.start(
      owner: const TrackingOwner(
        userId: 'user-1',
        organizationId: 'org-1',
      ),
      trackId: trackId,
      format: TrackExportFormat.gpx,
    );
    final resultExpectation = expectLater(
      operation.result,
      throwsA(
        isA<TrackingException>().having(
          (error) => error.code,
          'code',
          'export_cancelled',
        ),
      ),
    );
    await operation.progress.firstWhere((value) => value.pointsWritten > 0);
    final stopwatch = Stopwatch()..start();
    await operation.cancel();
    stopwatch.stop();
    await resultExpectation;

    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(sink.aborted, isTrue);
    expect(sink.committed, isFalse);
  });

  test('streaming and legacy exporters agree in every continuity mode',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'mode-parity');
    await harness.append(trackId: trackId, latitude: 0, longitude: 0);
    await harness.append(trackId: trackId, latitude: 0, longitude: 0.001);
    await harness.repository.pauseTrack(trackId, reason: 'explicit_pause');
    await harness.repository.prepareResume(trackId);
    await harness.repository.markTrackActive(trackId);
    await harness.append(trackId: trackId, latitude: 1, longitude: 1);
    await harness.append(trackId: trackId, latitude: 1, longitude: 1.001);
    await harness.repository.completeTrack(trackId, reason: 'finished');
    const owner = TrackingOwner(userId: 'user-1', organizationId: 'org-1');
    final legacy = TrackExportService(
      repository: harness.repository,
      fileWriter: _UnusedWriter(),
    );

    for (final continuity in RouteGeometryContinuity.values) {
      for (final format in TrackExportFormat.values) {
        final options = TrackExportOptions(geometryContinuity: continuity);
        final artifact = await legacy.renderTrack(
          trackId: trackId,
          format: format,
          options: options,
        );
        late _MemoryIncrementalSink sink;
        final result = await IncrementalTrackExportService(
          repository: harness.repository,
          pointPageSize: 1,
          segmentPageSize: 1,
          sinkFactory: () => sink = _MemoryIncrementalSink(),
        )
            .start(
              owner: owner,
              trackId: trackId,
              format: format,
              options: options,
            )
            .result;

        expect(result.sourceSegmentCount, artifact.sourceSegmentCount);
        expect(result.geometryPartCount, artifact.geometryPartCount);
        expect(result.gapCount, artifact.gapCount);
        expect(result.inferredConnectorCount, artifact.inferredConnectorCount);
        expect(sink.contents, isNotEmpty);
      }
    }
  });

  test('Q1-05 V2 export selects and labels immutable derived geometry',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'derived-export');
    await harness.append(trackId: trackId, latitude: 0, longitude: 0);
    await harness.append(trackId: trackId, latitude: 2, longitude: 2);
    await harness.repository.completeTrack(trackId, reason: 'finished');
    const owner = TrackingOwner(userId: 'user-1', organizationId: 'org-1');
    final run = await DerivedGeometryService(harness.repository).derive(
      owner: owner,
      trackId: trackId,
      request: const DerivedGeometryRequest(smoothingFactor: 0.5),
    );
    late _MemoryIncrementalSink sink;
    final operation = IncrementalTrackExportService(
      repository: harness.repository,
      pointPageSize: 1,
      sinkFactory: () => sink = _MemoryIncrementalSink(),
    ).start(
      owner: owner,
      trackId: trackId,
      format: TrackExportFormat.geoJson,
      options: TrackExportOptions(
        geometry: TrackGeometrySelection.derived(run.id),
      ),
    );

    await operation.result;
    final json = jsonDecode(sink.contents) as Map<String, dynamic>;
    final feature = (json['features'] as List).first as Map<String, dynamic>;
    expect(feature['properties']['geometrySource'], 'derived:${run.id}');
    expect(
      feature['geometry']['coordinates'],
      <Object?>[
        <Object?>[0.0, 0.0],
        <Object?>[1.0, 1.0],
      ],
    );
  });

  test('S1-01 owner-generation change fences late progress and result',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'scope-route');
    for (var index = 0; index < 5; index += 1) {
      await harness.append(
        trackId: trackId,
        latitude: 27.7 + index / 10000,
        longitude: 85.3,
      );
    }
    await harness.repository.completeTrack(trackId, reason: 'finished');
    var ownerCurrent = true;
    late _MemoryIncrementalSink sink;
    final operation = IncrementalTrackExportService(
      repository: harness.repository,
      pointPageSize: 1,
      sinkFactory: () => sink = _MemoryIncrementalSink(),
    ).start(
      owner: const TrackingOwner(
        userId: 'user-1',
        organizationId: 'org-1',
      ),
      trackId: trackId,
      format: TrackExportFormat.gpx,
      isOwnerScopeCurrent: () => ownerCurrent,
    );
    final subscription = operation.progress.listen((progress) {
      if (progress.pointsWritten > 0) ownerCurrent = false;
    });

    await expectLater(
      operation.result,
      throwsA(
        isA<TrackingOwnershipException>().having(
          (error) => error.code,
          'code',
          'owner_scope_changed',
        ),
      ),
    );
    await subscription.cancel();
    expect(sink.aborted, isTrue);
    expect(sink.committed, isFalse);
  });

  test('S1-01 filesystem sink removes its partial file on a fenced failure',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'partial-route');
    await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
    );
    await harness.repository.completeTrack(trackId, reason: 'finished');
    final directory =
        await Directory.systemTemp.createTemp('fbl-export-abort-');
    var ownerCurrent = true;
    final operation = IncrementalTrackExportService(
      repository: harness.repository,
      sinkFactory: () => _ScopeChangingFileSink(
        FileSystemIncrementalExportSink(directory.path),
        () => ownerCurrent = false,
      ),
    ).start(
      owner: const TrackingOwner(
        userId: 'user-1',
        organizationId: 'org-1',
      ),
      trackId: trackId,
      format: TrackExportFormat.gpx,
      isOwnerScopeCurrent: () => ownerCurrent,
    );

    await expectLater(
      operation.result,
      throwsA(isA<TrackingOwnershipException>()),
    );
    expect(await directory.list().toList(), isEmpty);
    await directory.delete(recursive: true);
  });
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

final class _ScopeChangingFileSink implements IncrementalExportSink {
  _ScopeChangingFileSink(this.delegate, this.afterOpen);

  final IncrementalExportSink delegate;
  final void Function() afterOpen;

  @override
  Future<void> open(IncrementalExportDescriptor descriptor) async {
    await delegate.open(descriptor);
    afterOpen();
  }

  @override
  Future<void> addUtf8(List<int> bytes) => delegate.addUtf8(bytes);

  @override
  Future<TrackExportDestination> commit() => delegate.commit();

  @override
  Future<void> abort() => delegate.abort();
}
