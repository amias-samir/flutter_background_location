import 'dart:io';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/src/storage/route_summary_store.dart';
import 'package:flutter_background_location_tracker/src/storage/sqlite_track_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// FLT-23: a finished route's summary written under an older definition is
// refreshed after the open (or first on read), not before it returns; a
// route that can still record is refreshed before.

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory directory;
  late String path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('fbl-summary-');
    path = '${directory.path}/route.sqlite';
  });
  tearDown(() => directory.delete(recursive: true));

  SqliteTrackRepository open() => SqliteTrackRepository(
        path: path,
        databaseFactoryOverride: databaseFactoryFfi,
        singleInstance: false,
      );

  Future<Database> raw() => databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(singleInstance: false),
      );

  Future<void> record(SqliteTrackRepository repository, String trackId,
      {required bool finish}) async {
    final created = await repository.createTrack(
      userId: 'user-1',
      organizationId: 'org-1',
      config: const TrackingConfig(),
      requestedTrackId: trackId,
    );
    await repository.markTrackActive(created);
    if (finish) await repository.completeTrack(created, reason: 'finished');
  }

  /// Marks every summary as written under an older definition with a wrong
  /// stop count, as a build before a summary-version bump left it.
  Future<void> makeStale() async {
    final database = await raw();
    await database.rawUpdate(
      'UPDATE track_summaries SET summary_version = ?, stop_count = 99',
      <Object?>[RouteSummaryStore.summaryVersion - 1],
    );
    await database.close();
  }

  Future<Map<String, Object?>> row(String trackId) async {
    final database = await raw();
    final rows = await database.query(
      'track_summaries',
      where: 'track_id = ?',
      whereArgs: <Object?>[trackId],
    );
    await database.close();
    return rows.single;
  }

  test('a finished route is refreshed after the open; an active one before',
      () async {
    final first = open();
    await first.initialize();
    await record(first, 'finished', finish: true);
    await record(first, 'recording', finish: false);
    await first.close();
    await makeStale();

    final reopened = open();
    await reopened.initialize();
    expect(
      (await row('recording'))['summary_version'],
      RouteSummaryStore.summaryVersion,
      reason: 'a route that can still record is current before the open ends',
    );
    // close() waits for the background pass.
    await reopened.close();
    final finished = await row('finished');
    expect(finished['summary_version'], RouteSummaryStore.summaryVersion);
    expect(finished['stop_count'], 0);
  });

  test('reading a stale finished summary refreshes it first', () async {
    final first = open();
    await first.initialize();
    await record(first, 'finished', finish: true);
    await first.close();
    await makeStale();

    final reopened = open();
    await reopened.initialize();
    final summary = await reopened.routeSummary('finished');
    expect(summary!.stopCount, 0, reason: 'never the stale 99');
    await reopened.close();
  });
}
