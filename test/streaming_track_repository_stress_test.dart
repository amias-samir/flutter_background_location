import 'dart:io';

import 'package:flutter_background_location_tracker/src/domain/export_models.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_config.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_start.dart';
import 'package:flutter_background_location_tracker/src/export/incremental_track_export.dart';
import 'package:flutter_background_location_tracker/src/storage/sqlite_track_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test(
    'D1-01 traverses 100,000 points exactly within the bounded page budget',
    () async {
      sqfliteFfiInit();
      final directory =
          await Directory.systemTemp.createTemp('fbl-stream-100k-');
      final databasePath = '${directory.path}/tracks.sqlite';
      final writer = SqliteTrackRepository(
        path: databasePath,
        databaseFactoryOverride: databaseFactoryFfi,
        singleInstance: false,
      );
      await writer.initialize();
      final trackId = await writer.createTrack(
        userId: 'stress-user',
        organizationId: 'stress-org',
        config: const TrackingConfig(),
        requestedTrackId: 'stress-track',
      );
      final segmentId = (await writer.getTrack(trackId))!.currentSegmentId!;
      await writer.close();

      final database = await databaseFactoryFfi.openDatabase(
        databasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      const pointCount = 100000;
      const chunkSize = 2000;
      final capturedAt = DateTime.utc(2026, 8, 25).toIso8601String();
      await database.transaction((transaction) async {
        for (var start = 1; start <= pointCount; start += chunkSize) {
          final end = (start + chunkSize - 1).clamp(1, pointCount);
          final batch = transaction.batch();
          for (var sequence = start; sequence <= end; sequence += 1) {
            batch.insert('track_points', <String, Object?>{
              'id': 'point-$sequence',
              'track_id': trackId,
              'segment_id': segmentId,
              'sequence': sequence,
              'latitude': 27.7 + sequence / 10000000,
              'longitude': 85.3,
              'captured_at': capturedAt,
              'persisted_at': capturedAt,
              'activity_type': 'unknown',
              'activity_confidence': 0,
              'motion_state': 'unknown',
              'is_mocked': 0,
              'mock_detection_available': 0,
              'mock_assessment': 'unavailable',
              'accepted': sequence.isEven ? 1 : 0,
              'quality_flags': sequence.isEven ? 0 : 1,
              'rejection_reason': sequence.isEven ? null : 'poor_accuracy',
            });
          }
          await batch.commit(noResult: true);
        }
      });
      await database.close();

      final reader = SqliteTrackRepository(
        path: databasePath,
        databaseFactoryOverride: databaseFactoryFfi,
        singleInstance: false,
      );
      await reader.initialize();
      try {
        const owner = TrackingOwner(
          userId: 'stress-user',
          organizationId: 'stress-org',
        );
        String? cursor;
        var expectedSequence = 1;
        var pages = 0;
        final baselineRss = ProcessInfo.currentRss;
        var peakRss = baselineRss;
        do {
          final page = await reader.listPointPage(
            owner: owner,
            trackId: trackId,
            limit: 500,
            cursor: cursor,
          );
          expect(page.estimatedDecodedBytes, lessThanOrEqualTo(1024 * 1024));
          for (final point in page.items) {
            expect(point.sequence, expectedSequence);
            expect(point.accepted, expectedSequence.isEven);
            expectedSequence += 1;
          }
          cursor = page.nextCursor;
          pages += 1;
          if (ProcessInfo.currentRss > peakRss) {
            peakRss = ProcessInfo.currentRss;
          }
          if (!page.hasMore) break;
        } while (true);

        expect(expectedSequence, pointCount + 1);
        expect(pages, 200);
        expect(
          peakRss - baselineRss,
          lessThanOrEqualTo(32 * 1024 * 1024),
          reason: 'Bounded traversal must not retain the complete route.',
        );

        late _CountingSink exportSink;
        final exportBaselineRss = ProcessInfo.currentRss;
        final operation = IncrementalTrackExportService(
          repository: reader,
          pointPageSize: 500,
          sinkFactory: () => exportSink = _CountingSink(exportBaselineRss),
        ).start(
          owner: owner,
          trackId: trackId,
          format: TrackExportFormat.gpx,
          options: const TrackExportOptions(
            includeRejectedPoints: true,
            allowIncompleteTrackSnapshot: true,
          ),
        );
        IncrementalTrackExportProgress? lastProgress;
        final progressSubscription = operation.progress.listen(
          (progress) => lastProgress = progress,
        );
        final exportResult = await operation.result;
        await progressSubscription.cancel();
        expect(exportResult.pointCount, pointCount);
        expect(exportResult.segmentCount, 1);
        expect(exportResult.byteLength, exportSink.bytesWritten);
        expect(exportSink.maximumChunkBytes, lessThanOrEqualTo(1024 * 1024));
        expect(lastProgress?.pointsWritten, pointCount);
        expect(lastProgress?.bytesWritten, exportResult.byteLength);
        expect(
          exportSink.peakRss - exportBaselineRss,
          lessThanOrEqualTo(48 * 1024 * 1024),
          reason: 'RSS is a conservative VM-reservation proxy; decoded pages '
              'and output chunks remain independently bounded.',
        );
      } finally {
        await reader.close();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

final class _CountingSink implements IncrementalExportSink {
  _CountingSink(this.baselineRss) : peakRss = baselineRss;

  final int baselineRss;
  int peakRss;
  int bytesWritten = 0;
  int maximumChunkBytes = 0;
  IncrementalExportDescriptor? descriptor;

  @override
  Future<void> open(IncrementalExportDescriptor value) async {
    descriptor = value;
  }

  @override
  Future<void> addUtf8(List<int> bytes) async {
    bytesWritten += bytes.length;
    if (bytes.length > maximumChunkBytes) maximumChunkBytes = bytes.length;
    final rss = ProcessInfo.currentRss;
    if (rss > peakRss) peakRss = rss;
  }

  @override
  Future<TrackExportDestination> commit() async => TrackExportDestination(
        displayName: descriptor!.fileName,
        mimeType: descriptor!.mimeType,
        localFilePath: '/counted/${descriptor!.fileName}',
        userVisible: false,
      );

  @override
  Future<void> abort() async {}
}
