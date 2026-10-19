import 'package:flutter_background_location_tracker/src/application/motion_gate.dart';
import 'package:flutter_background_location_tracker/src/domain/activity_snapshot.dart';
import 'package:flutter_background_location_tracker/src/domain/tracker_status.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_config.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_configuration_epoch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime.utc(2026, 10, 18, 13);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  ActivitySnapshot periodic(
    TrackingActivityType type,
    int confidence,
    int seconds, {
    String rawType = 'still',
  }) =>
      ActivitySnapshot(
        type: type,
        confidence: confidence,
        recordedAt: at(seconds),
        source: 'android_activity_recognition',
        rawType: rawType,
      );

  ActivitySnapshot transition(
    TrackingActivityType type,
    int confidence,
    int seconds,
  ) =>
      ActivitySnapshot(
        type: type,
        confidence: confidence,
        recordedAt: at(seconds),
        source: 'android_activity_transition',
      );

  ActivitySnapshot coreMotion(
    TrackingActivityType type,
    int confidence,
    int seconds,
  ) =>
      ActivitySnapshot(
        type: type,
        confidence: confidence,
        recordedAt: at(seconds),
        source: 'ios_core_motion_activity',
      );

  MotionGate stillGate() {
    final gate = MotionGate(const TrackingConfig());
    for (var second = 0; second <= 30; second += 5) {
      gate.add(
        periodic(TrackingActivityType.stationary, 100, second),
        at(second),
      );
    }
    return gate;
  }

  test('new adaptive configurations use motion policy 2', () {
    expect(
      MotionGate(const TrackingConfig()).policyVersion,
      TrackingPolicyVersions.motionPolicy,
    );
    expect(TrackingPolicyVersions.motionPolicy, 2);
  });

  test('an episode starts once confident still stands for 30 s', () {
    final gate = MotionGate(const TrackingConfig());
    gate.add(periodic(TrackingActivityType.stationary, 100, 0), at(0));
    gate.add(periodic(TrackingActivityType.stationary, 98, 25), at(25));
    expect(gate.stillEpisodeActive, isFalse);
    gate.evaluate(at(30));
    expect(gate.stillEpisodeActive, isTrue);
    expect(gate.stillEpisodeStartedAt, at(0));
    expect(gate.state, isNot(MotionState.stationary));
    gate.evaluate(at(90));
    expect(gate.state, MotionState.stationary);
  });

  test('field-test dips are neutral inside an episode', () {
    final gate = stillGate();
    gate
      ..add(
        periodic(TrackingActivityType.unknown, 40, 35, rawType: 'unknown'),
        at(35),
      )
      ..add(
        periodic(TrackingActivityType.unknown, 100, 40, rawType: 'tilting'),
        at(40),
      )
      ..add(periodic(TrackingActivityType.stationary, 36, 45), at(45))
      ..add(
        periodic(TrackingActivityType.inVehicle, 71, 50, rawType: 'inVehicle'),
        at(50),
      )
      ..add(
        periodic(TrackingActivityType.unknown, 40, 55, rawType: 'unknown'),
        at(55),
      );
    expect(gate.stillEpisodeActive, isTrue);
  });

  test('Activity Recognition silence keeps the episode', () {
    final gate = stillGate();
    // Google pauses reports while a device stays still; 25 minutes later a
    // fix still finds the episode current.
    gate.evaluate(at(25 * 60));
    expect(gate.stillEpisodeActive, isTrue);
    expect(gate.state, MotionState.stationary);
  });

  test('a stale reading is neutral inside an episode', () {
    final gate = stillGate();
    gate.add(
      ActivitySnapshot(
        type: TrackingActivityType.stationary,
        confidence: 100,
        recordedAt: at(31),
        evidenceState: ActivityEvidenceState.stale,
        source: 'android_activity_recognition',
      ),
      at(1500),
    );
    expect(gate.stillEpisodeActive, isTrue);
  });

  test('two consecutive moving readings end the episode, one does not', () {
    final gate = stillGate();
    gate.add(
      periodic(TrackingActivityType.walking, 90, 35, rawType: 'onFoot'),
      at(35),
    );
    expect(gate.stillEpisodeActive, isTrue);
    gate.add(
      periodic(TrackingActivityType.unknown, 40, 40, rawType: 'unknown'),
      at(40),
    );
    gate.add(
      periodic(TrackingActivityType.walking, 90, 45, rawType: 'onFoot'),
      at(45),
    );
    expect(gate.stillEpisodeActive, isTrue, reason: 'not consecutive');
    gate.add(
      periodic(TrackingActivityType.walking, 92, 50, rawType: 'onFoot'),
      at(50),
    );
    expect(gate.stillEpisodeActive, isFalse);
    expect(gate.state, MotionState.moving);
  });

  test('in-vehicle readings need confidence 75 to count as moving', () {
    final gate = stillGate();
    gate
      ..add(periodic(TrackingActivityType.inVehicle, 71, 35), at(35))
      ..add(periodic(TrackingActivityType.inVehicle, 74, 40), at(40));
    expect(gate.stillEpisodeActive, isTrue);
    gate
      ..add(periodic(TrackingActivityType.inVehicle, 96, 45), at(45))
      ..add(periodic(TrackingActivityType.inVehicle, 96, 50), at(50));
    expect(gate.stillEpisodeActive, isFalse);
  });

  test('ENTER of a moving activity and EXIT STILL end the episode at once', () {
    final walking = stillGate()
      ..add(transition(TrackingActivityType.walking, 100, 35), at(35));
    expect(walking.stillEpisodeActive, isFalse);

    final exitStill = stillGate()
      ..add(transition(TrackingActivityType.stationary, 0, 35), at(35));
    expect(exitStill.stillEpisodeActive, isFalse);
  });

  test('ENTER STILL starts an episode immediately', () {
    final gate = MotionGate(const TrackingConfig())
      ..add(transition(TrackingActivityType.stationary, 100, 0), at(0));
    expect(gate.stillEpisodeActive, isTrue);
  });

  test('a departure confirmed by a fix ignores older still readings', () {
    final gate = stillGate()..endStillEpisode(at(60));
    expect(gate.stillEpisodeActive, isFalse);
    // A reading recorded before the departure cannot reopen the stop, and a
    // newer one needs its own 30 s.
    gate.add(periodic(TrackingActivityType.stationary, 100, 58), at(61));
    gate.evaluate(at(70));
    expect(gate.stillEpisodeActive, isFalse);
    gate.add(periodic(TrackingActivityType.stationary, 100, 65), at(65));
    gate.evaluate(at(90));
    expect(gate.stillEpisodeActive, isFalse);
    gate.evaluate(at(95));
    expect(gate.stillEpisodeActive, isTrue);
  });

  test('duplicate readings from the stream and fixes count once', () {
    final gate = stillGate();
    final walking = periodic(
      TrackingActivityType.walking,
      90,
      35,
      rawType: 'onFoot',
    );
    gate
      ..add(walking, at(35))
      ..add(walking, at(36));
    expect(gate.stillEpisodeActive, isTrue);
  });

  test('restoring stored stop evidence resumes the episode', () {
    final gate = MotionGate(const TrackingConfig())..restoreStillEpisode(at(0));
    expect(gate.stillEpisodeActive, isTrue);
  });

  test('Core Motion: high confidence moving ends at once, medium after 10 s',
      () {
    MotionGate iosStill() {
      final gate = MotionGate(const TrackingConfig())
        ..add(coreMotion(TrackingActivityType.stationary, 100, 0), at(0));
      gate.evaluate(at(30));
      expect(gate.stillEpisodeActive, isTrue);
      return gate;
    }

    final high = iosStill()
      ..add(coreMotion(TrackingActivityType.walking, 100, 40), at(40));
    expect(high.stillEpisodeActive, isFalse);

    final medium = iosStill()
      ..add(coreMotion(TrackingActivityType.walking, 67, 40), at(40));
    medium.evaluate(at(45));
    expect(medium.stillEpisodeActive, isTrue);
    medium.evaluate(at(50));
    expect(medium.stillEpisodeActive, isFalse);

    final interrupted = iosStill()
      ..add(coreMotion(TrackingActivityType.walking, 67, 40), at(40))
      ..add(coreMotion(TrackingActivityType.stationary, 100, 44), at(44));
    interrupted.evaluate(at(60));
    expect(interrupted.stillEpisodeActive, isTrue);
  });

  test('explicit capture intents and legacy configurations keep policy 1', () {
    for (final intent in <RouteCaptureIntent>[
      RouteCaptureIntent.walking,
      RouteCaptureIntent.cycling,
      RouteCaptureIntent.vehicle,
    ]) {
      final gate = MotionGate(TrackingConfig(captureIntent: intent));
      expect(gate.policyVersion, 1, reason: intent.name);
      gate.add(transition(TrackingActivityType.stationary, 100, 0), at(0));
      expect(gate.stillEpisodeActive, isFalse, reason: intent.name);
    }
    final legacy = MotionGate(
      TrackingConfig.fromMap(const <String, Object?>{'motionPolicyVersion': 1}),
    );
    expect(legacy.policyVersion, 1);
  });
}
