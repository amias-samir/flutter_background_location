import 'package:flutter/services.dart';
import 'package:flutter_background_location_tracker/src/platform/native_tracker_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('FIX-21 the location stream asks native not to replay the journal',
      () async {
    const channel = EventChannel('test/fix21/location');
    Object? listenArguments;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      channel,
      MockStreamHandler.inline(
        onListen: (arguments, events) => listenArguments = arguments,
      ),
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockStreamHandler(channel, null),
    );

    final adapter = NativeTrackerAdapter(locationChannel: channel);
    final subscription = adapter.locationStream.listen((_) {});
    await pumpEventQueue();

    expect(listenArguments, <Object?, Object?>{'replayOnListen': 'none'});
    await subscription.cancel();
  });

  test('FLT-09 the native protocol is fetched once per adapter', () async {
    const channel = MethodChannel('test/flt09/methods');
    var calls = 0;
    var fail = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'getProtocolInfo') return null;
      calls += 1;
      if (fail) {
        fail = false;
        throw PlatformException(code: 'temporarily_unavailable');
      }
      return <String, Object?>{
        'version': 2,
        'capabilityCodes': <String>['paged_journal'],
      };
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final adapter = NativeTrackerAdapter(methodChannel: channel);

    // A failure is not cached.
    await expectLater(
        adapter.protocolInfo(), throwsA(isA<PlatformException>()));
    final first = await adapter.protocolInfo();
    final second = await adapter.protocolInfo();

    expect(first.supports('paged_journal'), isTrue);
    expect(identical(first, second), isTrue);
    expect(calls, 2);
  });
}
