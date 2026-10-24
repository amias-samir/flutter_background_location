import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';

import '../domain/fix_quality.dart';
import '../domain/route_summary.dart';
import '../domain/step_coverage.dart';
import '../domain/track_point.dart';
import '../domain/tracking_continuity.dart';

/// Schema 17: route details kept in the route database as a route records,
/// so hosts read them instead of computing them.
///
/// Every function runs on the executor of the caller's transaction: a
/// summary changes in the same commit as the point, stop, run or lifecycle
/// change behind it.
abstract final class RouteSummaryStore {
  /// Bumped when a summary's definition changes; rows written under an older
  /// definition are recomputed when the database opens.
  static const summaryVersion = 2;

  /// A Doppler speed counts for the maximum when measured to within this.
  static const maximumSpeedAccuracyMetersPerSecond = 2.0;

  /// Adds the schema 17 columns and tables. Idempotent: also run on every
  /// open, because an upgrade from a database without points returns early.
  static Future<void> ensureSchema(DatabaseExecutor database) async {
    await _addColumn(database, 'track_points', 'step_count', 'INTEGER');
    await _addColumn(database, 'track_segments', 'step_count', 'INTEGER');
    await _addColumn(database, 'track_continuity_gaps', 'visible', 'INTEGER');
    await _addColumn(
        database, 'track_quality_runs', 'stop_evidence', 'INTEGER');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS track_summaries (
        track_id TEXT PRIMARY KEY,
        summary_version INTEGER NOT NULL,
        first_fix_at TEXT,
        last_fix_at TEXT,
        recording_ms INTEGER NOT NULL DEFAULT 0,
        moving_ms INTEGER NOT NULL DEFAULT 0,
        stopped_ms INTEGER NOT NULL DEFAULT 0,
        stop_count INTEGER NOT NULL DEFAULT 0,
        max_speed_mps REAL,
        quality_event_count INTEGER NOT NULL DEFAULT 0,
        visible_gap_count INTEGER NOT NULL DEFAULT 0,
        stop_evidence_run_count INTEGER NOT NULL DEFAULT 0,
        step_count INTEGER,
        cleaned_distance_m REAL,
        cleaned_run_id TEXT,
        stops_source TEXT NOT NULL DEFAULT 'pending',
        step_generation TEXT,
        step_last_count INTEGER,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
        CHECK(recording_ms >= 0 AND moving_ms >= 0 AND stopped_ms >= 0),
        CHECK(stops_source IN ('recorded', 'derived', 'pending'))
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS trip_summaries (
        trip_id TEXT PRIMARY KEY,
        summary_version INTEGER NOT NULL,
        leg_count INTEGER NOT NULL DEFAULT 0,
        segment_count INTEGER NOT NULL DEFAULT 0,
        first_fix_at TEXT,
        last_fix_at TEXT,
        recording_ms INTEGER NOT NULL DEFAULT 0,
        moving_ms INTEGER NOT NULL DEFAULT 0,
        stopped_ms INTEGER NOT NULL DEFAULT 0,
        stop_count INTEGER NOT NULL DEFAULT 0,
        max_speed_mps REAL,
        quality_event_count INTEGER NOT NULL DEFAULT 0,
        visible_gap_count INTEGER NOT NULL DEFAULT 0,
        stop_evidence_run_count INTEGER NOT NULL DEFAULT 0,
        step_count INTEGER,
        cleaned_distance_m REAL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY(trip_id) REFERENCES trips(id) ON DELETE CASCADE
      )
    ''');
    await _addColumn(database, 'track_summaries', 'step_generation', 'TEXT');
    await _addColumn(database, 'track_summaries', 'step_last_count', 'INTEGER');
    // Schema 18: the review that applies the current rules to an older
    // route, the corrected distance and when a stalled step counter stopped.
    await _addColumn(database, 'track_summaries', 'review_run_id', 'TEXT');
    await _addColumn(database, 'track_summaries', 'review_version', 'INTEGER');
    await _addColumn(
      database,
      'track_summaries',
      'corrected_distance_m',
      'REAL',
    );
    await _addColumn(
      database,
      'track_summaries',
      'step_count_stopped_at',
      'TEXT',
    );
    await _addColumn(
        database, 'trip_summaries', 'corrected_distance_m', 'REAL');
    await _addColumn(
      database,
      'trip_summaries',
      'step_count_stopped_at',
      'TEXT',
    );
  }

  static Future<void> _addColumn(
    DatabaseExecutor database,
    String table,
    String column,
    String type,
  ) async {
    // Result-returning PRAGMAs go through rawQuery on Android.
    final columns = await database.rawQuery('PRAGMA table_info($table)');
    if (columns.isEmpty || columns.any((row) => row['name'] == column)) return;
    await database.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  /// Starts [trackId]'s summary. Its stops are [TrackStopSource.recorded] when
  /// the route records them live, else [TrackStopSource.pending] until they
  /// are derived after it completes.
  static Future<void> create(
    DatabaseExecutor database,
    String trackId, {
    required bool recordsStops,
    required DateTime now,
  }) =>
      database.rawInsert(
        '''
        INSERT OR IGNORE INTO track_summaries
          (track_id, summary_version, stops_source, updated_at)
        VALUES (?, ?, ?, ?)
        ''',
        <Object?>[
          trackId,
          summaryVersion,
          recordsStops ? TrackStopSource.recorded : TrackStopSource.pending,
          _timestamp(now),
        ],
      );

  /// After a point of [trackId] was stored.
  static Future<void> onPointStored(
    DatabaseExecutor database, {
    required String trackId,
    required bool accepted,
    required DateTime capturedAt,
    required double? speed,
    required double? speedAccuracy,
    required double maximumPlausibleSpeedMetersPerSecond,
    required DateTime now,
  }) async {
    final current = await _summaryRow(database, trackId);
    if (current == null) return;
    final recording =
        await _recordingMs(database, trackId, openEnd: capturedAt);
    final stopped = (current['stopped_ms'] as num?)?.toInt() ?? 0;
    final fastest = (current['max_speed_mps'] as num?)?.toDouble();
    final measured = accepted &&
            speed != null &&
            speed.isFinite &&
            speed >= 0 &&
            speed <= maximumPlausibleSpeedMetersPerSecond &&
            (speedAccuracy == null ||
                speedAccuracy <= maximumSpeedAccuracyMetersPerSecond)
        ? speed
        : null;
    await database.update(
      'track_summaries',
      <String, Object?>{
        if (accepted && current['first_fix_at'] == null)
          'first_fix_at': _timestamp(capturedAt),
        if (accepted) 'last_fix_at': _timestamp(capturedAt),
        if (measured != null && (fastest == null || measured > fastest))
          'max_speed_mps': measured,
        'recording_ms': recording,
        'moving_ms': math.max(0, recording - stopped),
        'updated_at': _timestamp(now),
      },
      where: 'track_id = ?',
      whereArgs: <Object?>[trackId],
    );
  }

  /// After [trackId]'s stop rows changed.
  static Future<void> onStopsChanged(
    DatabaseExecutor database,
    String trackId, {
    required DateTime now,
  }) async {
    final current = await _summaryRow(database, trackId);
    if (current == null) return;
    final (count, stopped) = await _stops(database, trackId);
    final recording = (current['recording_ms'] as num?)?.toInt() ?? 0;
    await database.update(
      'track_summaries',
      <String, Object?>{
        'stop_count': count,
        'stopped_ms': stopped,
        'moving_ms': math.max(0, recording - stopped),
        'updated_at': _timestamp(now),
      },
      where: 'track_id = ?',
      whereArgs: <Object?>[trackId],
    );
  }

  /// After a rejected-fix run of [trackId] was stored. A quality event is a
  /// run that left a visible hole in the route ([visible]) and was not stop
  /// evidence; an informational run, such as one dropped fix, is not one.
  static Future<void> onQualityRun(
    DatabaseExecutor database,
    String trackId, {
    required bool stopEvidence,
    required bool visible,
    required DateTime now,
  }) =>
      database.rawUpdate(
        '''
        UPDATE track_summaries
        SET quality_event_count = quality_event_count + ?,
            stop_evidence_run_count = stop_evidence_run_count + ?,
            updated_at = ?
        WHERE track_id = ?
        ''',
        <Object?>[
          !stopEvidence && visible ? 1 : 0,
          stopEvidence ? 1 : 0,
          _timestamp(now),
          trackId,
        ],
      );

  /// After [count] visible runs of [trackId] became informational because a
  /// stop opened right after them.
  static Future<void> onQualityRunsDowngraded(
    DatabaseExecutor database,
    String trackId, {
    required int count,
    required DateTime now,
  }) async {
    if (count <= 0) return;
    await database.rawUpdate(
      '''
      UPDATE track_summaries
      SET quality_event_count = MAX(0, quality_event_count - ?), updated_at = ?
      WHERE track_id = ?
      ''',
      <Object?>[count, _timestamp(now), trackId],
    );
  }

  /// After a continuity gap of [trackId] was stored.
  static Future<void> onGap(
    DatabaseExecutor database,
    String trackId, {
    required bool visible,
    required DateTime now,
  }) async {
    if (!visible) return;
    await database.rawUpdate(
      '''
      UPDATE track_summaries
      SET visible_gap_count = visible_gap_count + 1, updated_at = ?
      WHERE track_id = ?
      ''',
      <Object?>[_timestamp(now), trackId],
    );
  }

  /// Records capture generation [generation]'s cumulative [stepCount] and
  /// the counter's [coverage] in the generation's live
  /// `track_step_generations` row (schema 18).
  ///
  /// Native counts are cumulative within a generation, so a generation counts
  /// once, at its highest count, in whatever order its counts arrive: a
  /// higher count adds its increase to the segment the generation began in,
  /// and a repeated or lower one adds nothing. A fix journaled after a final
  /// count from status, or a final recorded again during recovery, never
  /// counts twice.
  ///
  /// The count is incomplete from `stopped_at`: the last rise of a counter
  /// that stalled, or where a generation ended without a final flush. A rise
  /// while counting again clears it.
  ///
  /// Returns the coverage state before and after, for health events.
  static Future<(String?, String?)> onStepCount(
    DatabaseExecutor database, {
    required String trackId,
    required String segmentId,
    required String? generation,
    required int stepCount,
    StepCoverage? coverage,
    required DateTime now,
  }) async {
    final current = await _summaryRow(database, trackId);
    if (current == null) return (null, null);
    final key = generation ?? '';
    final rows = await database.query(
      'track_step_generations',
      where: 'track_id = ? AND capture_generation_id = ? '
          'AND review_run_id IS NULL',
      whereArgs: <Object?>[trackId, key],
      limit: 1,
    );
    final existing = rows.isEmpty ? null : rows.single;
    // A route recording across the schema 18 upgrade kept its newest
    // generation's count in the summary row.
    final previous = (existing?['step_count'] as num?)?.toInt() ??
        (current['step_generation'] == key
            ? (current['step_last_count'] as num?)?.toInt()
            : null);
    final delta = stepCount - (previous ?? 0);
    final before = existing?['coverage_state'] as String?;
    final stoppedBefore = existing?['stopped_at'] as String?;
    final stoppedAt = _stepsStoppedAtAfter(
      stoppedBefore,
      coverage,
      rose: delta > 0,
    );
    final rowSegment = existing?['segment_id'] as String? ?? segmentId;
    final values = <String, Object?>{
      'step_count': math.max(stepCount, previous ?? 0),
      if (coverage?.lastRiseAt case final rise?)
        'last_rise_at': _timestamp(rise),
      if (coverage?.countedThrough case final through?)
        'counted_through': _timestamp(through),
      if (coverage != null) 'coverage_state': coverage.state.name,
      if (coverage != null) 'decided_by': 'native',
      'stopped_at': stoppedAt,
      'updated_at': _timestamp(now),
    };
    if (existing == null) {
      await database.insert('track_step_generations', <String, Object?>{
        'id': 'live:$trackId:$key',
        'track_id': trackId,
        'segment_id': rowSegment,
        'capture_generation_id': key,
        ...values,
      });
    } else if (delta > 0 ||
        coverage != null && coverage.state.name != before ||
        stoppedAt != stoppedBefore) {
      await database.update(
        'track_step_generations',
        values,
        where: 'id = ?',
        whereArgs: <Object?>[existing['id']],
      );
    }
    if (delta > 0) {
      await database.rawUpdate(
        '''
        UPDATE track_segments SET step_count = COALESCE(step_count, 0) + ?
        WHERE id = ?
        ''',
        <Object?>[delta, rowSegment],
      );
    }
    if (delta > 0 || stoppedAt != stoppedBefore || existing == null) {
      await database.update(
        'track_summaries',
        <String, Object?>{
          'step_generation': key,
          'step_last_count': math.max(stepCount, previous ?? 0),
          'step_count': await _steps(database, trackId),
          'step_count_stopped_at': await _stepsStoppedAt(database, trackId),
          'updated_at': _timestamp(now),
        },
        where: 'track_id = ?',
        whereArgs: <Object?>[trackId],
      );
    }
    return (before, coverage?.state.name ?? before);
  }

  /// Where a generation's count stops being complete after [coverage]
  /// arrives: the last rise of a stalled counter or the last count of a
  /// generation that ended unflushed, kept at its earliest; a rise while
  /// counting with nothing uncounted clears it.
  static String? _stepsStoppedAtAfter(
    String? before,
    StepCoverage? coverage, {
    required bool rose,
  }) {
    if (coverage == null) return before;
    final state = coverage.state;
    if (state == StepCoverageState.stalled) {
      return before ??
          _optionalTimestamp(coverage.lastRiseAt ?? coverage.countedThrough);
    }
    if (state == StepCoverageState.endedUnflushed) {
      return before ??
          _optionalTimestamp(coverage.countedThrough ?? coverage.lastRiseAt);
    }
    if (state == StepCoverageState.counting &&
        rose &&
        coverage.uncounted == Duration.zero) {
      return null;
    }
    return before;
  }

  static String? _optionalTimestamp(DateTime? value) =>
      value == null ? null : _timestamp(value);

  /// After [trackId]'s segment step counts changed.
  static Future<void> onStepsChanged(
    DatabaseExecutor database,
    String trackId, {
    required DateTime now,
  }) async =>
      database.update(
        'track_summaries',
        <String, Object?>{
          'step_count': await _steps(database, trackId),
          'updated_at': _timestamp(now),
        },
        where: 'track_id = ?',
        whereArgs: <Object?>[trackId],
      );

  /// Records the cleaned view [runId] of [trackId] and its length.
  static Future<void> onCleanedGeometry(
    DatabaseExecutor database,
    String trackId, {
    required String runId,
    required double distanceMeters,
    required DateTime now,
  }) =>
      database.update(
        'track_summaries',
        <String, Object?>{
          'cleaned_run_id': runId,
          'cleaned_distance_m': distanceMeters,
          'updated_at': _timestamp(now),
        },
        where: 'track_id = ?',
        whereArgs: <Object?>[trackId],
      );

  /// Sets where [trackId]'s stops came from.
  static Future<void> setStopsSource(
    DatabaseExecutor database,
    String trackId,
    String source, {
    required DateTime now,
  }) =>
      database.update(
        'track_summaries',
        <String, Object?>{
          'stops_source': source,
          'updated_at': _timestamp(now)
        },
        where: 'track_id = ?',
        whereArgs: <Object?>[trackId],
      );

  /// Recomputes [trackId]'s summary from its stored rows: at lifecycle
  /// changes, on open for rows of an older [summaryVersion], and after the
  /// schema 17 upgrade. Missing per-run and per-gap decisions of older rows
  /// are filled in first. A new row's stops are [TrackStopSource.recorded]
  /// when [recordsStops] or when the track already has stop rows.
  static Future<void> refresh(
    DatabaseExecutor database,
    String trackId, {
    required bool recordsStops,
    required double maximumPlausibleSpeedMetersPerSecond,
    required DateTime now,
  }) async {
    // Whole rows: databases upgraded from early schemas lack some columns.
    final tracks = await database.query(
      'tracks',
      where: 'id = ?',
      whereArgs: <Object?>[trackId],
      limit: 1,
    );
    if (tracks.isEmpty) return;
    // A table an early schema never had counts as empty.
    final tables = await _tableNames(database);
    if (!tables.contains('track_summaries')) return;
    final hasRuns = tables.contains('track_quality_runs');
    final hasGaps = tables.contains('track_continuity_gaps');
    final hasSegments = tables.contains('track_segments');
    if (hasRuns) await _fillRunDecisions(database, trackId);
    if (hasGaps) await _fillGapDecisions(database, trackId);
    final (stopCount, stopped) = tables.contains('track_stops')
        ? await _stops(database, trackId)
        : (0, 0);
    final lastPointAt =
        DateTime.tryParse('${tracks.single['last_point_at']}')?.toUtc();
    final recording = hasSegments
        ? await _recordingMs(database, trackId, openEnd: lastPointAt)
        : 0;
    final pointColumns = tables.contains('track_points')
        ? await _columnNames(database, 'track_points')
        : const <String>{};
    final hasFixes = pointColumns.contains('captured_at') &&
        pointColumns.contains('accepted');
    final fixes = hasFixes
        ? (await database.rawQuery(
            '''
            SELECT MIN(captured_at) AS first_fix_at,
                   MAX(captured_at) AS last_fix_at
            FROM track_points WHERE track_id = ? AND accepted = 1
            ''',
            <Object?>[trackId],
          ))
            .single
        : const <String, Object?>{};
    final fastest = hasFixes &&
            pointColumns.contains('speed') &&
            pointColumns.contains('speed_accuracy')
        ? (await database.rawQuery(
            '''
            SELECT MAX(speed) AS fastest FROM track_points
            WHERE track_id = ? AND accepted = 1 AND speed IS NOT NULL
              AND speed >= 0 AND speed <= ?
              AND (speed_accuracy IS NULL OR speed_accuracy <= ?)
            ''',
            <Object?>[
              trackId,
              maximumPlausibleSpeedMetersPerSecond,
              maximumSpeedAccuracyMetersPerSecond,
            ],
          ))
            .single['fastest']
        : null;
    final (runWhere, runArgs) = hasRuns
        ? await rowsOf(database, 'track_quality_runs', trackId)
        : ('', const <Object?>[]);
    final runs = hasRuns
        ? (await database.rawQuery(
            '''
            SELECT
              COALESCE(SUM(CASE WHEN stop_evidence = 1 THEN 0
                WHEN severity = 'visibleGap' THEN 1 ELSE 0 END), 0)
                AS quality_events,
              COALESCE(SUM(CASE WHEN stop_evidence = 1 THEN 1 ELSE 0 END), 0)
                AS stop_evidence
            FROM track_quality_runs WHERE $runWhere
            ''',
            runArgs,
          ))
            .single
        : const <String, Object?>{};
    final (gapWhere, gapArgs) = hasGaps
        ? await rowsOf(database, 'track_continuity_gaps', trackId)
        : ('', const <Object?>[]);
    final visibleGaps = hasGaps
        ? (await database.rawQuery(
            '''
            SELECT COUNT(*) AS count FROM track_continuity_gaps
            WHERE $gapWhere AND visible = 1
            ''',
            gapArgs,
          ))
            .single['count']
        : 0;
    final existing = await _summaryRow(database, trackId);
    final values = <String, Object?>{
      'summary_version': summaryVersion,
      'first_fix_at': fixes['first_fix_at'],
      'last_fix_at': fixes['last_fix_at'],
      'recording_ms': recording,
      'moving_ms': math.max(0, recording - stopped),
      'stopped_ms': stopped,
      'stop_count': stopCount,
      'max_speed_mps': (fastest as num?)?.toDouble(),
      'quality_event_count': (runs['quality_events'] as num?)?.toInt() ?? 0,
      'stop_evidence_run_count': (runs['stop_evidence'] as num?)?.toInt() ?? 0,
      'visible_gap_count': (visibleGaps as num?)?.toInt() ?? 0,
      'step_count': hasSegments ? await _steps(database, trackId) : null,
      if (tables.contains('track_step_generations'))
        'step_count_stopped_at': await _stepsStoppedAt(database, trackId),
      'updated_at': _timestamp(now),
    };
    if (existing == null) {
      await database.insert('track_summaries', <String, Object?>{
        'track_id': trackId,
        ...values,
        'stops_source': recordsStops || stopCount > 0
            ? TrackStopSource.recorded
            : TrackStopSource.pending,
      });
    } else {
      await database.update(
        'track_summaries',
        values,
        where: 'track_id = ?',
        whereArgs: <Object?>[trackId],
      );
    }
  }

  /// Totals of [tripId]'s legs, stored in `trip_summaries` and returned.
  static Future<TripSummary?> refreshTrip(
    DatabaseExecutor database,
    String tripId, {
    required DateTime now,
  }) async {
    final trips = await database.query(
      'trips',
      columns: <String>[
        'started_at',
        'ended_at',
        'measured_distance_m',
        'accepted_point_count',
        'rejected_point_count',
      ],
      where: 'id = ?',
      whereArgs: <Object?>[tripId],
      limit: 1,
    );
    if (trips.isEmpty) return null;
    // Whole rows per leg: databases upgraded from early schemas lack some
    // track columns.
    final legIds = await database.query(
      'trip_legs',
      columns: <String>['track_id'],
      where: 'trip_id = ?',
      whereArgs: <Object?>[tripId],
      orderBy: 'leg_number ASC',
    );
    final legs = <Map<String, Object?>>[];
    for (final leg in legIds) {
      final trackId = leg['track_id']! as String;
      final tracks = await database.query(
        'tracks',
        where: 'id = ?',
        whereArgs: <Object?>[trackId],
        limit: 1,
      );
      if (tracks.isEmpty) continue;
      legs.add(<String, Object?>{
        ...?await _summaryRow(database, trackId),
        'segment_count': tracks.single['segment_count'],
        'accepted_point_count': tracks.single['accepted_point_count'],
        'total_distance_m': tracks.single['total_distance_m'],
      });
    }
    int sum(String key) => legs.fold(
          0,
          (total, row) => total + ((row[key] as num?)?.toInt() ?? 0),
        );
    DateTime? time(Object? value) =>
        value == null ? null : DateTime.parse(value as String).toUtc();
    DateTime? firstFix;
    DateTime? lastFix;
    double? fastest;
    int? steps;
    double? cleaned = 0;
    var corrected = 0.0;
    var anyReviewed = false;
    DateTime? stepsStoppedAt;
    for (final leg in legs) {
      final legStopped = time(leg['step_count_stopped_at']);
      if (legStopped != null &&
          (stepsStoppedAt == null || legStopped.isBefore(stepsStoppedAt))) {
        stepsStoppedAt = legStopped;
      }
      final legCorrected = leg['review_run_id'] == null
          ? null
          : (leg['corrected_distance_m'] as num?)?.toDouble();
      if (legCorrected != null) anyReviewed = true;
      corrected +=
          legCorrected ?? (leg['total_distance_m'] as num?)?.toDouble() ?? 0;
      final first = time(leg['first_fix_at']);
      final last = time(leg['last_fix_at']);
      if (first != null && (firstFix == null || first.isBefore(firstFix))) {
        firstFix = first;
      }
      if (last != null && (lastFix == null || last.isAfter(lastFix))) {
        lastFix = last;
      }
      final speed = (leg['max_speed_mps'] as num?)?.toDouble();
      if (speed != null && (fastest == null || speed > fastest)) {
        fastest = speed;
      }
      final legSteps = (leg['step_count'] as num?)?.toInt();
      if (legSteps != null) steps = (steps ?? 0) + legSteps;
      final legCleaned = (leg['cleaned_distance_m'] as num?)?.toDouble();
      final hasFixes =
          ((leg['accepted_point_count'] as num?)?.toInt() ?? 0) > 0;
      if (cleaned != null) {
        if (legCleaned != null) {
          cleaned += legCleaned;
        } else if (hasFixes) {
          cleaned = null;
        }
      }
    }
    final trip = trips.single;
    final tripSummaryColumns = await _columnNames(database, 'trip_summaries');
    final summary = TripSummary(
      tripId: tripId,
      startedAt: DateTime.parse(trip['started_at']! as String).toUtc(),
      endedAt: time(trip['ended_at']),
      legCount: legs.length,
      distanceMeters: (trip['measured_distance_m'] as num?)?.toDouble() ?? 0,
      acceptedPointCount: (trip['accepted_point_count'] as num?)?.toInt() ?? 0,
      rejectedPointCount: (trip['rejected_point_count'] as num?)?.toInt() ?? 0,
      segmentCount: sum('segment_count'),
      firstFixAt: firstFix,
      lastFixAt: lastFix,
      recording: Duration(milliseconds: sum('recording_ms')),
      moving: Duration(milliseconds: sum('moving_ms')),
      stopped: Duration(milliseconds: sum('stopped_ms')),
      stopCount: sum('stop_count'),
      maxSpeedMetersPerSecond: fastest,
      stepCount: steps,
      qualityEventCount: sum('quality_event_count'),
      visibleGapCount: sum('visible_gap_count'),
      stopEvidenceRunCount: sum('stop_evidence_run_count'),
      cleanedDistanceMeters: legs.isEmpty ? null : cleaned,
      correctedDistanceMeters: anyReviewed ? corrected : null,
      stepCountStoppedAt: stepsStoppedAt,
      updatedAt: now,
    );
    await database.insert(
      'trip_summaries',
      <String, Object?>{
        'trip_id': tripId,
        'summary_version': summaryVersion,
        'leg_count': summary.legCount,
        'segment_count': summary.segmentCount,
        'first_fix_at': firstFix == null ? null : _timestamp(firstFix),
        'last_fix_at': lastFix == null ? null : _timestamp(lastFix),
        'recording_ms': summary.recording.inMilliseconds,
        'moving_ms': summary.moving.inMilliseconds,
        'stopped_ms': summary.stopped.inMilliseconds,
        'stop_count': summary.stopCount,
        'max_speed_mps': fastest,
        'quality_event_count': summary.qualityEventCount,
        'visible_gap_count': summary.visibleGapCount,
        'stop_evidence_run_count': summary.stopEvidenceRunCount,
        'step_count': steps,
        'cleaned_distance_m': summary.cleanedDistanceMeters,
        if (tripSummaryColumns.contains('corrected_distance_m'))
          'corrected_distance_m': summary.correctedDistanceMeters,
        if (tripSummaryColumns.contains('step_count_stopped_at'))
          'step_count_stopped_at':
              stepsStoppedAt == null ? null : _timestamp(stepsStoppedAt),
        'updated_at': _timestamp(now),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return summary;
  }

  /// The Trip [trackId] is a leg of, if any.
  static Future<String?> tripIdOf(
    DatabaseExecutor database,
    String trackId,
  ) async {
    if (!(await _tableNames(database)).contains('trip_legs')) return null;
    final rows = await database.query(
      'trip_legs',
      columns: <String>['trip_id'],
      where: 'track_id = ?',
      whereArgs: <Object?>[trackId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['trip_id'] as String?;
  }

  /// [trackId]'s stored summary with its route's stored totals.
  static Future<RouteSummary?> readTrack(
    DatabaseExecutor database,
    String trackId,
  ) async {
    final summaries = await database.query(
      'track_summaries',
      where: 'track_id = ?',
      whereArgs: <Object?>[trackId],
      limit: 1,
    );
    if (summaries.isEmpty) return null;
    final tracks = await database.query(
      'tracks',
      where: 'id = ?',
      whereArgs: <Object?>[trackId],
      limit: 1,
    );
    if (tracks.isEmpty) return null;
    final track = tracks.single;
    final row = summaries.single;
    DateTime? time(Object? value) =>
        value == null ? null : DateTime.parse(value as String).toUtc();
    int count(String key) => (row[key] as num?)?.toInt() ?? 0;
    int trackCount(String key) => (track[key] as num?)?.toInt() ?? 0;
    return RouteSummary(
      trackId: trackId,
      startedAt: DateTime.parse(track['started_at']! as String).toUtc(),
      endedAt: time(track['ended_at']),
      firstFixAt: time(row['first_fix_at']),
      lastFixAt: time(row['last_fix_at']),
      distanceMeters: (track['total_distance_m'] as num?)?.toDouble() ?? 0,
      cleanedDistanceMeters: (row['cleaned_distance_m'] as num?)?.toDouble(),
      cleanedRunId: row['cleaned_run_id'] as String?,
      correctedDistanceMeters: row['review_run_id'] == null
          ? null
          : (row['corrected_distance_m'] as num?)?.toDouble(),
      stepCountStoppedAt: time(row['step_count_stopped_at']),
      acceptedPointCount: trackCount('accepted_point_count'),
      rejectedPointCount: trackCount('rejected_point_count'),
      segmentCount: trackCount('segment_count'),
      recording: Duration(milliseconds: count('recording_ms')),
      moving: Duration(milliseconds: count('moving_ms')),
      stopped: Duration(milliseconds: count('stopped_ms')),
      stopCount: count('stop_count'),
      maxSpeedMetersPerSecond: (row['max_speed_mps'] as num?)?.toDouble(),
      stepCount: (row['step_count'] as num?)?.toInt(),
      qualityEventCount: count('quality_event_count'),
      visibleGapCount: count('visible_gap_count'),
      stopEvidenceRunCount: count('stop_evidence_run_count'),
      stopsSource: row['stops_source'] as String? ?? TrackStopSource.pending,
      updatedAt: DateTime.parse(row['updated_at']! as String).toUtc(),
    );
  }

  /// Whether [runRows], the rejected points of a quality run, are all stop
  /// evidence: held at a stop, or rejected while a stay was current.
  static bool isStopEvidence(Iterable<Map<String, Object?>> runRows) =>
      runRows.every(
        (row) =>
            _stopHoldReasons.contains(row['rejection_reason']) ||
            ((row['quality_flags'] as num?)?.toInt() ?? 0) &
                    TrackPointQualityFlag.duringStop !=
                0,
      );

  static const _stopHoldReasons = <String>{
    FixQualityIssue.stationaryHold,
    FixQualityIssue.stationaryOutlier,
  };

  /// The review whose rows [trackId]'s totals and stops read, if one is
  /// current (route database schema 18).
  static Future<String?> currentReviewRunId(
    DatabaseExecutor database,
    String trackId,
  ) async {
    if (!(await _columnNames(database, 'track_summaries'))
        .contains('review_run_id')) {
      return null;
    }
    final rows = await database.query(
      'track_summaries',
      columns: <String>['review_run_id'],
      where: 'track_id = ?',
      whereArgs: <Object?>[trackId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['review_run_id'] as String?;
  }

  /// SQL selecting the rows of the reviewed table aliased [alias] that count
  /// for their track: those of its current review, or the rows recorded live
  /// when it has none. Needs schema 18.
  static String currentRowsSql(String alias) =>
      "COALESCE($alias.review_run_id, '') = COALESCE(("
      'SELECT summary.review_run_id FROM track_summaries summary '
      "WHERE summary.track_id = $alias.track_id), '')";

  /// The condition selecting [trackId]'s rows of [table] that count: those of
  /// its current review, or the rows recorded live.
  static Future<(String, List<Object?>)> rowsOf(
    DatabaseExecutor database,
    String table,
    String trackId,
  ) async {
    if (!(await _columnNames(database, table)).contains('review_run_id')) {
      return ('track_id = ?', <Object?>[trackId]);
    }
    final runId = await currentReviewRunId(database, trackId);
    return runId == null
        ? ('track_id = ? AND review_run_id IS NULL', <Object?>[trackId])
        : ('track_id = ? AND review_run_id = ?', <Object?>[trackId, runId]);
  }

  static Future<Map<String, Object?>?> _summaryRow(
    DatabaseExecutor database,
    String trackId,
  ) async {
    final rows = await database.query(
      'track_summaries',
      where: 'track_id = ?',
      whereArgs: <Object?>[trackId],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single;
  }

  /// Time inside [trackId]'s segments; the open segment ends at [openEnd].
  static Future<int> _recordingMs(
    DatabaseExecutor database,
    String trackId, {
    required DateTime? openEnd,
  }) async {
    final segments = await database.query(
      'track_segments',
      where: 'track_id = ?',
      whereArgs: <Object?>[trackId],
    );
    var total = 0;
    for (final segment in segments) {
      final started = segment['started_at'];
      if (started == null) continue;
      final start = DateTime.parse(started as String).toUtc();
      final ended = segment['ended_at'] == null
          ? openEnd
          : DateTime.parse(segment['ended_at']! as String).toUtc();
      if (ended == null) continue;
      final duration = ended.difference(start).inMilliseconds;
      if (duration > 0) total += duration;
    }
    return total;
  }

  static Future<(int, int)> _stops(
    DatabaseExecutor database,
    String trackId,
  ) async {
    final (where, args) = await rowsOf(database, 'track_stops', trackId);
    final rows = await database.query(
      'track_stops',
      columns: <String>['started_at', 'last_seen_at', 'ended_at'],
      where: where,
      whereArgs: args,
    );
    var stopped = 0;
    for (final row in rows) {
      final start = DateTime.parse(row['started_at']! as String);
      final end = DateTime.parse(
        (row['ended_at'] ?? row['last_seen_at'])! as String,
      );
      final duration = end.difference(start).inMilliseconds;
      if (duration > 0) stopped += duration;
    }
    return (rows.length, stopped);
  }

  /// The earliest time a capture generation of [trackId] stopped counting
  /// while the device walked, from its live or current review rows.
  static Future<String?> _stepsStoppedAt(
    DatabaseExecutor database,
    String trackId,
  ) async {
    final (where, args) =
        await rowsOf(database, 'track_step_generations', trackId);
    final row = (await database.rawQuery(
      'SELECT MIN(stopped_at) AS stopped_at FROM track_step_generations '
      'WHERE $where AND stopped_at IS NOT NULL',
      args,
    ))
        .single;
    return row['stopped_at'] as String?;
  }

  static Future<int?> _steps(DatabaseExecutor database, String trackId) async {
    final row = (await database.rawQuery(
      '''
      SELECT SUM(step_count) AS steps, COUNT(step_count) AS counted
      FROM track_segments WHERE track_id = ?
      ''',
      <Object?>[trackId],
    ))
        .single;
    return ((row['counted'] as num?)?.toInt() ?? 0) == 0
        ? null
        : (row['steps'] as num?)?.toInt();
  }

  /// Fills `stop_evidence` for runs stored before schema 17.
  static Future<void> _fillRunDecisions(
    DatabaseExecutor database,
    String trackId,
  ) async {
    final pending = (await database.rawQuery(
      'SELECT COUNT(*) AS count FROM track_quality_runs '
      'WHERE track_id = ? AND stop_evidence IS NULL',
      <Object?>[trackId],
    ))
        .single['count'];
    if (((pending as num?)?.toInt() ?? 0) == 0) return;
    await database.rawUpdate(
      '''
        UPDATE track_quality_runs
        SET stop_evidence = CASE WHEN NOT EXISTS (
          SELECT 1 FROM track_points AS point
          WHERE point.track_id = track_quality_runs.track_id
            AND point.sequence BETWEEN track_quality_runs.first_raw_sequence
              AND track_quality_runs.last_raw_sequence
            AND point.accepted = 0
            AND COALESCE(point.rejection_reason, '') NOT IN (?, ?)
            AND (COALESCE(point.quality_flags, 0) & ?) = 0
        ) THEN 1 ELSE 0 END
        WHERE track_id = ? AND stop_evidence IS NULL
        ''',
      <Object?>[
        FixQualityIssue.stationaryHold,
        FixQualityIssue.stationaryOutlier,
        TrackPointQualityFlag.duringStop,
        trackId,
      ],
    );
  }

  static Future<Set<String>> _tableNames(DatabaseExecutor database) async =>
      (await database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ))
          .map((row) => row['name']! as String)
          .toSet();

  static Future<Set<String>> _columnNames(
    DatabaseExecutor database,
    String table,
  ) async =>
      (await database.rawQuery('PRAGMA table_info($table)'))
          .map((row) => row['name']! as String)
          .toSet();

  /// Fills `visible` for gaps stored before schema 17.
  static Future<void> _fillGapDecisions(
    DatabaseExecutor database,
    String trackId,
  ) async {
    final rows = await database.query(
      'track_continuity_gaps',
      columns: <String>[
        'id',
        'cause',
        'provider_gap_ms',
        'straight_line_distance_m',
      ],
      where: 'track_id = ? AND visible IS NULL',
      whereArgs: <Object?>[trackId],
    );
    for (final row in rows) {
      final cause = TrackingGapCause.values.asNameMap()[row['cause']] ??
          TrackingGapCause.unknown;
      final visible = TrackingContinuityGap.visibleFor(
        cause: cause,
        providerGap: row['provider_gap_ms'] == null
            ? null
            : Duration(milliseconds: (row['provider_gap_ms']! as num).toInt()),
        straightLineDistanceMeters:
            (row['straight_line_distance_m'] as num?)?.toDouble(),
      );
      await database.update(
        'track_continuity_gaps',
        <String, Object?>{'visible': visible ? 1 : 0},
        where: 'id = ?',
        whereArgs: <Object?>[row['id']],
      );
    }
  }

  static String _timestamp(DateTime value) => value.toUtc().toIso8601String();
}
