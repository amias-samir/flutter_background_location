import 'package:sqflite/sqflite.dart';

import '../domain/route_recording_detail.dart';
import '../domain/route_summary.dart';
import '../domain/track.dart';

/// Route database schema 19: the detail each route records
/// ([RouteRecordingDetail]) and the compaction of clean routes once they end.
///
/// Every addition is idempotent and ensured on every open, on fresh creation
/// and in the schema 19 upgrade, so a database keeps one shape whichever way
/// it got here.
abstract final class RouteCompactionStore {
  /// Ensures the schema 19 columns. Routes recorded before them are full.
  static Future<void> ensureSchema(DatabaseExecutor database) async {
    await _addColumn(
      database,
      'tracks',
      'recording_detail',
      "TEXT NOT NULL DEFAULT 'full'",
    );
    await _addColumn(database, 'tracks', 'compacted_at', 'TEXT');
  }

  /// Completed or failed clean routes not yet compacted, oldest first; with
  /// [userId] and [organizationId], only that owner's. A route whose stops
  /// are still to be derived, or with an export being written, waits.
  static Future<List<String>> tracksAwaitingCompaction(
    DatabaseExecutor database, {
    required int limit,
    String? userId,
    String? organizationId,
  }) async {
    final owned = userId != null && organizationId != null;
    final rows = await database.rawQuery(
      '''
      SELECT track.id FROM tracks AS track
      LEFT JOIN track_summaries AS summary ON summary.track_id = track.id
      WHERE track.recording_detail = ? AND track.compacted_at IS NULL
        AND track.status IN (?, ?)
        AND (summary.stops_source IS NULL OR summary.stops_source != ?)
        AND NOT EXISTS (
          SELECT 1 FROM managed_exports AS export
          WHERE export.track_id = track.id AND export.state = 'pending'
        )
        ${owned ? 'AND track.user_id = ? AND track.organization_id = ?' : ''}
      ORDER BY track.started_at ASC
      LIMIT ?
      ''',
      <Object?>[
        RouteRecordingDetail.clean.name,
        TrackStatus.completed.name,
        TrackStatus.failed.name,
        TrackStopSource.pending,
        if (owned) ...<Object?>[userId, organizationId],
        limit,
      ],
    );
    return rows.map((row) => row['id']! as String).toList(growable: false);
  }

  /// Removes what a clean route [trackId] no longer needs once it has ended:
  /// the activity readings journaled with its fixes (only a restart of a live
  /// route decides from them), its motion evidence and its diagnostic health
  /// events, keeping [keptHealthEventTypes]. Its points, their acceptance,
  /// distance, stops, steps, summaries and uploads stay. Returns false
  /// without changes when the route is not an ended, uncompacted clean route.
  static Future<bool> compact(
    Transaction transaction,
    String trackId, {
    required List<String> keptHealthEventTypes,
    required String compactedAt,
  }) async {
    final claimed = await transaction.rawUpdate(
      '''
      UPDATE tracks SET compacted_at = ?
      WHERE id = ? AND recording_detail = ? AND compacted_at IS NULL
        AND status IN (?, ?)
      ''',
      <Object?>[
        compactedAt,
        trackId,
        RouteRecordingDetail.clean.name,
        TrackStatus.completed.name,
        TrackStatus.failed.name,
      ],
    );
    if (claimed != 1) return false;
    await transaction.rawUpdate(
      '''
      UPDATE track_points SET activity_readings_json = NULL
      WHERE track_id = ? AND activity_readings_json IS NOT NULL
      ''',
      <Object?>[trackId],
    );
    await transaction.delete(
      'track_motion_evidence',
      where: 'track_id = ?',
      whereArgs: <Object?>[trackId],
    );
    await transaction.rawDelete(
      '''
      DELETE FROM tracking_health_events
      WHERE track_id = ? AND type NOT IN (
        ${List<String>.filled(keptHealthEventTypes.length, '?').join(', ')}
      )
      ''',
      <Object?>[trackId, ...keptHealthEventTypes],
    );
    return true;
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
}
