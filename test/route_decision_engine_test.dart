import 'dart:math' as math;

import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/src/application/route_decision_engine.dart';
import 'package:flutter_background_location_tracker/src/domain/kinematic_policy.dart';
import 'package:flutter_background_location_tracker/src/domain/track_geodesy.dart';
import 'package:flutter_test/flutter_test.dart';

// Every scenario reproduces a failure mode of the 2026-10-24 two-phone field
// test with generated coordinates around a synthetic origin.

const _metersPerDegree = 111195.07973436875;
const _originLatitude = 0.5;
const _originLongitude = 0.5;
final _t0 = DateTime.utc(2026, 10, 24, 3);

double _lat(double north) => _originLatitude + north / _metersPerDegree;
double _lon(double east) =>
    _originLongitude +
    east / (_metersPerDegree * math.cos(_originLatitude * math.pi / 180));

ActivitySnapshot _reading(
  TrackingActivityType type,
  int confidence,
  DateTime at, {
  String source = 'android_activity_recognition',
}) =>
    ActivitySnapshot(
      type: type,
      confidence: confidence,
      recordedAt: at,
      source: source,
    );

LocationSample _fix(
  int seconds, {
  required double east,
  double north = 0,
  double accuracy = 5,
  double? speed,
  double? speedAccuracy,
  bool gnss = true,
  ActivitySnapshot? activity,
}) {
  final at = _t0.add(Duration(seconds: seconds));
  return LocationSample(
    latitude: _lat(north),
    longitude: _lon(east),
    capturedAt: at,
    horizontalAccuracy: accuracy,
    verticalAccuracy: gnss ? 3 : null,
    speed: speed,
    speedAccuracy: speedAccuracy,
    provider: 'fused',
    capturedActivity: activity,
    nativeReceivedAt: at.add(const Duration(milliseconds: 200)),
    providerTimeDeltaMsAtReceipt: 200,
    mockDetectionAvailable: true,
  );
}

/// Feeds fixes to an engine and stores them as a repository would.
final class _Route {
  _Route({TrackingConfig? config, this.segmentStartedAt})
      : config = config ?? const TrackingConfig(),
        engine = RouteDecisionEngine(config ?? const TrackingConfig());

  final TrackingConfig config;
  final DateTime? segmentStartedAt;
  RouteDecisionEngine engine;
  final points = <TrackPoint>[];
  final steps = <DecisionStep>[];
  final stops = <TrackStop>[];

  TrackStop? get openStop {
    final last = stops.isEmpty ? null : stops.last;
    return last != null && last.isOpen ? last : null;
  }

  TrackPoint add(LocationSample sample) {
    final step = engine.decide(
      sample,
      segmentId: 'segment',
      segmentStartedAt: segmentStartedAt,
      readings: sample.activityReadings,
    );
    final point = _stored(sample, step, points.length + 1);
    engine.commit(step, point);
    points.add(point);
    steps.add(step);
    _apply(step.stopChange, point);
    return point;
  }

  /// Rebuilds the engine from every stored point, as after a restart.
  void restart() {
    engine = RouteDecisionEngine(config)
      ..restore(
        tail: points.map(RouteDecisionInputs.restoredFix).toList(),
        segmentId: 'segment',
        segmentStartedAt: segmentStartedAt,
        openStop: openStop,
      );
  }

  void _apply(TrackStopChange? change, TrackPoint point) {
    TrackStop stop({
      required String kind,
      required double latitude,
      required double longitude,
      required double sigma,
      required double radius,
      required DateTime startedAt,
      required DateTime lastSeenAt,
      DateTime? endedAt,
      required int evidence,
    }) =>
        TrackStop(
          id: 'stop-${stops.length}',
          trackId: 'track',
          segmentId: 'segment',
          kind: kind,
          latitude: latitude,
          longitude: longitude,
          centreSigmaMeters: sigma,
          radiusMeters: radius,
          startedAt: startedAt,
          lastSeenAt: lastSeenAt,
          endedAt: endedAt,
          evidenceCount: evidence,
          qualityPolicyVersion: 5,
        );
    switch (change) {
      case TrackStopOpen():
        stops.add(
          stop(
            kind: change.kind,
            latitude: change.latitude,
            longitude: change.longitude,
            sigma: change.centreSigmaMeters,
            radius: change.radiusMeters,
            startedAt: change.startedAt,
            lastSeenAt: point.capturedAt,
            evidence: change.priorEvidenceCount + 1,
          ),
        );
      case TrackStopRecord():
        stops.add(
          stop(
            kind: change.kind,
            latitude: change.latitude,
            longitude: change.longitude,
            sigma: change.centreSigmaMeters,
            radius: change.radiusMeters,
            startedAt: change.startedAt,
            lastSeenAt: change.lastSeenAt,
            endedAt: point.capturedAt,
            evidence: change.evidenceCount,
          ),
        );
      case TrackStopExtend():
        final open = openStop!;
        stops[stops.length - 1] = stop(
          kind: open.kind,
          latitude: open.latitude,
          longitude: open.longitude,
          sigma: open.centreSigmaMeters,
          radius: open.radiusMeters,
          startedAt: open.startedAt,
          lastSeenAt: point.capturedAt,
          evidence: open.evidenceCount + 1,
        );
      case TrackStopClose(departure: final departure):
        final open = openStop!;
        stops[stops.length - 1] = stop(
          kind: open.kind,
          latitude: open.latitude,
          longitude: open.longitude,
          sigma: open.centreSigmaMeters,
          radius: open.radiusMeters,
          startedAt: open.startedAt,
          lastSeenAt: open.lastSeenAt,
          endedAt: departure ? point.capturedAt : open.lastSeenAt,
          evidence: open.evidenceCount,
        );
      case null:
        break;
    }
  }

  double get acceptedLength {
    final accepted = points.where((point) => point.accepted).toList();
    var length = 0.0;
    for (var i = 1; i < accepted.length; i += 1) {
      length += TrackGeodesy.sphericalHaversineMeters(
        accepted[i - 1].latitude,
        accepted[i - 1].longitude,
        accepted[i].latitude,
        accepted[i].longitude,
      );
    }
    return length;
  }
}

TrackPoint _stored(LocationSample sample, DecisionStep step, int sequence) =>
    TrackPoint(
      id: 'point-$sequence',
      trackId: 'track',
      segmentId: 'segment',
      sequence: sequence,
      latitude: sample.latitude,
      longitude: sample.longitude,
      horizontalAccuracy: sample.horizontalAccuracy,
      verticalAccuracy: sample.verticalAccuracy,
      speed: sample.speed,
      speedAccuracy: sample.speedAccuracy,
      capturedAt: sample.capturedAt,
      persistedAt: sample.capturedAt,
      activityType:
          sample.capturedActivity?.type ?? TrackingActivityType.unknown,
      activityConfidence: sample.capturedActivity?.confidence ?? 0,
      activitySource: sample.capturedActivity?.source,
      activityEvidenceState: sample.capturedActivity?.evidenceState ??
          ActivityEvidenceState.unavailable,
      activityRecordedAt: sample.capturedActivity?.recordedAt,
      activityReadings: sample.activityReadings,
      motionState: MotionState.unknown,
      provider: sample.provider,
      isMocked: false,
      mockDetectionAvailable: true,
      nativeReceivedAt: sample.nativeReceivedAt,
      providerTimeDeltaMsAtReceipt: sample.providerTimeDeltaMsAtReceipt,
      accepted: step.decision.acceptedForGeometry,
      qualityFlags: step.decision.qualityFlags,
      rejectionReason: step.decision.rejectionReason,
      qualityPolicyVersion: 5,
    );

/// Walks east at [speed] m/s from [fromEast] with a fix every [every]
/// seconds and a fresh walking reading on each fix.
List<LocationSample> _walk(
  int startSecond,
  int count, {
  double fromEast = 0,
  double north = 0,
  double speed = 1.25,
  int every = 6,
  double speedAccuracy = 0.2,
  bool readings = true,
}) =>
    <LocationSample>[
      for (var i = 0; i < count; i += 1)
        _fix(
          startSecond + i * every,
          east: fromEast + i * every * speed,
          north: north,
          speed: speed,
          speedAccuracy: speedAccuracy,
          activity: readings
              ? _reading(
                  TrackingActivityType.walking,
                  95,
                  _t0.add(Duration(seconds: startSecond + i * every)),
                )
              : null,
        ),
    ];

void main() {
  test('a re-acquisition excursion after a silence is held back (walk 09:08)',
      () {
    final route = _Route();
    // Walk 60 m, arrive, fall silent for 29 s.
    final arrival = _walk(0, 9, fromEast: -60);
    arrival.forEach(route.add);
    final arrivedAt = 48;
    // Three degraded fixes 100–140 m away, mutually consistent.
    final excursion = <LocationSample>[
      _fix(arrivedAt + 29,
          east: -93,
          north: 32,
          accuracy: 5.8,
          speed: 0.51,
          speedAccuracy: 11.1),
      _fix(arrivedAt + 35,
          east: -125,
          north: 35,
          accuracy: 6.8,
          speed: 3.58,
          speedAccuracy: 7.1),
      _fix(arrivedAt + 41,
          east: -133,
          north: 24,
          accuracy: 10.9,
          speed: 2.81,
          speedAccuracy: 5.8),
    ];
    for (final fix in excursion) {
      final point = route.add(fix);
      expect(point.accepted, isFalse);
      expect(point.rejectionReason, KinematicPolicy.kinematicOutlierReason);
    }
    // The true place: fixes within 20 m for 2.5 minutes, no moving readings.
    for (var i = 0; i < 9; i += 1) {
      final point = route.add(
        _fix(
          arrivedAt + 48 + i * 18,
          east: (i.isEven ? -6.0 : 8.0) + i * 0.3,
          north: i.isEven ? 4.0 : -3.0,
          accuracy: 4.5,
          speed: 0.15,
          speedAccuracy: i.isEven ? 2.9 : 1.8,
          activity: _reading(
            TrackingActivityType.unknown,
            40,
            _t0.add(Duration(seconds: arrivedAt + 48 + i * 18)),
          ),
        ),
      );
      expect(point.accepted, isFalse, reason: 'held at the place');
      expect(point.rejectionReason, FixQualityIssue.stationaryHold);
    }
    expect(route.stops, hasLength(1));
    expect(route.openStop, isNotNull);
    // Walk on: the departure leaves the radius with a measured speed.
    final departAt = arrivedAt + 48 + 9 * 18;
    final onward = _walk(departAt, 10, fromEast: 0);
    final points = onward.map(route.add).toList();
    expect(points.where((point) => point.accepted), isNotEmpty);
    expect(route.openStop, isNull, reason: 'the departure closed the stop');
    // No excursion in the route: about 60 m in and about 70 m out.
    expect(route.acceptedLength, lessThan(160));
  });

  test(
      'a wrong first fix after an outage re-anchors on the agreeing fixes '
      '(goldhunga 09:55)', () {
    final route = _Route();
    for (var i = 0; i < 12; i += 1) {
      route.add(
        _fix(i * 5, east: i * 40.0, speed: 8, speedAccuracy: 1.0, accuracy: 4),
      );
    }
    // 335 s without fixes; the device moved about 150 m on and slowed down.
    const last = 55;
    final wrong = route.add(
      _fix(last + 335,
          east: 440 - 135, accuracy: 5.8, speed: 0, speedAccuracy: 3.2),
    );
    expect(wrong.accepted, isFalse);
    final far = route.add(
      _fix(last + 342,
          east: 440 + 150, accuracy: 6.3, speed: 0.36, speedAccuracy: 2.3),
    );
    expect(far.accepted, isFalse, reason: 'it disagrees with the wrong fix');
    final agreeing = route.add(
      _fix(last + 348,
          east: 440 + 168, accuracy: 4.7, speed: 0.31, speedAccuracy: 2.5),
    );
    expect(agreeing.accepted, isTrue,
        reason: 'usable and agrees with the last suspect');
    // No 135 m detour: the route goes on from the last good fix.
    expect(route.acceptedLength, lessThan(440 + 168 + 25));
  });

  test('a tunnel exit with a precise Doppler speed is accepted at once', () {
    final route = _Route();
    for (var i = 0; i < 8; i += 1) {
      route.add(_fix(i * 5, east: i * 50.0, speed: 10, speedAccuracy: 0.8));
    }
    final exit = route.add(
      _fix(35 + 60, east: 350 + 600, speed: 10, speedAccuracy: 0.8),
    );
    expect(exit.accepted, isTrue);
  });

  test('a tunnel exit with a broken Doppler speed is accepted within 30 s', () {
    final route = _Route();
    for (var i = 0; i < 8; i += 1) {
      route.add(_fix(i * 5, east: i * 50.0, speed: 10, speedAccuracy: 0.8));
    }
    DateTime? firstAccepted;
    for (var i = 0; i < 10; i += 1) {
      final point = route.add(
        _fix(95 + i * 5, east: 950 + i * 50.0, speed: 10, speedAccuracy: 6),
      );
      if (point.accepted) {
        firstAccepted = point.capturedAt;
        break;
      }
    }
    expect(firstAccepted, isNotNull);
    expect(
      firstAccepted!.difference(_t0.add(const Duration(seconds: 95))),
      lessThanOrEqualTo(const Duration(seconds: 35)),
    );
  });

  test('pocket sway inside the radius never ends a pause (mulpani 15:59)', () {
    final route = _Route();
    _walk(0, 6, fromEast: -40).forEach(route.add);
    // The last walking reading is at 30 s; Activity Recognition lags for up
    // to 30 s after a stop, during which fixes still move the route.
    final afterLag = <TrackPoint>[];
    for (var i = 0; i < 14; i += 1) {
      final second = 36 + i * 12;
      final point = route.add(
        _fix(
          second,
          east: (i % 3) * 2.0 - 2,
          north: (i % 2) * 3.0,
          accuracy: 4.5,
          speed: i.isEven ? 0.75 : 0.64,
          speedAccuracy: i.isEven ? 0.24 : 0.30,
          activity: _reading(
            TrackingActivityType.unknown,
            40,
            _t0.add(Duration(seconds: second)),
          ),
        ),
      );
      if (second > 30 + 30) afterLag.add(point);
    }
    expect(
      afterLag.where((point) => point.accepted),
      isEmpty,
      reason: 'a 0.64-0.75 m/s pocket-sway speed measured to 0.24-0.30 m/s '
          'has a lower bound below 0.4 m/s: it never ends the pause',
    );
    expect(route.stops, hasLength(1), reason: 'two quiet minutes make a stop');
  });

  test(
      'one walking reading inside the radius keeps the pause; confirmed '
      'activity outside it departs', () {
    final route = _Route();
    _walk(0, 5, fromEast: -30).forEach(route.add);
    // Quiet at the place once Activity Recognition caught up (readings at
    // 0-24 s), then a lone walking reading 10 m out, inside the radius.
    for (final second in <int>[60, 75, 90]) {
      final quiet = route.add(_fix(second,
          east: 2,
          accuracy: 4,
          speed: 0.1,
          speedAccuracy: 1.5,
          activity: _reading(TrackingActivityType.unknown, 40,
              _t0.add(Duration(seconds: second)))));
      expect(quiet.accepted, isFalse);
    }
    final lone = route.add(_fix(105,
        east: 10,
        accuracy: 4,
        speed: 0.25,
        speedAccuracy: 1.5,
        activity: _reading(TrackingActivityType.walking, 87,
            _t0.add(const Duration(seconds: 105)))));
    expect(lone.accepted, isFalse, reason: 'one reading never ends a stay');
    // Walking away with readings but an imprecise Doppler speed: confirmed
    // activity on the second consecutive outside fix, farther out.
    final away = <TrackPoint>[
      for (var i = 0; i < 4; i += 1)
        route.add(_fix(120 + i * 6,
            east: 30.0 + i * 8,
            accuracy: 4,
            speed: 1.2,
            speedAccuracy: 1.5,
            activity: _reading(TrackingActivityType.walking, 95,
                _t0.add(Duration(seconds: 120 + i * 6))))),
    ];
    expect(away.first.accepted, isFalse);
    expect(away.any((point) => point.accepted), isTrue);
  });

  test(
      'a still stop with a secondary cluster stays one stop (bhotechaur 18:07)',
      () {
    final route = _Route();
    _walk(0, 5, fromEast: -30).forEach(route.add);
    var second = 30;
    ActivitySnapshot still(int at) => _reading(
        TrackingActivityType.stationary, 99, _t0.add(Duration(seconds: at)));
    // A confirmed still stop.
    for (var i = 0; i < 10; i += 1) {
      route.add(_fix(second,
          east: i.isEven ? 3 : -2,
          north: i.isEven ? -2 : 2,
          accuracy: 4,
          speed: 0.05,
          speedAccuracy: 0.2,
          activity: still(second)));
      second += 20;
    }
    expect(route.openStop, isNotNull);
    // Fixes flip to a cluster 120 m away with an optimistic accuracy and a
    // zero placeholder speed, while the phone lies still.
    for (var i = 0; i < 8; i += 1) {
      final secondary = i.isEven;
      final point = route.add(_fix(second,
          east: secondary ? 115 : 1,
          north: secondary ? 31 : 1,
          accuracy: secondary ? 6.2 : 5,
          speed: 0,
          speedAccuracy: 2.0,
          activity: still(second)));
      expect(point.accepted, isFalse, reason: 'no departure at $second s');
      second += 20;
    }
    expect(route.stops, hasLength(1));
    expect(route.openStop, isNotNull);
  });

  test(
      'a crawl with one GNSS fix and a network fix is no stop (bhotechaur 16:07)',
      () {
    final route = _Route();
    for (var i = 0; i < 6; i += 1) {
      route.add(_fix(i * 5,
          east: i * 25.0,
          speed: 5,
          speedAccuracy: 1.2,
          activity: _reading(TrackingActivityType.inVehicle, 96,
              _t0.add(Duration(seconds: i * 5)))));
    }
    route.add(_fix(31, east: 128, speed: 0, speedAccuracy: 1.4));
    route.add(_fix(80,
        east: 122,
        north: -8,
        accuracy: 3.7,
        speed: 0.1,
        speedAccuracy: 0.6,
        activity: _reading(TrackingActivityType.stationary, 42,
            _t0.add(const Duration(seconds: 80)))));
    // Four minutes later a network fix (no speed or vertical accuracy).
    route.add(_fix(305, east: 100, north: -3, accuracy: 16.8, gnss: false));
    // After the silence the first far fix waits for one that agrees with it.
    final first = route.add(_fix(343,
        east: 128 + 290,
        speed: 3.68,
        speedAccuracy: 1.7,
        activity: _reading(TrackingActivityType.inVehicle, 92,
            _t0.add(const Duration(seconds: 343)))));
    expect(first.accepted, isFalse);
    final departure = route.add(_fix(348,
        east: 128 + 309,
        speed: 3.85,
        speedAccuracy: 1.4,
        activity: _reading(TrackingActivityType.inVehicle, 92,
            _t0.add(const Duration(seconds: 348)))));
    expect(departure.accepted, isTrue);
    expect(route.stops, isEmpty);
    expect(route.steps.last.stayExplainsGap, isFalse,
        reason: 'the gap stays visible: nothing shows the vehicle stayed');
  });

  test(
      'without any evidence a walk keeps its fixes and two confined minutes '
      'make a stop', () {
    final route = _Route();
    final walk = _walk(0, 12, speed: 1, every: 5, readings: false)
        .map((fix) => _fix(
              fix.capturedAt.difference(_t0).inSeconds,
              east: _eastOf(fix),
            ))
        .toList();
    final walked = walk.map(route.add).toList();
    expect(walked.every((point) => point.accepted), isTrue);
    for (var i = 0; i < 30; i += 1) {
      route.add(
          _fix(60 + i * 5, east: 55 + (i % 3) * 1.5, north: (i % 2) * 2.0));
    }
    expect(route.stops, hasLength(1));
  });

  test('a stay at the start of a segment counts from when recording began', () {
    final startedAt = _t0;
    final route = _Route(segmentStartedAt: startedAt);
    for (var i = 0; i < 9; i += 1) {
      route.add(_fix(44 + i * 15,
          east: (i % 3) * 3.0,
          north: (i % 2) * 2.0,
          accuracy: i == 0 ? 14.6 : 5,
          speed: 0.1,
          speedAccuracy: 0.6,
          activity: _reading(TrackingActivityType.unknown, 40,
              _t0.add(Duration(seconds: 44 + i * 15)))));
    }
    expect(route.stops, hasLength(1));
    expect(route.stops.single.startedAt, startedAt);
  });

  test(
      'a measured standstill starts a stay before the walking readings catch '
      'up, and a stay left just before the first fix after a silence is a '
      'stop (goldhunga 11:49)', () {
    final route = _Route();
    _walk(0, 13, fromEast: -156, speed: 1.3, every: 10).forEach(route.add);
    // 10 s after the last walking fix and reading, 7 m on: 0.12 ± 0.14 m/s.
    final still = route.add(_fix(130,
        east: 7,
        speed: 0.12,
        speedAccuracy: 0.14,
        activity: _reading(TrackingActivityType.unknown, 40,
            _t0.add(const Duration(seconds: 130)))));
    expect(still.accepted, isFalse,
        reason: 'the standstill is newer than the readings');
    expect(still.rejectionReason, FixQualityIssue.stationaryHold);
    // 202 s without fixes, then a ride 55 m from the place at 6.27 m/s.
    final departure = route.add(_fix(332,
        east: 55,
        accuracy: 3.8,
        speed: 6.27,
        speedAccuracy: 1.09,
        activity: _reading(TrackingActivityType.inVehicle, 100,
            _t0.add(const Duration(seconds: 325)))));
    expect(departure.accepted, isTrue);
    expect(route.steps.last.stopChange, isA<TrackStopRecord>());
    final stop = route.stops.single;
    expect(stop.startedAt, _t0.add(const Duration(seconds: 120)));
    expect(stop.endedAt, departure.capturedAt);
    expect(route.steps.last.stayExplainsGap, isTrue);
  });

  test(
      'a stay after a silence that followed a moving fix counts its two '
      'minutes from the fixes after the silence (goldhunga 11:04)', () {
    final route = _Route();
    for (var i = 0; i < 6; i += 1) {
      route.add(_fix(i * 5,
          east: -180 + i * 30.0,
          speed: 6,
          speedAccuracy: 1.1,
          activity: _reading(TrackingActivityType.inVehicle, 96,
              _t0.add(Duration(seconds: i * 5)))));
    }
    // The last fix still moves; then 38 s without fixes.
    route.add(_fix(30,
        east: 0,
        accuracy: 2,
        speed: 1.61,
        speedAccuracy: 1.6,
        activity: _reading(TrackingActivityType.unknown, 40,
            _t0.add(const Duration(seconds: 30)))));
    // 52 s standing at the place, then a slow walk back with readings.
    for (final (second, east) in <(int, double)>[
      (68, 2),
      (78, -2),
      (113, 1),
      (120, -1)
    ]) {
      final point = route.add(_fix(second,
          east: east,
          accuracy: 2,
          speed: 0.6,
          speedAccuracy: 0.6,
          activity: _reading(TrackingActivityType.unknown, 40,
              _t0.add(Duration(seconds: second)))));
      expect(point.accepted, isFalse);
    }
    for (var i = 0; i < 7; i += 1) {
      route.add(_fix(127 + i * 10,
          east: -4 - i * 6.0,
          accuracy: 4.5,
          speed: 0.6,
          speedAccuracy: 0.2,
          activity: _reading(TrackingActivityType.walking, 92,
              _t0.add(Duration(seconds: 127 + i * 10)))));
    }
    expect(route.stops, isEmpty,
        reason: 'under a minute and a half since the silence: no stop');
    expect(route.points.last.accepted, isTrue,
        reason: 'the walk left the pause');
  });

  test(
      'a stay that becomes a stop as it is left explains its silent gap as a '
      'stop (bhotechaur 13:25)', () {
    final route = _Route();
    for (var i = 0; i < 6; i += 1) {
      route.add(_fix(i * 5,
          east: -150 + i * 30.0,
          speed: 6,
          speedAccuracy: 1.0,
          activity: _reading(TrackingActivityType.inVehicle, 96,
              _t0.add(Duration(seconds: i * 5)))));
    }
    for (final second in <int>[45, 60, 80, 95, 110]) {
      route.add(_fix(second,
          east: (second % 3) - 1.0,
          accuracy: 4,
          speed: 0.1,
          speedAccuracy: 0.3,
          activity: _reading(TrackingActivityType.unknown, 40,
              _t0.add(Duration(seconds: second)))));
    }
    expect(route.stops, isEmpty, reason: 'not yet two minutes');
    // 130 s later a ride 213 m away at 8.3 m/s.
    final departure = route.add(_fix(240,
        east: 213,
        accuracy: 4.8,
        speed: 8.3,
        speedAccuracy: 0.13,
        activity: _reading(TrackingActivityType.inVehicle, 96,
            _t0.add(const Duration(seconds: 235)))));
    expect(departure.accepted, isTrue);
    expect(route.steps.last.stopChange, isA<TrackStopRecord>());
    expect(route.steps.last.stayExplainsGap, isTrue,
        reason: '188 m beyond the radius at 8.3 m/s took 23 s: the stop '
            'explains the silence');
  });

  test(
      'a measured standstill outside a pause blocks an exit on lagging '
      'readings (bhotechaur 15:05)', () {
    final route = _Route();
    _walk(0, 5, fromEast: -30).forEach(route.add);
    for (final second in <int>[60, 75, 90]) {
      final quiet = route.add(_fix(second,
          east: 2,
          accuracy: 4,
          speed: 0.1,
          speedAccuracy: 1.5,
          activity: _reading(TrackingActivityType.unknown, 40,
              _t0.add(Duration(seconds: second)))));
      expect(quiet.accepted, isFalse);
    }
    final out = route.add(_fix(110,
        east: 30,
        accuracy: 10,
        speed: 0.81,
        speedAccuracy: 0.61,
        activity: _reading(TrackingActivityType.walking, 100,
            _t0.add(const Duration(seconds: 109)),
            source: 'android_activity_transition')));
    expect(out.rejectionReason, FixQualityIssue.stationaryOutlier);
    final standing = route.add(_fix(131,
        east: 33,
        accuracy: 4,
        speed: 0.09,
        speedAccuracy: 0.11,
        activity: _reading(TrackingActivityType.unknown, 40,
            _t0.add(const Duration(seconds: 122)))));
    expect(standing.accepted, isFalse,
        reason: 'a 0.09 ± 0.11 m/s fix is standing, whatever the readings say');
    expect(standing.rejectionReason, FixQualityIssue.stationaryOutlier);
    expect(route.engine.stayCurrent, isTrue);
  });

  test(
      'confirmed walking with a measured speed ends a pause inside its '
      'radius, so the walk on keeps its vertices (slow stroll)', () {
    final route = _Route();
    _walk(0, 6, fromEast: -30, speed: 1, every: 5).forEach(route.add);
    // Standing: a precise Doppler speed shows the device still at once.
    final standing = route.add(_fix(40,
        east: -4,
        speed: 0.1,
        speedAccuracy: 0.2,
        activity: _reading(TrackingActivityType.unknown, 40,
            _t0.add(const Duration(seconds: 40)))));
    expect(standing.rejectionReason, FixQualityIssue.stationaryHold);
    // Walking on, still inside the 25 m radius.
    final onward = <TrackPoint>[
      for (var i = 0; i < 4; i += 1)
        route.add(_fix(80 + i * 5,
            east: (i + 1) * 5.0,
            speed: 1,
            speedAccuracy: 0.22,
            activity: _reading(TrackingActivityType.walking, 92,
                _t0.add(Duration(seconds: 80 + i * 5))))),
    ];
    expect(onward.first.accepted, isFalse, reason: 'one reading is not enough');
    expect(onward[1].accepted, isTrue, reason: 'confirmed by a second reading');
    expect(onward.skip(1).every((point) => point.accepted), isTrue);
    expect(route.stops, isEmpty);
  });

  test(
      'a fix after a long silence inside the radius makes the stay a stop '
      'before its walking can end it (bhotechaur 18:16)', () {
    final route = _Route();
    _walk(0, 5, fromEast: -30).forEach(route.add);
    for (final second in <int>[55, 87, 97, 157]) {
      route.add(_fix(second,
          east: (second % 3) - 1.0,
          accuracy: 6,
          speed: 0.1,
          speedAccuracy: 1.5,
          activity: _reading(TrackingActivityType.unknown, 40,
              _t0.add(Duration(seconds: second)))));
    }
    expect(route.stops, isEmpty);
    // Sixteen minutes without fixes; then a walking transition and a walking
    // fix 9 m from the place.
    final walking = route.add(_fix(1150,
        east: 9,
        accuracy: 6,
        speed: 0.88,
        speedAccuracy: 0.22,
        activity: _reading(TrackingActivityType.walking, 100,
            _t0.add(const Duration(seconds: 1149)),
            source: 'android_activity_transition')));
    expect(walking.accepted, isFalse);
    expect(route.steps.last.stopChange, isA<TrackStopOpen>());
    expect(route.openStop, isNotNull,
        reason: 'walking inside a stop is part of it');
    // The ride away ends it.
    final away = <TrackPoint>[
      for (var i = 0; i < 3; i += 1)
        route.add(_fix(1260 + i * 5,
            east: 40.0 + i * 30,
            speed: 6,
            speedAccuracy: 1,
            activity: _reading(TrackingActivityType.inVehicle, 96,
                _t0.add(Duration(seconds: 1260 + i * 5))))),
    ];
    expect(away.any((point) => point.accepted), isTrue);
    expect(route.openStop, isNull);
    expect(route.stops.single.endedAt, isNotNull);
  });

  test('a restart after any fix rebuilds the same decisions', () {
    List<LocationSample> scenario() => <LocationSample>[
          ..._walk(0, 9, fromEast: -60),
          _fix(77,
              east: -93,
              north: 32,
              accuracy: 5.8,
              speed: 0.51,
              speedAccuracy: 11.1),
          _fix(83,
              east: -125,
              north: 35,
              accuracy: 6.8,
              speed: 3.58,
              speedAccuracy: 7.1),
          for (var i = 0; i < 9; i += 1)
            _fix(96 + i * 18,
                east: (i.isEven ? -6.0 : 8.0),
                north: i.isEven ? 4.0 : -3.0,
                accuracy: 4.5,
                speed: 0.15,
                speedAccuracy: 1.8,
                activity: _reading(TrackingActivityType.unknown, 40,
                    _t0.add(Duration(seconds: 96 + i * 18)))),
          ..._walk(258, 10, fromEast: 0),
        ];
    final straight = _Route();
    scenario().forEach(straight.add);
    String decisions(_Route route) => route.points
        .map((point) => '${point.accepted}/${point.rejectionReason}')
        .join(',');
    for (final restartEvery in <int>[1, 3, 7]) {
      final restarted = _Route();
      final fixes = scenario();
      for (var i = 0; i < fixes.length; i += 1) {
        if (i > 0 && i % restartEvery == 0) restarted.restart();
        restarted.add(fixes[i]);
      }
      expect(decisions(restarted), decisions(straight),
          reason: 'restart every $restartEvery');
      expect(restarted.stops.length, straight.stops.length);
    }
  });
}

double _eastOf(LocationSample fix) =>
    (fix.longitude - _originLongitude) *
    _metersPerDegree *
    math.cos(_originLatitude * math.pi / 180);
