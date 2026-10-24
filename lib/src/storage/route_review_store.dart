import 'package:sqflite/sqflite.dart';

/// Route database schema 18: evidence quality policy 5 decides from, and the
/// review layer that applies the current rules to routes recorded under older
/// ones without touching what they recorded.
///
/// Every addition is idempotent and ensured on every open, on fresh creation
/// and in the schema 18 upgrade, so a database keeps one shape whichever way
/// it got here.
abstract final class RouteReviewStore {
  /// Ensures the schema 18 columns, tables and indexes.
  static Future<void> ensureSchema(DatabaseExecutor database) async {
    // The attached reading's own time and the readings journaled with a fix:
    // a fix decided again later is judged on the same evidence.
    await _addColumn(database, 'track_points', 'activity_recorded_at', 'TEXT');
    await _addColumn(
      database,
      'track_points',
      'activity_readings_json',
      'TEXT',
    );
    // Rows a review derived, beside the rows recorded live (NULL). No foreign
    // key: some upgrade paths have no derived-geometry table yet, and a
    // review's rows are deleted with it explicitly ([deleteReviewRows]).
    for (final table in reviewedTables.take(3)) {
      await _addColumn(database, table, 'review_run_id', 'TEXT');
      if (await _hasTable(database, table)) {
        await database.execute(
          'CREATE INDEX IF NOT EXISTS idx_${table}_review '
          'ON $table(review_run_id)',
        );
      }
    }
    if (await _hasTable(database, 'tracks')) {
      await database.execute('''
        CREATE TABLE IF NOT EXISTS track_step_generations (
          id TEXT PRIMARY KEY,
          track_id TEXT NOT NULL,
          segment_id TEXT,
          capture_generation_id TEXT NOT NULL,
          step_count INTEGER,
          last_rise_at TEXT,
          counted_through TEXT,
          stopped_at TEXT,
          coverage_state TEXT,
          decided_by TEXT,
          review_run_id TEXT,
          updated_at TEXT NOT NULL,
          FOREIGN KEY(track_id) REFERENCES tracks(id) ON DELETE CASCADE,
          CHECK(step_count IS NULL OR step_count >= 0)
        )
      ''');
      await database.execute('''
        CREATE UNIQUE INDEX IF NOT EXISTS idx_track_step_generations_live
        ON track_step_generations(track_id, capture_generation_id)
        WHERE review_run_id IS NULL
      ''');
      await database.execute('''
        CREATE INDEX IF NOT EXISTS idx_track_step_generations_review
        ON track_step_generations(review_run_id)
      ''');
    }
  }

  /// Schema 18 upgrade: a route recording across it keeps counting its newest
  /// capture generation once, because the generation and count its schema 17
  /// summary held become that generation's live row. Its next count adds to
  /// the route's current segment.
  static Future<void> seedLiveStepGenerations(DatabaseExecutor database) async {
    if (!await _hasTable(database, 'track_summaries') ||
        !await _hasTable(database, 'track_step_generations')) {
      return;
    }
    await database.execute('''
      INSERT OR IGNORE INTO track_step_generations (
        id, track_id, segment_id, capture_generation_id, step_count,
        decided_by, updated_at
      )
      SELECT 'live:' || summary.track_id || ':' || summary.step_generation,
        summary.track_id, NULL, summary.step_generation,
        summary.step_last_count, 'schema_18_upgrade', summary.updated_at
      FROM track_summaries summary
      WHERE summary.step_generation IS NOT NULL
        AND summary.step_last_count IS NOT NULL
    ''');
  }

  /// Tables whose rows a review derives beside the live ones.
  static const reviewedTables = <String>[
    'track_stops',
    'track_continuity_gaps',
    'track_quality_runs',
    'track_step_generations',
  ];

  /// Deletes every row review [runId] derived.
  static Future<void> deleteReviewRows(
    DatabaseExecutor database,
    String runId,
  ) async {
    for (final table in reviewedTables) {
      await database.delete(
        table,
        where: 'review_run_id = ?',
        whereArgs: <Object?>[runId],
      );
    }
    await database.rawUpdate(
      '''
      UPDATE track_summaries SET review_run_id = NULL, review_version = NULL
      WHERE review_run_id = ?
      ''',
      <Object?>[runId],
    );
  }

  static Future<bool> _hasTable(DatabaseExecutor database, String table) async {
    final rows = await database.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
      <Object?>[table],
    );
    return rows.isNotEmpty;
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
