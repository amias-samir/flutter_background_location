import 'dart:io';

import 'package:flutter_background_location_tracker/src/domain/activity_snapshot.dart';
import 'package:flutter_background_location_tracker/src/domain/location_sample.dart';
import 'package:flutter_background_location_tracker/src/domain/track_point.dart';
import 'package:flutter_background_location_tracker/src/domain/tracker_status.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_config.dart';
import 'package:flutter_background_location_tracker/src/storage/sqlite_track_repository.dart';
import 'package:flutter_background_location_tracker/src/storage/track_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class RepositoryHarness {
  RepositoryHarness({TrackingConfig? config})
      : config = config ?? const TrackingConfig();

  final TrackingConfig config;
  DateTime now = DateTime.utc(2026, 7, 20, 8);

  late final SqliteTrackRepository repository;
  var _nextId = 0;

  Future<void> initialize() async {
    sqfliteFfiInit();
    repository = SqliteTrackRepository(
      path: inMemoryDatabasePath,
      databaseFactoryOverride: databaseFactoryFfi,
      clock: () => now,
      idGenerator: () => 'generated-${_nextId++}',
    );
    await repository.initialize();
  }

  Future<String> createActiveTrack({String trackId = 'track-1'}) async {
    final created = await repository.createTrack(
      userId: 'user-1',
      organizationId: 'org-1',
      config: config,
      requestedTrackId: trackId,
    );
    await repository.markTrackActive(created);
    return created;
  }

  Future<TrackPoint> append({
    required String trackId,
    required double latitude,
    required double longitude,
    DateTime? capturedAt,
    bool accepted = true,
    int qualityFlags = TrackPointQualityFlag.none,
    String? rejectionReason,
    bool isMocked = false,
    bool mockDetectionAvailable = false,
    TrackingActivityType activityType = TrackingActivityType.unknown,
    int activityConfidence = 0,
    MotionState motionState = MotionState.unknown,
    String? eventId,
    String? sourceTrackId,
    DateTime? nativeReceivedAt,
    int? providerTimeDeltaMsAtReceipt,
    int? monotonicFixNanos,
    int? monotonicReceivedNanos,
    String? monotonicDomainId,
  }) {
    final timestamp = capturedAt ?? now;
    return repository.appendPoint(
      PointWriteRequest(
        trackId: trackId,
        sample: LocationSample(
          latitude: latitude,
          longitude: longitude,
          capturedAt: timestamp,
          horizontalAccuracy: 5,
          isMocked: isMocked,
          mockDetectionAvailable: mockDetectionAvailable,
          mockEvidence: isMocked ? 'test_provider' : null,
          provider: 'test',
          eventId: eventId,
          trackId: sourceTrackId,
          nativeReceivedAt: nativeReceivedAt,
          providerTimeDeltaMsAtReceipt: providerTimeDeltaMsAtReceipt,
          monotonicFixNanos: monotonicFixNanos,
          monotonicReceivedNanos: monotonicReceivedNanos,
          monotonicDomainId: monotonicDomainId,
        ),
        activity: ActivitySnapshot(
          type: activityType,
          confidence: activityConfidence,
          recordedAt: timestamp,
        ),
        motionState: motionState,
        accepted: accepted,
        qualityFlags: qualityFlags,
        rejectionReason: rejectionReason,
      ),
    );
  }
}

String readFixture(String relativePath) =>
    File('test/fixtures/$relativePath').readAsStringSync().replaceAll(
          '\r\n',
          '\n',
        );
