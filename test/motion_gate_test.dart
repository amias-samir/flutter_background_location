import 'package:flutter_background_location/src/application/motion_gate.dart';
import 'package:flutter_background_location/src/domain/activity_snapshot.dart';
import 'package:flutter_background_location/src/domain/tracker_status.dart';
import 'package:flutter_background_location/src/domain/tracking_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const config = TrackingConfig(
    stationaryConfirmationDuration: Duration(seconds: 90),
    movingConfirmationCount: 2,
  );
  final epoch = DateTime.utc(2026, 7, 20, 8);

  ActivitySnapshot activity(
    TrackingActivityType type,
    int confidence,
    DateTime at,
  ) =>
      ActivitySnapshot(type: type, confidence: confidence, recordedAt: at);

  test('requires sustained high-confidence stationary evidence', () {
    final gate = MotionGate(config);

    expect(
      gate.add(activity(TrackingActivityType.stationary, 75, epoch), epoch),
      MotionState.unknown,
    );
    expect(
      gate.add(
        activity(
          TrackingActivityType.stationary,
          90,
          epoch.add(const Duration(seconds: 89)),
        ),
        epoch.add(const Duration(seconds: 89)),
      ),
      MotionState.unknown,
    );
    expect(
      gate.add(
        activity(
          TrackingActivityType.stationary,
          90,
          epoch.add(const Duration(seconds: 90)),
        ),
        epoch.add(const Duration(seconds: 90)),
      ),
      MotionState.stationary,
    );
    expect(gate.samplingProfile, SamplingProfile.stationary);
  });

  test('noise resets stationary confirmation window', () {
    final gate = MotionGate(config);
    gate.add(activity(TrackingActivityType.stationary, 90, epoch), epoch);
    gate.add(
      activity(
        TrackingActivityType.unknown,
        100,
        epoch.add(const Duration(seconds: 60)),
      ),
      epoch.add(const Duration(seconds: 60)),
    );

    expect(
      gate.add(
        activity(
          TrackingActivityType.stationary,
          90,
          epoch.add(const Duration(seconds: 91)),
        ),
        epoch.add(const Duration(seconds: 91)),
      ),
      MotionState.unknown,
    );
  });

  test('requires consecutive movement evidence to leave stationary mode', () {
    final gate = MotionGate(config);
    gate.add(activity(TrackingActivityType.stationary, 90, epoch), epoch);
    gate.add(
      activity(
        TrackingActivityType.stationary,
        90,
        epoch.add(const Duration(seconds: 90)),
      ),
      epoch.add(const Duration(seconds: 90)),
    );

    expect(
      gate.add(
        activity(
          TrackingActivityType.walking,
          60,
          epoch.add(const Duration(seconds: 91)),
        ),
        epoch.add(const Duration(seconds: 91)),
      ),
      MotionState.stationary,
    );
    expect(
      gate.add(
        activity(
          TrackingActivityType.inVehicle,
          80,
          epoch.add(const Duration(seconds: 92)),
        ),
        epoch.add(const Duration(seconds: 92)),
      ),
      MotionState.moving,
    );
    expect(gate.samplingProfile, SamplingProfile.moving);
  });

  test('low-confidence or unknown evidence breaks a movement streak', () {
    final gate = MotionGate(config);
    gate.add(activity(TrackingActivityType.walking, 90, epoch), epoch);
    gate.add(
      activity(
        TrackingActivityType.unknown,
        90,
        epoch.add(const Duration(seconds: 1)),
      ),
      epoch.add(const Duration(seconds: 1)),
    );

    expect(
      gate.add(
        activity(
          TrackingActivityType.onBicycle,
          90,
          epoch.add(const Duration(seconds: 2)),
        ),
        epoch.add(const Duration(seconds: 2)),
      ),
      MotionState.unknown,
    );
    expect(
      gate.add(
        activity(
          TrackingActivityType.onBicycle,
          59,
          epoch.add(const Duration(seconds: 3)),
        ),
        epoch.add(const Duration(seconds: 3)),
      ),
      MotionState.unknown,
    );
  });
}
