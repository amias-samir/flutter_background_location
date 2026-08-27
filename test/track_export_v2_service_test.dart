import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RepositoryHarness harness;
  late Directory root;

  setUp(() async {
    harness = RepositoryHarness();
    await harness.initialize();
    root = await Directory.systemTemp.createTemp('fbl-export-v2-');
  });

  tearDown(() async {
    await harness.repository.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<String> completedRoute(String id) async {
    final trackId = await harness.createActiveTrack(trackId: id);
    await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
    );
    await harness.append(
      trackId: trackId,
      latitude: 27.701,
      longitude: 85.301,
    );
    await harness.repository.completeTrack(trackId, reason: 'finished');
    return trackId;
  }

  test('S1-02 local V2 export is inventoried, collision-safe, and shareable',
      () async {
    final trackId = await completedRoute('local-v2');
    final exportRoot = Directory('${root.path}/exports');
    final cacheRoot = Directory('${root.path}/cache');
    final service = TrackExportServiceV2(
      repository: harness.repository,
      owner: const TrackingOwner(
        userId: 'user-1',
        organizationId: 'org-1',
      ),
      useAndroidNativeDestination: false,
      exportDirectoryProvider: () async => exportRoot,
      shareCacheDirectoryProvider: () async => cacheRoot,
    );

    Future<TrackExportResultV2> export() async {
      final operation = await service.exportTrackV2(
        TrackExportRequest(
          trackId: trackId,
          format: TrackExportFormat.gpx,
          fileName: '../काठमाडौं patrol.JSON',
        ),
      );
      return operation.result;
    }

    final first = await export();
    final second = await export();
    expect(first.destination.contentUri, isNull);
    expect(first.destination.localFilePath, isNotNull);
    expect(first.destination.displayName, 'काठमाडौं patrol.gpx');
    expect(second.destination.displayName, 'काठमाडौं patrol_1.gpx');
    expect(await File(first.destination.localFilePath!).exists(), isTrue);

    final inventory = await harness.repository.getManagedExport(
      owner: const TrackingOwner(
        userId: 'user-1',
        organizationId: 'org-1',
      ),
      exportId: first.managedExportId,
    );
    expect(inventory?.state, ManagedExportState.committed);
    expect(
        inventory?.destination?.localFilePath, first.destination.localFilePath);
    final managed = await service.listManagedExports(trackId);
    expect(
      managed.map((item) => item.id).toSet(),
      <String>{first.managedExportId, second.managedExportId},
    );

    final stale = File(
      '${cacheRoot.path}/flutter_background_location_share/stale.gpx',
    );
    await stale.create(recursive: true);
    await stale
        .setLastModified(DateTime.now().subtract(const Duration(days: 2)));
    final prepared = await service.prepareExportForSharing(first);
    expect(await stale.exists(), isFalse);
    expect(await File(prepared.path).readAsBytes(),
        await File(first.destination.localFilePath!).readAsBytes());
    await prepared.delete();
    expect(await File(prepared.path).exists(), isFalse);

    final deletion = await service.deleteManagedExport(first.managedExportId);
    expect(deletion.status, 'deleted');
    expect(deletion.artifactRemoved, isTrue);
    expect(await File(first.destination.localFilePath!).exists(), isFalse);
    final repeated = await service.deleteManagedExport(first.managedExportId);
    expect(repeated.status, 'already_deleted');
    expect(await File(second.destination.localFilePath!).exists(), isTrue);
  });

  test('S1-02 Android channel streams bytes and returns the real content URI',
      () async {
    final trackId = await completedRoute('native-v2');
    const channel = MethodChannel('test/export-v2');
    final chunks = <Uint8List>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getProtocolInfo':
          return <String, Object?>{
            'version': 2,
            'capabilityCodes': <String>['streaming_export_v2'],
          };
        case 'beginExportToDownloadsV2':
          return <String, Object?>{'handleId': 'native-handle'};
        case 'appendExportToDownloadsV2':
          final arguments = call.arguments! as Map<Object?, Object?>;
          chunks.add(arguments['bytes']! as Uint8List);
          return true;
        case 'commitExportToDownloadsV2':
          return <String, Object?>{
            'displayName': 'native.gpx',
            'mimeType': 'application/gpx+xml',
            'contentUri': 'content://media/external/downloads/42',
            'displayPath': 'Download/flutter_background_location/native.gpx',
            'userVisible': true,
          };
        case 'copyExportToCacheV2':
          final arguments = call.arguments! as Map<Object?, Object?>;
          await File(arguments['destinationPath']! as String)
              .writeAsBytes(chunks.expand((chunk) => chunk).toList());
          return true;
        case 'abortExportToDownloadsV2':
          return true;
        case 'deleteExportDestinationV2':
          return true;
      }
      return null;
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );

    final service = TrackExportServiceV2(
      repository: harness.repository,
      owner: const TrackingOwner(
        userId: 'user-1',
        organizationId: 'org-1',
      ),
      methodChannel: channel,
      useAndroidNativeDestination: true,
      shareCacheDirectoryProvider: () async => Directory('${root.path}/cache'),
    );
    final operation = await service.exportTrackV2(
      TrackExportRequest(
        trackId: trackId,
        format: TrackExportFormat.gpx,
        fileName: 'native',
      ),
    );
    final result = await operation.result;

    expect(result.destination.contentUri.toString(),
        'content://media/external/downloads/42');
    expect(result.destination.localFilePath, isNull);
    expect(result.destination.userVisible, isTrue);
    expect(chunks, isNotEmpty);
    expect(chunks.every((chunk) => chunk.length <= 1024 * 1024), isTrue);
    expect(utf8.decode(chunks.expand((chunk) => chunk).toList()),
        contains('<gpx'));

    final prepared = await service.prepareExportForSharing(result);
    expect(await File(prepared.path).readAsString(), contains('<gpx'));
    await prepared.delete();
    final deletion = await service.deleteManagedExport(result.managedExportId);
    expect(deletion.status, 'deleted');
    expect(deletion.artifactRemoved, isTrue);
  });

  test('S1-02 refuses an old Android binary instead of fabricating a path',
      () async {
    final trackId = await completedRoute('legacy-native');
    const channel = MethodChannel('test/export-v2-legacy');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'getProtocolInfo'
          ? <String, Object?>{
              'version': 1,
              'capabilityCodes': const <String>[],
            }
          : null,
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final service = TrackExportServiceV2(
      repository: harness.repository,
      owner: const TrackingOwner(
        userId: 'user-1',
        organizationId: 'org-1',
      ),
      methodChannel: channel,
      useAndroidNativeDestination: true,
    );

    await expectLater(
      service.exportTrackV2(
        TrackExportRequest(
          trackId: trackId,
          format: TrackExportFormat.geoJson,
        ),
      ),
      throwsA(
        isA<TrackingExportException>().having(
          (error) => error.code,
          'code',
          'native_protocol_upgrade_required',
        ),
      ),
    );
  });

  test('S1-02 destination rejects zero and multiple access handles', () {
    expect(
      () => TrackExportDestination(
        displayName: 'route.gpx',
        mimeType: 'application/gpx+xml',
        userVisible: false,
      ),
      throwsArgumentError,
    );
    expect(
      () => TrackExportDestination(
        displayName: 'route.gpx',
        mimeType: 'application/gpx+xml',
        contentUri: Uri.parse('content://exports/1'),
        localFilePath: '/tmp/route.gpx',
        userVisible: false,
      ),
      throwsArgumentError,
    );
  });
}
