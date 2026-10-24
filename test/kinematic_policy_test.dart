import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/src/domain/kinematic_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// One re-acquisition fix of the 2026-10-24 two-phone field test, as relative
/// values only: seconds of silence before it, metres from the last accepted
/// point, its Doppler speed and accuracy, and whether it was right.
final class _Reacquisition {
  const _Reacquisition(
    this.label,
    this.silenceSeconds,
    this.meters,
    this.speed,
    this.speedAccuracy, {
    required this.vouched,
  });

  final String label;
  final int silenceSeconds;
  final double meters;
  final double speed;
  final double speedAccuracy;
  final bool vouched;
}

void main() {
  group('Doppler classes (R1)', () {
    DopplerClass classify(double? speed, double? accuracy) =>
        KinematicPolicy.classify(speed: speed, speedAccuracy: accuracy);

    test('speed accuracy decides what a Doppler speed may vouch for', () {
      expect(classify(1.2, 0.2), DopplerClass.precise);
      expect(classify(8, 1.5), DopplerClass.precise);
      expect(classify(8, 1.6), DopplerClass.usable);
      expect(classify(4, 2.9), DopplerClass.usable);
      expect(classify(4, 3), DopplerClass.degraded);
      expect(classify(0.51, 11.1), DopplerClass.degraded);
    });

    test('a zero speed with metres per second of accuracy is a placeholder',
        () {
      expect(classify(0, 2.5), DopplerClass.degraded);
      expect(classify(0.04, 1.5), DopplerClass.degraded);
      // A precisely measured stillness is a measurement.
      expect(classify(0, 0.1), DopplerClass.precise);
      expect(classify(0.31, 2.5), DopplerClass.usable);
    });

    test('missing or invalid values are degraded', () {
      expect(classify(null, 0.5), DopplerClass.degraded);
      expect(classify(1, null), DopplerClass.degraded);
      expect(classify(double.nan, 0.5), DopplerClass.degraded);
      expect(classify(-1, 0.5), DopplerClass.degraded);
      expect(classify(1, -0.5), DopplerClass.degraded);
    });
  });

  test('a far fix must prove itself after four moving intervals, at least 20 s',
      () {
    expect(
      KinematicPolicy.reacquisitionSilence(const Duration(seconds: 5)),
      const Duration(seconds: 20),
    );
    expect(
      KinematicPolicy.reacquisitionSilence(const Duration(seconds: 3)),
      const Duration(seconds: 20),
    );
    expect(
      KinematicPolicy.reacquisitionSilence(const Duration(seconds: 10)),
      const Duration(seconds: 40),
    );
  });

  test('reported accuracy can widen the effective sigma, never narrow it', () {
    expect(
      KinematicPolicy.effectiveSigma(reportedSigmaMeters: 1),
      KinematicPolicy.minimumSigmaMeters,
    );
    expect(
      KinematicPolicy.effectiveSigma(
        reportedSigmaMeters: 1.4,
        observedSigmaMeters: 4.6,
      ),
      4.6,
    );
    expect(
      KinematicPolicy.effectiveSigma(
        reportedSigmaMeters: 6.6,
        observedSigmaMeters: 2,
      ),
      6.6,
    );
    expect(KinematicPolicy.uncertaintyMeters(2, 2), 20);
    expect(KinematicPolicy.uncertaintyMeters(6, 8), closeTo(30, 1e-9));
  });

  test('only a precise Doppler speed vouches for its own fix', () {
    expect(
      KinematicPolicy.ownSpeedBound(speed: 1, speedAccuracy: 0.5),
      closeTo(3.5, 1e-9),
    );
    expect(KinematicPolicy.ownSpeedBound(speed: 4, speedAccuracy: 2), isNull);
  });

  test('context bounds keep mode floors and allow vehicles to accelerate', () {
    double bound(KinematicMode mode, double reference, int seconds) =>
        KinematicPolicy.contextSpeedBound(
          mode: mode,
          referenceSpeed: reference,
          elapsed: Duration(seconds: seconds),
        );
    expect(bound(KinematicMode.pedestrian, 1.2, 29), closeTo(3, 1e-9));
    expect(bound(KinematicMode.pedestrian, 1.6, 29), closeTo(3.4, 1e-9));
    expect(bound(KinematicMode.running, 2, 10), 6);
    expect(bound(KinematicMode.other, 0, 5), closeTo(13, 1e-9));
    expect(bound(KinematicMode.vehicle, 8, 60), closeTo(35, 1e-9));
    expect(bound(KinematicMode.bicycle, 0, 3), closeTo(16, 1e-9));
    expect(
      KinematicPolicy.modeOf(
        ActivitySnapshot(
          type: TrackingActivityType.walking,
          confidence: 90,
          recordedAt: DateTime.utc(2026, 10, 24),
        ),
        referenceSpeed: 1.3,
      ),
      KinematicMode.pedestrian,
    );
    expect(
      KinematicPolicy.modeOf(
        ActivitySnapshot(
          type: TrackingActivityType.walking,
          confidence: 90,
          recordedAt: DateTime.utc(2026, 10, 24),
        ),
        referenceSpeed: 8,
      ),
      KinematicMode.other,
      reason: 'a lagging walking reading does not throttle a vehicle',
    );
  });

  test('reachability caps every bound at 70 m/s', () {
    expect(
      KinematicPolicy.reachable(
        distanceMeters: 140000,
        uncertainty: 20,
        speedBound: 1000,
        elapsed: const Duration(minutes: 2),
      ),
      isFalse,
    );
    expect(
      KinematicPolicy.reachable(
        distanceMeters: 98,
        uncertainty: 20,
        speedBound: 3,
        elapsed: const Duration(seconds: 29),
      ),
      isTrue,
      reason: 'kinematics alone cannot reject the walking excursion; the '
          're-acquisition rule does',
    );
  });

  group('the first far fix after a silence (K2), field-test calibration', () {
    // Phone A (Qualcomm): every re-acquisition fix was right and carried a
    // precise Doppler speed. Phone B (MediaTek): the wrong ones carried a zero
    // placeholder, a precise near-zero speed that contradicts the distance,
    // or a broken speed; one right fix (24 s, 65 m) waits one fix.
    const cases = <_Reacquisition>[
      _Reacquisition('A 16:11:45', 285, 136, 8.25, 1.2, vouched: true),
      _Reacquisition('A 17:53:09', 162, 64, 4.12, 1.4, vouched: true),
      _Reacquisition('A 09:55:03', 339, 148, 5.35, 1.0, vouched: true),
      _Reacquisition('A 09:55:46', 24, 37, 2.58, 0.6, vouched: true),
      _Reacquisition('A 11:53:04', 202, 49, 6.27, 1.1, vouched: true),
      _Reacquisition('A 12:17:47', 71, 43, 4.93, 1.0, vouched: true),
      _Reacquisition('A 13:07:25', 62, 56, 6.84, 1.0, vouched: true),
      _Reacquisition('A 09:00:51', 50, 42, 5.59, 1.1, vouched: true),
      _Reacquisition('B 15:04:14 wrong', 20, 72, 0.12, 0.2, vouched: false),
      _Reacquisition('B 18:07:11 wrong', 27, 120, 0, 2.0, vouched: false),
      _Reacquisition('B 18:25:35', 34, 38, 1.16, 0.4, vouched: true),
      _Reacquisition('B 09:55:14 wrong', 334, 135, 0, 3.2, vouched: false),
      _Reacquisition('B 10:56:53', 60, 43, 1.03, 0.3, vouched: true),
      _Reacquisition('B 12:17:49 late', 24, 65, 4.44, 1.7, vouched: false),
      _Reacquisition('B 13:07:22', 112, 32, 4.40, 1.5, vouched: true),
      _Reacquisition('B 15:25:25', 35, 36, 0.59, 0.6, vouched: true),
      _Reacquisition('B 09:08:07 wrong', 30, 98, 0.51, 11.1, vouched: false),
    ];
    for (final fix in cases) {
      test(fix.label, () {
        expect(
          KinematicPolicy.vouchedAfterSilence(
            distanceMeters: fix.meters,
            uncertainty: 20,
            elapsed: Duration(seconds: fix.silenceSeconds),
            speed: fix.speed,
            speedAccuracy: fix.speedAccuracy,
          ),
          fix.vouched,
        );
      });
    }
  });

  test('constant-velocity residual separates a line from an out-and-back', () {
    final t0 = DateTime.utc(2026, 10, 24, 3);
    KinematicPoint at(int seconds, double north) => KinematicPoint(
          latitude: 0.5 + north / 111195.07973436875,
          longitude: 0.5,
          capturedAt: t0.add(Duration(seconds: seconds)),
        );
    expect(
      KinematicPolicy.constantVelocityResidualMeters(
        <KinematicPoint>[at(0, 0), at(15, 30), at(30, 60)],
      ),
      closeTo(0, 0.01),
    );
    expect(
      KinematicPolicy.constantVelocityResidualMeters(
        <KinematicPoint>[at(0, 0), at(15, 100), at(30, 0)],
      ),
      greaterThan(50),
    );
    expect(
      KinematicPolicy.constantVelocityResidualMeters(
        <KinematicPoint>[at(0, 0), at(15, 30)],
      ),
      isNull,
    );
  });

  test('observed moving sigma reads the scatter of evenly spaced fixes', () {
    final t0 = DateTime.utc(2026, 10, 24, 3);
    // A straight walk with a deterministic ±4 m cross-track zigzag.
    final points = <KinematicPoint>[
      for (var i = 0; i < 30; i += 1)
        KinematicPoint(
          latitude: 0.5 + (i * 6.5) / 111195.07973436875,
          longitude: 0.5 + (i.isEven ? 4 : -4) / 111178.1,
          capturedAt: t0.add(Duration(seconds: i * 5)),
        ),
    ];
    final sigma = KinematicPolicy.observedMovingSigma(points)!;
    // Second differences of a ±4 m zigzag are 16 m: 16 / (1.177 · √6).
    expect(sigma, closeTo(16 / (1.1774100225154747 * 2.449489742783178), 0.2));
    expect(KinematicPolicy.observedMovingSigma(points.sublist(0, 5)), isNull);
  });
}
