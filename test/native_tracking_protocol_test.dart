import 'package:flutter/services.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/src/platform/native_tracker_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('protocol parser preserves unknown capability strings', () {
    final protocol = NativeTrackingProtocol.fromMap(<Object?, Object?>{
      'version': 2,
      'capabilityCodes': <Object?>[
        NativeTrackingCapabilities.locationSettings,
        'future_native_capability',
        '',
        '  ',
      ],
    });

    expect(protocol.version, 2);
    expect(
      protocol.capabilityCodes,
      <String>{
        NativeTrackingCapabilities.locationSettings,
        'future_native_capability',
      },
    );
    expect(protocol.supports('future_native_capability'), isTrue);
  });

  test('native adapter negotiates protocol info', () async {
    final channel = const MethodChannel('test/protocol_info');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getProtocolInfo');
      return <String, Object?>{
        'version': 2,
        'capabilityCodes': <String>[
          NativeTrackingCapabilities.sharedPendingLocationCoordinator,
          'future_native_capability',
        ],
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final adapter = NativeTrackerAdapter(methodChannel: channel);
    final protocol = await (adapter as NativeProtocolAdapter).protocolInfo();

    expect(protocol.version, 2);
    expect(
      protocol.capabilityCodes,
      containsAll(<String>[
        NativeTrackingCapabilities.sharedPendingLocationCoordinator,
        'future_native_capability',
      ]),
    );
  });

  test('native adapter treats missing protocol method as legacy v1', () async {
    final channel = const MethodChannel('test/protocol_missing');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final adapter = NativeTrackerAdapter(methodChannel: channel);
    final protocol = await (adapter as NativeProtocolAdapter).protocolInfo();

    expect(protocol.version, 1);
    expect(protocol.capabilityCodes, isEmpty);
  });

  test('native adapter fences lifecycle commands with negotiated revisions',
      () async {
    final channel = const MethodChannel('test/command_lease');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'getProtocolInfo':
          return <String, Object?>{
            'version': 2,
            'capabilityCodes': <String>[
              NativeTrackingCapabilities.commandLease,
            ],
          };
        case 'acquireCommandLease':
          return <String, Object?>{
            'engineLeaseToken': 'engine-lease',
            'commandRevision': 4,
          };
        case 'pauseTrackingV2':
          expect(call.arguments, containsPair('trackId', 'track-1'));
          expect(
              call.arguments, containsPair('sessionControlToken', 'session-1'));
          expect(
              call.arguments, containsPair('engineLeaseToken', 'engine-lease'));
          expect(call.arguments, containsPair('expectedCommandRevision', 4));
          expect((call.arguments! as Map)['commandId'], isNotEmpty);
          return <String, Object?>{'commandRevision': 5};
        case 'resumeTrackingV2':
          expect(call.arguments, containsPair('expectedCommandRevision', 5));
          return <String, Object?>{'commandRevision': 6};
        case 'releaseCommandLease':
          return true;
      }
      fail('Unexpected method ${call.method}');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final adapter = NativeTrackerAdapter(methodChannel: channel);
    final leasing = adapter as CommandLeaseTrackerAdapter;
    final lease = await leasing.acquireCommandLease(
      trackId: 'track-1',
      sessionControlToken: 'session-1',
    );
    expect(lease.supported, isTrue);
    expect(lease.commandRevision, 4);

    await adapter.pause(trackId: 'track-1');
    await adapter.resume(
      trackId: 'track-1',
      config: const TrackingConfig(),
    );
    await leasing.releaseCommandLease(trackId: 'track-1');

    expect(calls.map((call) => call.method), contains('pauseTrackingV2'));
    expect(calls.map((call) => call.method), contains('resumeTrackingV2'));
  });

  test('native adapter preserves legacy lifecycle methods without capability',
      () async {
    final channel = const MethodChannel('test/legacy_command');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getProtocolInfo') {
        return <String, Object?>{'version': 1, 'capabilityCodes': <String>[]};
      }
      if (call.method == 'pauseTracking') return <String, Object?>{};
      fail('Unexpected method ${call.method}');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final adapter = NativeTrackerAdapter(methodChannel: channel);
    final lease =
        await (adapter as CommandLeaseTrackerAdapter).acquireCommandLease(
      trackId: 'track-1',
      sessionControlToken: 'session-1',
    );
    expect(lease.supported, isFalse);
    await adapter.pause(trackId: 'track-1');
    expect(calls.last.method, 'pauseTracking');
  });

  test('native adapter reads bounded pending-location pages', () async {
    final channel = const MethodChannel('test/pending_page');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getProtocolInfo') {
        return <String, Object?>{
          'version': 2,
          'capabilityCodes': <String>[
            NativeTrackingCapabilities.pagedJournal,
            NativeTrackingCapabilities.byteBoundedJournal,
          ],
        };
      }
      expect(call.method, 'getPendingLocationsPage');
      return <String, Object?>{
        'events': <Object?>[
          <String, Object?>{
            'eventId': 'event-1',
            'trackId': 'track-1',
            'lat': 27.7,
            'lon': 85.3,
            'timestamp': DateTime.utc(2026, 8, 25).millisecondsSinceEpoch,
          },
        ],
        'nextCursor': '12',
        'hasMore': true,
        'encodedBytes': 256,
        'remainingCount': 3,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final adapter = NativeTrackerAdapter(methodChannel: channel);
    final page =
        await (adapter as PagedNativeLocationAdapter).pendingLocationPage(
      cursor: '7',
      maxRecords: 25,
      maxEncodedBytes: 64 * 1024,
    );

    expect(page.events, hasLength(1));
    expect(page.events.single.eventId, 'event-1');
    expect(page.nextCursor, '12');
    expect(page.hasMore, isTrue);
    expect(page.encodedBytes, 256);
    expect(page.remainingCount, 3);
    expect(calls.last.arguments, containsPair('cursor', '7'));
    expect(calls.last.arguments, containsPair('maxRecords', 25));
    expect(calls.last.arguments, containsPair('maxEncodedBytes', 64 * 1024));
  });

  test('native adapter reports paged pending locations as unsupported',
      () async {
    final channel = const MethodChannel('test/pending_page_unsupported');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getProtocolInfo');
      return <String, Object?>{
        'version': 2,
        'capabilityCodes': const <String>[],
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final adapter = NativeTrackerAdapter(methodChannel: channel);

    expect(
      () => (adapter as PagedNativeLocationAdapter).pendingLocationPage(),
      throwsA(
        isA<TrackingNativeException>().having(
          (error) => error.code,
          'code',
          'capability_unsupported',
        ),
      ),
    );
  });

  test('native adapter reads redacted journal diagnostics', () async {
    final channel = const MethodChannel('test/journal_diagnostic');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getProtocolInfo') {
        return <String, Object?>{
          'version': 2,
          'capabilityCodes': <String>[
            NativeTrackingCapabilities.nativeJournalDiagnostics,
          ],
        };
      }
      expect(call.method, 'getNativeJournalDiagnostic');
      return <String, Object?>{
        'platform': 'android',
        'healthy': true,
        'opened': true,
        'databaseName': 'flutter_background_location_pending.db',
        'integrityCheck': 'ok',
        'stats': <String, Object?>{
          'pendingRows': 2,
          'pendingPayloadBytes': 512,
        },
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final adapter = NativeTrackerAdapter(methodChannel: channel);
    final diagnostic = await (adapter as NativeJournalDiagnosticsAdapter)
        .nativeJournalDiagnostic(performMaintenance: true);

    expect(diagnostic['healthy'], isTrue);
    expect(diagnostic['opened'], isTrue);
    expect(diagnostic['databaseName'], contains('flutter_background'));
    expect(calls.last.method, 'getNativeJournalDiagnostic');
    expect(calls.last.arguments, containsPair('performMaintenance', true));
  });

  test('native adapter reports journal diagnostics as unsupported', () async {
    final channel = const MethodChannel('test/journal_diagnostic_missing');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getProtocolInfo');
      return <String, Object?>{
        'version': 2,
        'capabilityCodes': const <String>[],
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final adapter = NativeTrackerAdapter(methodChannel: channel);
    final diagnostic = await (adapter as NativeJournalDiagnosticsAdapter)
        .nativeJournalDiagnostic();

    expect(diagnostic['healthy'], isFalse);
    expect(diagnostic['opened'], isFalse);
    expect(diagnostic['errorType'], 'capability_unsupported');
  });

  test('native adapter opens typed settings destinations', () async {
    final channel = const MethodChannel('test/settings');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      if (call.method == 'getProtocolInfo') {
        return <String, Object?>{
          'version': 2,
          'capabilityCodes': <String>[
            NativeTrackingCapabilities.locationSettings,
          ],
        };
      }
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final adapter = NativeTrackerAdapter(methodChannel: channel);
    final result = await (adapter as TrackerSettingsAdapter).openSettings(
      TrackingSettingsDestination.locationServices,
    );

    expect(result.supported, isTrue);
    expect(result.opened, isTrue);
    expect(result.destination, TrackingSettingsDestination.locationServices);
    expect(methods, <String>['getProtocolInfo', 'openLocationSettings']);
  });

  test('native adapter reads Android battery optimization state', () async {
    final channel = const MethodChannel('test/battery');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getProtocolInfo') {
        return <String, Object?>{
          'version': 2,
          'capabilityCodes': <String>[
            NativeTrackingCapabilities.batteryOptimizationSettings,
          ],
        };
      }
      expect(call.method, 'getBatteryOptimizationStatus');
      return <String, Object?>{
        'supported': true,
        'isIgnoringBatteryOptimizations': false,
        'packageName': 'com.example.app',
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final adapter = NativeTrackerAdapter(methodChannel: channel);
    final state =
        await (adapter as TrackerSettingsAdapter).batteryOptimizationState();

    expect(state.supported, isTrue);
    expect(state.isIgnoringBatteryOptimizations, isFalse);
    expect(state.packageName, 'com.example.app');
  });

  test('missing settings methods return unsupported typed results', () async {
    final channel = const MethodChannel('test/settings_missing');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final adapter = NativeTrackerAdapter(methodChannel: channel);
    final settings = await (adapter as TrackerSettingsAdapter).openSettings(
      TrackingSettingsDestination.batteryOptimization,
    );
    final battery =
        await (adapter as TrackerSettingsAdapter).batteryOptimizationState();

    expect(settings.supported, isFalse);
    expect(settings.opened, isFalse);
    expect(battery.supported, isFalse);
    expect(battery.isIgnoringBatteryOptimizations, isTrue);
  });

  test('native adapter requests only the selected permission step', () async {
    final channel = const MethodChannel('test/staged_permission');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getProtocolInfo') {
        return <String, Object?>{
          'version': 2,
          'capabilityCodes': <String>[
            NativeTrackingCapabilities.stagedPermissionRequests,
          ],
        };
      }
      if (call.method == 'getPermissionStatus') {
        return <String, Object?>{
          'platform': 'android',
          'location': 'whileInUse',
          'locationServiceEnabled': true,
          'preciseLocation': true,
          'notificationGranted': true,
        };
      }
      expect(call.method, 'requestPermissions');
      return <String, Object?>{
        'platform': 'android',
        'location': 'always',
        'locationServiceEnabled': true,
        'preciseLocation': true,
        'notificationGranted': true,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final adapter = NativeTrackerAdapter(methodChannel: channel);
    final state =
        await (adapter as StagedPermissionAdapter).requestPermissionStep(
      action: TrackingReadinessAction.requestBackgroundLocation,
      expectedReadinessRevision: 42,
    );

    final request = calls.singleWhere(
      (call) => call.method == 'requestPermissions',
    );
    expect(state.location, LocationPermissionLevel.always);
    expect(
      request.arguments,
      containsPair('backgroundLocation', true),
    );
    expect(request.arguments, containsPair('location', false));
    expect(request.arguments, containsPair('activityRecognition', false));
    expect(request.arguments, containsPair('notifications', false));
    expect(request.arguments, containsPair('expectedReadinessRevision', 42));
  });

  test('native adapter negotiates track-scoped journal deletion', () async {
    const channel = MethodChannel('test/track_scoped_clear');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getProtocolInfo') {
        return <String, Object?>{
          'version': 2,
          'capabilityCodes': <String>[
            NativeTrackingCapabilities.trackScopedNativeClear,
          ],
        };
      }
      expect(call.method, 'clearNativeTrackData');
      expect(call.arguments, containsPair('trackId', 'route-1'));
      return 3;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final adapter = NativeTrackerAdapter(methodChannel: channel);
    final deleted = await (adapter as TrackScopedNativeDataAdapter)
        .clearNativeTrackData('route-1');

    expect(deleted, 3);
    expect(calls.map((call) => call.method),
        <String>['getProtocolInfo', 'clearNativeTrackData']);
  });
}
