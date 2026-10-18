import 'dart:io';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/src/storage/sqlite_track_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('FIX-18 caps diagnostic health events but keeps gap evidence', () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('fbl-health-');
    final databasePath = '${directory.path}/route.sqlite';
    var now = DateTime.utc(2026, 7, 20, 8);
    final repository = SqliteTrackRepository(
      path: databasePath,
      databaseFactoryOverride: databaseFactoryFfi,
      singleInstance: false,
      clock: () => now = now.add(const Duration(seconds: 1)),
    );
    await repository.initialize();
    for (final trackId in <String>['busy', 'quiet']) {
      await repository.createTrack(
        userId: 'user',
        organizationId: 'org',
        config: const TrackingConfig(),
        requestedTrackId: trackId,
      );
      await repository.markTrackActive(trackId);
      await repository.completeTrack(trackId, reason: 'done');
    }

    const evidenceTypes = <String>[
      'native_tracker_interrupted',
      'native_tracker_failed',
      'previous_session_interrupted',
      'termination_recovery_started_gap_possible',
      'authorization_changed',
    ];
    for (final type in evidenceTypes) {
      await repository.recordHealthEvent(trackId: 'busy', type: type);
    }
    for (var index = 0; index < 700; index++) {
      await repository.recordHealthEvent(
        trackId: 'busy',
        type: 'continuity_gap_recorded',
        details: <String, Object?>{'index': index},
      );
    }
    for (var index = 0; index < 10; index++) {
      await repository.recordHealthEvent(
        trackId: 'quiet',
        type: 'upload_failed',
      );
    }
    await repository.close();

    final raw = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    Future<int> count(String where, List<Object?> arguments) async =>
        (await raw.rawQuery(
          'SELECT COUNT(*) AS n FROM tracking_health_events WHERE $where',
          arguments,
        ))
            .single['n']! as int;
    final diagnostics = await count(
      "track_id = ? AND type = 'continuity_gap_recorded'",
      <Object?>['busy'],
    );
    final newest = await raw.rawQuery(
      'SELECT details_json FROM tracking_health_events '
      "WHERE track_id = 'busy' AND type = 'continuity_gap_recorded' "
      'ORDER BY occurred_at DESC LIMIT 1',
    );

    expect(diagnostics, inInclusiveRange(500, 550));
    expect(newest.single['details_json'], '{"index":699}');
    expect(
      await count(
        'track_id = ? AND type IN (?, ?, ?, ?, ?)',
        <Object?>['busy', ...evidenceTypes],
      ),
      evidenceTypes.length,
    );
    expect(await count('track_id = ?', <Object?>['quiet']), 10);
    await raw.close();
    await directory.delete(recursive: true);
  });
}
