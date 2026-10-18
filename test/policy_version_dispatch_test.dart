import 'dart:io';

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/src/storage/sqlite_track_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_support.dart';

void main() {
  group('FIX-30 version resolution', () {
    test('applies supported versions as recorded', () {
      for (final version in TrackingPolicyVersions.supportedQualityPolicies) {
        expect(TrackingPolicyVersions.resolveQualityPolicy(version), version);
      }
      for (final version
          in TrackingPolicyVersions.supportedContinuityPolicies) {
        expect(
          TrackingPolicyVersions.resolveContinuityPolicy(version),
          version,
        );
      }
    });

    test('falls back to the newest supported version for unknown versions', () {
      expect(
        TrackingPolicyVersions.resolveQualityPolicy(7),
        TrackingPolicyVersions.supportedQualityPolicies.last,
      );
      // Continuity version 1 was retired by the schema-14 distance repair.
      expect(
        TrackingPolicyVersions.resolveContinuityPolicy(1),
        TrackingPolicyVersions.supportedContinuityPolicies.last,
      );
      expect(
        TrackingPolicyVersions.resolveContinuityPolicy(9),
        TrackingPolicyVersions.supportedContinuityPolicies.last,
      );
    });

    test('current and legacy versions stay supported', () {
      expect(
        TrackingPolicyVersions.supportedQualityPolicies,
        contains(TrackingPolicyVersions.qualityPolicy),
      );
      expect(
        TrackingPolicyVersions.supportedContinuityPolicies,
        contains(TrackingPolicyVersions.continuityPolicy),
      );
      // Epochs written before schema 15 must stay replayable forever.
      expect(
        TrackingPolicyVersions.supportedContinuityPolicies,
        contains(TrackingPolicyVersions.legacyContinuityPolicy),
      );
    });
  });

  test('quality decisions report the version actually applied', () {
    final sample = LocationSample(
      latitude: 0.001,
      longitude: 0.002,
      capturedAt: DateTime.utc(2026, 7, 20, 8),
      horizontalAccuracy: 5,
      provider: 'test',
    );
    final now = DateTime.utc(2026, 7, 20, 8, 0, 1);

    final current = const FixQualityPolicy(TrackingConfig()).evaluate(
      sample: sample,
      previous: null,
      now: now,
    );
    final unknown = const FixQualityPolicy(TrackingConfig(), version: 7)
        .evaluate(sample: sample, previous: null, now: now);

    expect(current.policyVersion, TrackingPolicyVersions.qualityPolicy);
    expect(unknown.policyVersion, TrackingPolicyVersions.qualityPolicy);
    expect(unknown.acceptedForGeometry, current.acceptedForGeometry);
    expect(unknown.qualityFlags, current.qualityFlags);
    expect(unknown.issues, current.issues);
  });

  test('continuity decisions report the version actually applied', () {
    const evidence = TrackingContinuityEvidence(
      currentAcceptedForGeometry: true,
      expectedTrackId: 'track',
      currentTrackId: 'track',
      previousCaptureGenerationId: 'generation',
      currentCaptureGenerationId: 'generation',
      nativeLifecycle: TrackerLifecycle.tracking,
      samplingProfile: SamplingProfile.stationary,
      serviceHealthy: true,
      permissionAndServiceAvailable: true,
    );

    final current = const TrackingContinuityClassifier().classify(evidence);
    final unknown =
        const TrackingContinuityClassifier(policyVersion: 9).classify(evidence);

    expect(current.policyVersion, TrackingPolicyVersions.continuityPolicy);
    expect(unknown.policyVersion, TrackingPolicyVersions.continuityPolicy);
    expect(unknown.cause, current.cause);
    expect(unknown.treatment, current.treatment);
  });

  group('FIX-03 continuity across runtime configuration updates', () {
    TrackingContinuityEvidence boundary({
      String previousDomain = 'boot-1',
      bool? permissionAndServiceAvailable = true,
      TrackerLifecycle lifecycle = TrackerLifecycle.tracking,
      bool runtimeConfigurationBoundary = true,
    }) =>
        TrackingContinuityEvidence(
          currentAcceptedForGeometry: true,
          expectedTrackId: 'track',
          currentTrackId: 'track',
          previousCaptureGenerationId: 'generation-1',
          currentCaptureGenerationId: 'generation-2',
          previousMonotonicDomainId: previousDomain,
          currentMonotonicDomainId: 'boot-1',
          nativeLifecycle: lifecycle,
          serviceHealthy: true,
          permissionAndServiceAvailable: permissionAndServiceAvailable,
          runtimeConfigurationBoundary: runtimeConfigurationBoundary,
        );

    test('version 3 keeps the segment across the planned provider restart', () {
      final decision =
          const TrackingContinuityClassifier(policyVersion: 3).classify(
        boundary(),
      );

      expect(decision.treatment, TrackingGapTreatment.retainCurrentSegment);
      expect(decision.excludeConnectorFromMeasuredDistance, isFalse);
      expect(decision.policyVersion, 3);
    });

    test('version 2 epochs keep their recorded split behavior', () {
      final decision =
          const TrackingContinuityClassifier(policyVersion: 2).classify(
        boundary(),
      );

      expect(decision.treatment, TrackingGapTreatment.startNewSegment);
      expect(decision.cause, TrackingGapCause.nativeInterruption);
      expect(decision.policyVersion, 2);
    });

    test('version 3 still splits when other evidence explains the gap', () {
      const classifier = TrackingContinuityClassifier(policyVersion: 3);

      expect(
        classifier.classify(boundary(previousDomain: 'boot-0')).cause,
        TrackingGapCause.processRestart,
      );
      expect(
        classifier
            .classify(boundary(permissionAndServiceAvailable: false))
            .cause,
        TrackingGapCause.permissionOrServiceLoss,
      );
      expect(
        classifier.classify(boundary(lifecycle: TrackerLifecycle.paused)).cause,
        TrackingGapCause.explicitPause,
      );
      expect(
        classifier
            .classify(boundary(runtimeConfigurationBoundary: false))
            .treatment,
        TrackingGapTreatment.startNewSegment,
      );
    });
  });

  test('epochs without a recorded continuity version read as legacy', () {
    final row = <String, Object?>{
      'id': 'epoch',
      'track_id': 'track',
      'epoch_number': 1,
      'resolved_configuration_json': const TrackingConfig().toJson(),
      'preset_definition_version': 4,
      'quality_policy_version': 1,
      'created_at': '2026-07-20T08:00:00.000Z',
      'activation_sequence': 1,
      'activated_at': '2026-07-20T08:00:00.000Z',
    };

    expect(
      TrackingConfigurationEpoch.fromDatabase(row).continuityPolicyVersion,
      TrackingPolicyVersions.legacyContinuityPolicy,
    );
    expect(
      TrackingConfigurationEpoch.fromDatabase(
        <String, Object?>{...row, 'continuity_policy_version': null},
      ).continuityPolicyVersion,
      TrackingPolicyVersions.legacyContinuityPolicy,
    );
    expect(
      TrackingConfigurationEpoch.fromDatabase(
        <String, Object?>{...row, 'continuity_policy_version': 2},
      ).continuityPolicyVersion,
      2,
    );
  });

  group('schema 15 epoch continuity version', () {
    late Directory directory;

    setUp(() async {
      sqfliteFfiInit();
      directory = await Directory.systemTemp.createTemp('fbl-v15-');
    });

    tearDown(() => directory.delete(recursive: true));

    SqliteTrackRepository open(String name) => SqliteTrackRepository(
          path: '${directory.path}/$name.sqlite',
          databaseFactoryOverride: databaseFactoryFfi,
          singleInstance: false,
        );

    Future<Database> openRaw(String name) => databaseFactoryFfi.openDatabase(
          '${directory.path}/$name.sqlite',
          options: OpenDatabaseOptions(singleInstance: false),
        );

    Future<List<Map<String, Object?>>> epochColumns(String name) async {
      final raw = await openRaw(name);
      final columns = await raw.rawQuery(
        'PRAGMA table_info(tracking_configuration_epochs)',
      );
      await raw.close();
      return columns;
    }

    test('new routes record the current continuity version', () async {
      final repository = open('fresh');
      await repository.initialize();
      final trackId = await repository.createTrack(
        userId: 'user',
        organizationId: 'org',
        config: const TrackingConfig(),
        requestedTrackId: 'fresh-track',
      );

      final epoch = await repository.activeConfigurationEpoch(trackId);

      expect(epoch!.epochNumber, 1);
      expect(epoch.qualityPolicyVersion, TrackingPolicyVersions.qualityPolicy);
      expect(
        epoch.continuityPolicyVersion,
        TrackingPolicyVersions.continuityPolicy,
      );
      await repository.close();
    });

    test('upgrading from schema 14 keeps existing epochs on the legacy version',
        () async {
      final original = open('upgraded');
      await original.initialize();
      final trackId = await original.createTrack(
        userId: 'user',
        organizationId: 'org',
        config: const TrackingConfig(),
        requestedTrackId: 'schema-14-track',
      );
      await original.close();
      final schema14 = await openRaw('upgraded');
      await schema14.execute(
        'ALTER TABLE tracking_configuration_epochs '
        'DROP COLUMN continuity_policy_version',
      );
      await schema14.setVersion(14);
      await schema14.close();

      final upgraded = open('upgraded');
      await upgraded.initialize();
      final epoch = await upgraded.activeConfigurationEpoch(trackId);
      await upgraded.close();

      expect(
        epoch!.continuityPolicyVersion,
        TrackingPolicyVersions.legacyContinuityPolicy,
      );
      final upgradedRaw = await openRaw('upgraded');
      expect(await upgradedRaw.getVersion(), 15);
      final stored = await upgradedRaw.query(
        'tracking_configuration_epochs',
        columns: <String>['continuity_policy_version'],
        where: 'track_id = ?',
        whereArgs: <Object?>[trackId],
      );
      expect(stored.single['continuity_policy_version'], isNull);
      // sqflite lowers the stored version without a downgrade callback, so
      // an older package can leave the column behind for the next upgrade.
      await upgradedRaw.setVersion(14);
      await upgradedRaw.close();

      final reopened = open('upgraded');
      await reopened.initialize();
      await reopened.close();

      final fresh = open('fresh-parity');
      await fresh.initialize();
      await fresh.close();
      expect(
          await epochColumns('upgraded'), await epochColumns('fresh-parity'));
    });
  });

  test('FIX-17 repairs only legacy routes, with stable legacy labels',
      () async {
    sqfliteFfiInit();
    final directory = await Directory.systemTemp.createTemp('fbl-repair-');
    final databasePath = '${directory.path}/route.sqlite';
    SqliteTrackRepository open() => SqliteTrackRepository(
          path: databasePath,
          databaseFactoryOverride: databaseFactoryFfi,
          singleInstance: false,
        );
    Future<Database> openRaw() => databaseFactoryFfi.openDatabase(
          databasePath,
          options: OpenDatabaseOptions(singleInstance: false),
        );

    final original = open();
    await original.initialize();
    for (final trackId in <String>['legacy', 'malformed', 'current']) {
      await original.createTrack(
        userId: 'user',
        organizationId: 'org',
        config: const TrackingConfig(),
        requestedTrackId: trackId,
      );
      await original.markTrackActive(trackId);
      await original.appendPoint(
        PointWriteRequest(
          trackId: trackId,
          sample: LocationSample(
            latitude: 0.001,
            longitude: 0.001,
            capturedAt: DateTime.utc(2026, 7, 20, 8),
            horizontalAccuracy: 5,
            provider: 'test',
            trackId: trackId,
          ),
          activity: const ActivitySnapshot.unknown(),
          motionState: MotionState.moving,
          accepted: true,
          qualityFlags: TrackPointQualityFlag.none,
        ),
      );
      await original.completeTrack(trackId, reason: 'done');
    }
    await original.close();

    // Recreate routes recorded before epochs existed.
    final raw = await openRaw();
    for (final trackId in <String>['legacy', 'malformed']) {
      await raw.rawUpdate(
        'UPDATE track_points SET configuration_epoch_id = NULL '
        'WHERE track_id = ?',
        <Object?>[trackId],
      );
      await raw.delete(
        'tracking_configuration_epochs',
        where: 'track_id = ?',
        whereArgs: <Object?>[trackId],
      );
    }
    await raw.rawUpdate(
      "UPDATE tracks SET configuration_json = '{not json' WHERE id = ?",
      <Object?>['malformed'],
    );
    final currentEpochBefore = (await raw.query(
      'tracking_configuration_epochs',
      where: 'track_id = ?',
      whereArgs: <Object?>['current'],
    ))
        .single;
    await raw.close();

    Future<Map<String, Object?>> state() async {
      final inspect = await openRaw();
      final epochs = await inspect.query(
        'tracking_configuration_epochs',
        orderBy: 'track_id',
      );
      final points = await inspect.query(
        'track_points',
        columns: <String>['track_id', 'configuration_epoch_id'],
        orderBy: 'track_id',
      );
      await inspect.close();
      return <String, Object?>{'epochs': epochs, 'points': points};
    }

    for (var run = 0; run < 2; run++) {
      final repaired = open();
      await repaired.initialize();
      await repaired.close();
    }
    final after = await state();
    final epochs = (after['epochs']! as List).cast<Map<String, Object?>>();
    final points = (after['points']! as List).cast<Map<String, Object?>>();

    final legacyEpoch =
        epochs.singleWhere((row) => row['track_id'] == 'legacy');
    expect(
      legacyEpoch['preset_definition_version'],
      TrackingPolicyVersions.legacyPresetDefinition,
    );
    expect(
      legacyEpoch['quality_policy_version'],
      TrackingPolicyVersions.legacyQualityPolicy,
    );
    expect(legacyEpoch['continuity_policy_version'], isNull);
    expect(epochs.where((row) => row['track_id'] == 'malformed'), isEmpty);
    expect(
      epochs.singleWhere((row) => row['track_id'] == 'current'),
      currentEpochBefore,
    );
    expect(
      points.singleWhere(
        (row) => row['track_id'] == 'legacy',
      )['configuration_epoch_id'],
      legacyEpoch['id'],
    );
    expect(
      points.singleWhere(
        (row) => row['track_id'] == 'malformed',
      )['configuration_epoch_id'],
      isNull,
    );
    await directory.delete(recursive: true);
  });

  test('the active epoch covers the next point across a runtime update',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    const owner = TrackingOwner(userId: 'user-1', organizationId: 'org-1');
    final trackId = await harness.createActiveTrack(trackId: 'active-epoch');

    final initial = await harness.repository.activeConfigurationEpoch(trackId);
    expect(initial!.epochNumber, 1);
    await harness.append(trackId: trackId, latitude: 0.001, longitude: 0.001);

    final operation = await harness.repository.beginConfigurationUpdate(
      owner: owner,
      trackId: trackId,
      config: const TrackingConfig(accuracy: TrackingAccuracy.medium),
    );
    await harness.repository.markConfigurationUpdateStage(
      operationId: operation.id,
      stage: TrackingConfigurationUpdateStage.producerFenced,
    );
    await harness.repository.markConfigurationUpdateStage(
      operationId: operation.id,
      stage: TrackingConfigurationUpdateStage.nativeApplied,
    );
    final activated = await harness.repository.activateConfigurationUpdate(
      operationId: operation.id,
    );

    final active = await harness.repository.activeConfigurationEpoch(trackId);
    expect(active!.id, activated.id);
    expect(active.epochNumber, 2);
    expect(
      active.continuityPolicyVersion,
      TrackingPolicyVersions.continuityPolicy,
    );
    expect(
      await harness.repository.activeConfigurationEpoch('missing-track'),
      isNull,
    );
    await harness.repository.close();
  });

  test('points record the quality version that produced their decision',
      () async {
    final harness = RepositoryHarness();
    await harness.initialize();
    final trackId = await harness.createActiveTrack(trackId: 'provenance');
    LocationSample sample(int second) => LocationSample(
          latitude: 0.001,
          longitude: 0.001 + second / 1e5,
          capturedAt: harness.now.add(Duration(seconds: second)),
          horizontalAccuracy: 5,
          provider: 'test',
          trackId: trackId,
        );
    PointWriteRequest request(int second, {int? qualityPolicyVersion}) =>
        PointWriteRequest(
          trackId: trackId,
          sample: sample(second),
          activity: const ActivitySnapshot.unknown(),
          motionState: MotionState.moving,
          accepted: true,
          qualityFlags: TrackPointQualityFlag.none,
          qualityPolicyVersion: qualityPolicyVersion,
        );

    final unstated = await harness.repository.appendPoint(request(1));
    final stated = await harness.repository.appendPoint(
      request(2, qualityPolicyVersion: 3),
    );

    expect(unstated.qualityPolicyVersion, TrackingPolicyVersions.qualityPolicy);
    expect(stated.qualityPolicyVersion, 3);
    expect(stated.configurationEpochId, unstated.configurationEpochId);
    await harness.repository.close();
  });
}
