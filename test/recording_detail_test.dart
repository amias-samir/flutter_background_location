import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_background_location_tracker/src/platform/native_tracker_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:xml/xml.dart';

import 'test_support.dart';

const _owner = TrackingOwner(userId: 'user-1', organizationId: 'org-1');
final _t0 = DateTime.utc(2026, 11, 4, 8);

/// Records one synthetic route: a rejected run between two accepted fixes, a
/// 100 s gap kept in its segment and an interruption that starts a new
/// segment; every fix carries motion evidence and a journaled reading.
Future<void> _record(RepositoryHarness harness, String trackId) async {
  Future<void> append(
    int seconds, {
    required double north,
    bool accepted = true,
    TrackingContinuityDecision? continuity,
  }) async {
    final capturedAt = _t0.add(Duration(seconds: seconds));
    harness.now = capturedAt;
    final reading = ActivitySnapshot(
      type: TrackingActivityType.walking,
      confidence: 90,
      recordedAt: capturedAt,
    );
    await harness.repository.appendPointWithContinuity(
      PointWriteRequest(
        trackId: trackId,
        sample: LocationSample(
          latitude: 27 + north * 0.00001,
          longitude: 85,
          capturedAt: capturedAt,
          horizontalAccuracy: accepted ? 5 : 80,
          eventId: 'event-$seconds',
          activityReadings: <ActivitySnapshot>[reading],
          capturedMotionEvidence: MotionEvidenceSnapshot(
            state: FusedMotionState.moving,
            confidence: 90,
            observedAt: capturedAt,
            reason: 'fresh_step',
            generation: 1,
          ),
        ),
        activity: reading,
        motionState: MotionState.moving,
        accepted: accepted,
        qualityFlags: accepted
            ? TrackPointQualityFlag.none
            : TrackPointQualityFlag.poorAccuracy,
        rejectionReason: accepted ? null : 'poor_accuracy',
      ),
      continuity,
    );
  }

  await append(0, north: 0);
  await append(10, north: 10, accepted: false);
  await append(20, north: 20, accepted: false);
  await append(30, north: 30);
  await append(
    130,
    north: 300,
    continuity: const TrackingContinuityDecision(
      cause: TrackingGapCause.providerUnavailable,
      treatment: TrackingGapTreatment.retainCurrentSegment,
      excludeConnectorFromMeasuredDistance: false,
      policyVersion: TrackingPolicyVersions.continuityPolicy,
    ),
  );
  await append(
    400,
    north: 900,
    continuity: const TrackingContinuityDecision(
      cause: TrackingGapCause.nativeInterruption,
      treatment: TrackingGapTreatment.startNewSegment,
      excludeConnectorFromMeasuredDistance: true,
      policyVersion: TrackingPolicyVersions.continuityPolicy,
    ),
  );
  await append(410, north: 920);
  await harness.repository.recordHealthEvent(
    trackId: trackId,
    type: 'continuity_gap_recorded',
  );
  await harness.repository.recordHealthEvent(
    trackId: trackId,
    type: 'native_tracker_interrupted',
  );
}

final class _Recorded {
  _Recorded(this.directory, this.harness);

  final Directory directory;
  final RepositoryHarness harness;

  String get path => '${directory.path}/route.sqlite';

  /// Opens the same file directly, for row counts.
  Future<Database> raw() => databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );
}

Future<_Recorded> _open(RouteRecordingDetail detail) async {
  final directory = await Directory.systemTemp.createTemp('fbl-detail-');
  final harness = RepositoryHarness(path: '${directory.path}/route.sqlite')
    ..now = _t0;
  await harness.initialize();
  harness.repository
    ..newRouteRecordingDetail = detail
    ..recordsDiagnosticHealthEvents = detail == RouteRecordingDetail.full;
  addTearDown(() async {
    await harness.repository.close();
    await directory.delete(recursive: true);
  });
  return _Recorded(directory, harness);
}

Future<int> _count(Database raw, String table, [String where = '1']) async =>
    (await raw.rawQuery('SELECT COUNT(*) AS n FROM $table WHERE $where'))
        .single['n']! as int;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('resolving the recording detail', () {
    test('automatic is full in debug builds and clean otherwise', () {
      expect(
        TrackingClient.resolveRecordingDetail(
          RouteRecordingDetail.automatic,
          debugBuild: true,
        ),
        RouteRecordingDetail.full,
      );
      expect(
        TrackingClient.resolveRecordingDetail(
          RouteRecordingDetail.automatic,
          debugBuild: false,
        ),
        RouteRecordingDetail.clean,
      );
    });

    test('a forced mode wins over the build mode', () {
      for (final debugBuild in <bool>[true, false]) {
        expect(
          TrackingClient.resolveRecordingDetail(
            RouteRecordingDetail.full,
            debugBuild: debugBuild,
          ),
          RouteRecordingDetail.full,
        );
        expect(
          TrackingClient.resolveRecordingDetail(
            RouteRecordingDetail.clean,
            debugBuild: debugBuild,
          ),
          RouteRecordingDetail.clean,
        );
      }
    });

    test('the default configuration is automatic; tests run full', () {
      const configuration = TrackingConfiguration();
      expect(configuration.recordingDetail, RouteRecordingDetail.automatic);
      expect(
        configuration
            .copyWith(recordingDetail: RouteRecordingDetail.clean)
            .recordingDetail,
        RouteRecordingDetail.clean,
      );
      expect(
        TrackingClient(trackerAdapter: FakeTrackerAdapter()).recordingDetail,
        RouteRecordingDetail.full,
      );
    });

    test('stored names parse; unknown or missing ones are full', () {
      expect(RouteRecordingDetail.stored('clean'), RouteRecordingDetail.clean);
      expect(RouteRecordingDetail.stored('full'), RouteRecordingDetail.full);
      expect(RouteRecordingDetail.stored(null), RouteRecordingDetail.full);
      expect(RouteRecordingDetail.stored('other'), RouteRecordingDetail.full);
      expect(RouteRecordingDetail.tryParse('automatic'),
          RouteRecordingDetail.automatic);
      expect(RouteRecordingDetail.tryParse('other'), isNull);
    });
  });

  group('clean routes', () {
    test('collect and decide the same fixes as full routes', () async {
      final full = await _open(RouteRecordingDetail.full);
      final clean = await _open(RouteRecordingDetail.clean);
      for (final recorded in <_Recorded>[full, clean]) {
        await recorded.harness.createActiveTrack(trackId: 'route');
        await _record(recorded.harness, 'route');
      }
      final fullBundle = await full.harness.repository.loadTrackBundle('route');
      final cleanBundle =
          await clean.harness.repository.loadTrackBundle('route');

      List<Object> fixes(TrackBundle bundle) => <Object>[
            for (final (index, segment) in bundle.segments.indexed)
              for (final point in segment.points)
                (
                  index,
                  point.sequence,
                  point.accepted,
                  point.latitude,
                  point.longitude,
                  point.rejectionReason,
                ),
          ];
      expect(fixes(cleanBundle), fixes(fullBundle));
      expect(cleanBundle.track.totalDistanceMeters,
          fullBundle.track.totalDistanceMeters);
      expect(cleanBundle.track.acceptedPointCount, 5);
      expect(cleanBundle.track.rejectedPointCount, 2);
      expect(cleanBundle.track.segmentCount, 2);
      expect(fullBundle.track.recordingDetail, RouteRecordingDetail.full);
      expect(cleanBundle.track.recordingDetail, RouteRecordingDetail.clean);

      final fullSummary =
          (await full.harness.repository.routeSummary('route'))!;
      final cleanSummary =
          (await clean.harness.repository.routeSummary('route'))!;
      expect(cleanSummary.distanceMeters, fullSummary.distanceMeters);
      expect(cleanSummary.recording, fullSummary.recording);
      expect(fullSummary.qualityEventCount, greaterThan(0));
      expect(fullSummary.visibleGapCount, greaterThan(0));
      expect(cleanSummary.qualityEventCount, 0);
      expect(cleanSummary.visibleGapCount, 0);
      expect(cleanSummary.stopEvidenceRunCount, 0);
    });

    test('store only boundary gaps and no runs, motion or diagnostics',
        () async {
      final full = await _open(RouteRecordingDetail.full);
      final clean = await _open(RouteRecordingDetail.clean);
      for (final recorded in <_Recorded>[full, clean]) {
        await recorded.harness.createActiveTrack(trackId: 'route');
        await _record(recorded.harness, 'route');
      }

      final fullRaw = await full.raw();
      addTearDown(fullRaw.close);
      expect(await _count(fullRaw, 'track_quality_runs'), 1);
      expect(await _count(fullRaw, 'track_continuity_gaps'), 2);
      expect(await _count(fullRaw, 'track_motion_evidence'), greaterThan(0));
      expect(await _count(fullRaw, 'tracking_health_events'), 2);

      final cleanRaw = await clean.raw();
      addTearDown(cleanRaw.close);
      expect(await _count(cleanRaw, 'track_quality_runs'), 0);
      expect(await _count(cleanRaw, 'track_motion_evidence'), 0);
      final gaps = await cleanRaw.query('track_continuity_gaps');
      expect(gaps, hasLength(1));
      expect(gaps.single['visible'], 0);
      expect(gaps.single['before_segment_id'],
          isNot(gaps.single['after_segment_id']));
      expect(gaps.single['cause'], TrackingGapCause.nativeInterruption.name);
      final events = await cleanRaw.query('tracking_health_events');
      expect(events.map((row) => row['type']), <String>[
        'native_tracker_interrupted',
      ]);
      expect(
        await _count(cleanRaw, 'track_points', 'motion_evidence_id IS NULL'),
        7,
      );
    });

    test('keep incremental summaries equal to a refresh', () async {
      final clean = await _open(RouteRecordingDetail.clean);
      await clean.harness.createActiveTrack(trackId: 'route');
      await _record(clean.harness, 'route');
      final repository = clean.harness.repository;
      final live = (await repository.routeSummary('route'))!;
      await repository.refreshRouteSummary('route');
      final recomputed = (await repository.routeSummary('route'))!;
      expect(recomputed.qualityEventCount, live.qualityEventCount);
      expect(recomputed.visibleGapCount, live.visibleGapCount);
      expect(recomputed.stopEvidenceRunCount, live.stopEvidenceRunCount);
      expect(recomputed.distanceMeters, live.distanceMeters);
      expect(recomputed.recording, live.recording);
      expect(recomputed.segmentCount, live.segmentCount);
    });

    test('a route keeps the detail it started with', () async {
      final recorded = await _open(RouteRecordingDetail.clean);
      await recorded.harness.createActiveTrack(trackId: 'route');
      recorded.harness.repository.newRouteRecordingDetail =
          RouteRecordingDetail.full;
      await _record(recorded.harness, 'route');
      final raw = await recorded.raw();
      addTearDown(raw.close);
      expect(await _count(raw, 'track_quality_runs'), 0);
      expect(
        (await recorded.harness.repository.getTrack('route'))!.recordingDetail,
        RouteRecordingDetail.clean,
      );
    });
  });

  group('compaction', () {
    test('clears readings, motion evidence and diagnostics of ended routes',
        () async {
      final recorded = await _open(RouteRecordingDetail.clean);
      final repository = recorded.harness.repository;
      await recorded.harness.createActiveTrack(trackId: 'route');
      await _record(recorded.harness, 'route');
      // Rows a debug build of the same app wrote before the switch.
      final before = await recorded.raw();
      await before.insert('tracking_health_events', <String, Object?>{
        'id': 'debug-event',
        'track_id': 'route',
        'type': 'upload_failed',
        'occurred_at': _t0.toIso8601String(),
      });
      await before.close();

      expect(await repository.compactCleanRoutes(), 0,
          reason: 'an active route can still restart from its readings');
      final summaryBefore = (await repository.routeSummary('route'))!;
      final bundleBefore = await repository.loadTrackBundle('route');
      await repository.completeTrack('route', reason: 'done');

      expect(await repository.compactCleanRoutes(owner: _owner), 1);
      expect(await repository.compactCleanRoutes(), 0);

      final raw = await recorded.raw();
      addTearDown(raw.close);
      expect(
        await _count(raw, 'track_points', 'activity_readings_json IS NULL'),
        7,
      );
      expect(await _count(raw, 'track_motion_evidence'), 0);
      expect(
        (await raw.query('tracking_health_events')).map((row) => row['type']),
        <String>['native_tracker_interrupted'],
      );
      expect(
        (await raw.query('tracks')).single['compacted_at'],
        isNotNull,
      );

      final summaryAfter = (await repository.routeSummary('route'))!;
      final bundleAfter = await repository.loadTrackBundle('route');
      expect(summaryAfter.distanceMeters, summaryBefore.distanceMeters);
      expect(summaryAfter.stopCount, summaryBefore.stopCount);
      expect(summaryAfter.acceptedPointCount, summaryBefore.acceptedPointCount);
      expect(
        bundleAfter.segments.expand((segment) => segment.points).length,
        bundleBefore.segments.expand((segment) => segment.points).length,
      );
      expect(bundleAfter.track.rejectedPointCount, 2);
    });

    test('is owner-scoped and leaves full routes as recorded', () async {
      final recorded = await _open(RouteRecordingDetail.full);
      final repository = recorded.harness.repository;
      await recorded.harness.createActiveTrack(trackId: 'full-route');
      await _record(recorded.harness, 'full-route');
      await repository.completeTrack('full-route', reason: 'done');
      repository.newRouteRecordingDetail = RouteRecordingDetail.clean;
      await recorded.harness.createActiveTrack(trackId: 'clean-route');
      await repository.completeTrack('clean-route', reason: 'done');

      expect(
        await repository.compactCleanRoutes(
          owner: const TrackingOwner(userId: 'other', organizationId: 'org-1'),
        ),
        0,
      );
      expect(await repository.compactCleanRoutes(owner: _owner), 1);
      final raw = await recorded.raw();
      addTearDown(raw.close);
      final tracks = <String, Object?>{
        for (final row in await raw.query('tracks'))
          row['id']! as String: row['compacted_at'],
      };
      expect(tracks['full-route'], isNull);
      expect(tracks['clean-route'], isNotNull);
      expect(
        await _count(
          raw,
          'track_points',
          "track_id = 'full-route' AND activity_readings_json IS NOT NULL",
        ),
        7,
      );
    });
  });

  group('exports', () {
    Future<Map<TrackExportFormat, String>> export(
      RouteRecordingDetail detail,
    ) async {
      final recorded = await _open(detail);
      await recorded.harness.createActiveTrack(trackId: 'route');
      await _record(recorded.harness, 'route');
      await recorded.harness.repository.completeTrack('route', reason: 'done');
      final writer = FakeExportFileWriter();
      final exporter = TrackExportService(
        repository: recorded.harness.repository,
        fileWriter: writer,
      );
      return <TrackExportFormat, String>{
        for (final format in TrackExportFormat.values)
          format: writer.files[(await exporter.exportTrack(
            trackId: 'route',
            format: format,
          ))
              .path]!,
      };
    }

    Set<String> geoJsonKeys(String contents) {
      final keys = <String>{};
      void visit(Object? value) {
        if (value is Map) {
          keys.addAll(value.keys.cast<String>());
          value.values.forEach(visit);
        } else if (value is List) {
          value.forEach(visit);
        }
      }

      visit(jsonDecode(contents));
      return keys;
    }

    Set<String> xmlNames(String contents) => <String>{
          for (final element in XmlDocument.parse(contents)
              .descendants
              .whereType<XmlElement>())
            element.name.local,
          for (final element in XmlDocument.parse(contents)
              .descendants
              .whereType<XmlElement>())
            if (element.getAttribute('name') case final name?) name,
        };

    const evidenceKeys = <String>{
      'qualityEventCount',
      'visibleGapCount',
      'gapCount',
      'rejectedPointCount',
    };

    test('of clean routes leave out quality and gap evidence', () async {
      final full = await export(RouteRecordingDetail.full);
      final clean = await export(RouteRecordingDetail.clean);

      final fullGeoJson = geoJsonKeys(full[TrackExportFormat.geoJson]!);
      final cleanGeoJson = geoJsonKeys(clean[TrackExportFormat.geoJson]!);
      expect(fullGeoJson, containsAll(evidenceKeys));
      expect(cleanGeoJson.intersection(evidenceKeys), isEmpty);
      expect(
          cleanGeoJson, containsAll(<String>{'stopCount', 'distanceMeters'}));

      for (final format in <TrackExportFormat>[
        TrackExportFormat.gpx,
        TrackExportFormat.kml,
      ]) {
        final fullNames = xmlNames(full[format]!);
        final cleanNames = xmlNames(clean[format]!);
        expect(fullNames, contains('qualityEventCount'), reason: '$format');
        expect(cleanNames, isNot(contains('qualityEventCount')));
        expect(cleanNames, isNot(contains('visibleGapCount')));
        expect(cleanNames, isNot(contains('gap')));
        expect(cleanNames, contains('stopCount'), reason: '$format');
      }
    });
  });

  group('the client', () {
    test('records no diagnostics in clean mode', () async {
      final adapter = FakeTrackerAdapter();
      final directory = await Directory.systemTemp.createTemp('fbl-client-');
      final harness = RepositoryHarness(path: '${directory.path}/route.sqlite');
      await harness.initialize();
      final client = TrackingClient(
        configuration: const TrackingConfiguration(
          recordingDetail: RouteRecordingDetail.clean,
        ),
        trackerAdapter: adapter,
        repository: harness.repository,
      );
      addTearDown(() async {
        await client.dispose();
        await directory.delete(recursive: true);
      });
      await client.initialize();
      expect(client.recordingDetail, RouteRecordingDetail.clean);
      expect(client.recordsDiagnostics, isFalse);
      expect(await client.stepCounterDiagnostics(), isEmpty);

      final trackId = await client.startTrack(
        userId: _owner.userId,
        organizationId: _owner.organizationId,
      );
      expect(
        (await client.getTrack(trackId))!.recordingDetail,
        RouteRecordingDetail.clean,
      );
      await client.completeTrack(trackId: trackId);
    });

    test('sends the detail to native code with initialize', () async {
      const channel = MethodChannel('recording-detail-test');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));

      final adapter = NativeTrackerAdapter(methodChannel: channel);
      await adapter.initialize();
      adapter.applyRecordingDetail(RouteRecordingDetail.clean);
      await adapter.initialize();

      expect(calls.map((call) => call.arguments), <Object?>[
        null,
        <String, Object?>{'recordingDetail': 'clean'},
      ]);
      expect(
        NativeTrackingCapabilities.recordingDetailMode,
        'recording_detail_mode',
      );
    });
  });
}
