/// Pure-Dart fakes for host unit and widget tests.
///
/// Import this library only from tests. The production package does not depend
/// on a platform channel, database, filesystem, map, or state-management
/// library when these fakes are used.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'flutter_background_location_tracker.dart';
import 'package:path/path.dart' as path_util;
import 'package:sqflite/sqflite.dart';

import 'src/storage/sqlite_track_repository.dart';

/// A wall and monotonic clock that advances only when the test asks it to.
final class DeterministicTrackingClock {
  DeterministicTrackingClock({
    DateTime? initialTime,
    int initialMonotonicNanos = 0,
  })  : _now = (initialTime ?? DateTime.utc(2026)).toUtc(),
        _monotonicNanos = initialMonotonicNanos;

  DateTime _now;
  int _monotonicNanos;

  DateTime call() => _now;
  int monotonicNanos() => _monotonicNanos;

  void advance(Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'Cannot go backwards.');
    }
    _now = _now.add(duration);
    _monotonicNanos += duration.inMicroseconds * 1000;
  }
}

/// Temporary canonical database fixture. Pass an FFI database factory in pure
/// Dart tests or the platform factory in integration tests.
final class TemporaryTrackRepositoryFixture {
  TemporaryTrackRepositoryFixture._(this.directory, this.repository);

  final Directory directory;
  final SqliteTrackRepository repository;

  static Future<TemporaryTrackRepositoryFixture> create({
    required DatabaseFactory databaseFactory,
    DateTime Function()? clock,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'flutter_background_location_tracker_test_',
    );
    final repository = SqliteTrackRepository(
      path: path_util.join(directory.path, 'tracks.sqlite'),
      databaseFactoryOverride: databaseFactory,
      clock: clock,
      singleInstance: false,
    );
    await repository.initialize();
    return TemporaryTrackRepositoryFixture._(directory, repository);
  }

  Future<void> dispose() async {
    await repository.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

/// Generated route samples around a synthetic origin, never a participant's
/// real trace.
final class SyntheticTrackingRoute {
  const SyntheticTrackingRoute(this.locations, this.activities);

  final List<LocationSample> locations;
  final List<ActivitySnapshot> activities;

  factory SyntheticTrackingRoute.walking({
    int pointCount = 20,
    DateTime? startedAt,
  }) {
    final start = (startedAt ?? DateTime.utc(2026)).toUtc();
    return SyntheticTrackingRoute(
      List<LocationSample>.generate(
        pointCount,
        (index) => LocationSample(
          latitude: index * 0.00001,
          longitude: index * 0.00001,
          horizontalAccuracy: 5,
          capturedAt: start.add(Duration(seconds: index * 5)),
          provider: 'synthetic',
          eventId: 'synthetic-$index',
          mockDetectionAvailable: false,
        ),
        growable: false,
      ),
      <ActivitySnapshot>[
        ActivitySnapshot(
          type: TrackingActivityType.walking,
          confidence: 90,
          recordedAt: start,
        ),
      ],
    );
  }

  factory SyntheticTrackingRoute.stationary({
    int pointCount = 20,
    DateTime? startedAt,
  }) {
    final start = (startedAt ?? DateTime.utc(2026)).toUtc();
    return SyntheticTrackingRoute(
      List<LocationSample>.generate(
        pointCount,
        (index) => LocationSample(
          latitude: (index.isEven ? 1 : -1) * 0.000001,
          longitude: (index % 3 - 1) * 0.000001,
          horizontalAccuracy: 8,
          capturedAt: start.add(Duration(seconds: index * 15)),
          provider: 'synthetic',
          eventId: 'stationary-$index',
          mockDetectionAvailable: false,
        ),
        growable: false,
      ),
      <ActivitySnapshot>[
        ActivitySnapshot(
          type: TrackingActivityType.stationary,
          confidence: 95,
          recordedAt: start,
        ),
      ],
    );
  }

  /// A long indoor stop with the error pattern of a 2026-10-18 field test.
  ///
  /// GNSS fixes wander several metres around the stop while reporting two to
  /// four metres of accuracy, about one fix in seven is a fused fix reporting
  /// 13 to 19 metres without Doppler, and the provider delivers a fix only
  /// after five metres of apparent movement. Periodic still readings arrive
  /// every five seconds with unknown, tilting, low-confidence and one spurious
  /// in-vehicle dip. Seeded; [origin] is a synthetic coordinate.
  factory SyntheticTrackingRoute.indoorStop({
    Duration duration = const Duration(minutes: 30),
    DateTime? startedAt,
    ({double latitude, double longitude}) origin = syntheticOrigin,
    int seed = 1,
    String eventPrefix = 'indoor-stop',
    String? trackId,
  }) {
    final start = (startedAt ?? DateTime.utc(2026)).toUtc();
    final random = math.Random(seed);
    final noise = _GaussMarkovNoise(random, sigmaMeters: 4.5, tauSeconds: 30);
    final activities = <ActivitySnapshot>[];
    final locations = <LocationSample>[];
    ActivitySnapshot? latest;
    (double, double)? delivered;
    final spuriousVehicleAt = duration.inSeconds ~/ 4 ~/ 5 * 5;
    for (var second = 0; second <= duration.inSeconds; second += 1) {
      final (east, north) = noise.next();
      if (second % 5 != 0) continue;
      final at = start.add(Duration(seconds: second));
      final roll = random.nextDouble();
      latest = second == spuriousVehicleAt
          ? _periodic(TrackingActivityType.inVehicle, 71, at, 'inVehicle')
          : roll < 0.12
              ? _periodic(TrackingActivityType.unknown, 40, at, 'unknown')
              : roll < 0.16
                  ? _periodic(TrackingActivityType.unknown, 100, at, 'tilting')
                  : roll < 0.24
                      ? _periodic(
                          TrackingActivityType.stationary,
                          36 + random.nextInt(18),
                          at,
                          'still',
                        )
                      : _periodic(
                          TrackingActivityType.stationary,
                          96 + random.nextInt(5),
                          at,
                          'still',
                        );
      activities.add(latest);
      final last = delivered;
      if (last != null &&
          math.sqrt(
                  math.pow(east - last.$1, 2) + math.pow(north - last.$2, 2)) <
              5) {
        continue;
      }
      delivered = (east, north);
      final fused = random.nextDouble() < 0.15;
      locations.add(
        _syntheticFix(
          origin: origin,
          east: east,
          north: north,
          at: at,
          accuracy: fused
              ? 13 + random.nextDouble() * 6
              : 2 + random.nextDouble() * 2,
          speed: fused ? null : 0,
          speedAccuracy: fused ? null : 2 + random.nextDouble() * 3,
          verticalAccuracy: fused ? null : 3,
          activity: latest,
          eventId: '$eventPrefix-${locations.length}',
          trackId: trackId,
        ),
      );
    }
    return SyntheticTrackingRoute(locations, activities);
  }

  /// The end of a long stop, as a 2026-10-18 field test recorded it.
  ///
  /// After [silence] without any fix, while Activity Recognition stays paused
  /// on its last still reading, comes a coarse network fix and then about a
  /// minute of GNSS re-acquisition fixes 35 to 100 metres off that report 8 to
  /// 14 metres of accuracy and an inconclusive Doppler speed, converging back
  /// to the stop. With [depart], the route then leaves at motorbike speed
  /// with a clearly measured Doppler speed. Seeded and synthetic.
  factory SyntheticTrackingRoute.reacquisitionBurst({
    DateTime? startedAt,
    Duration silence = const Duration(minutes: 90),
    ({double latitude, double longitude}) origin = syntheticOrigin,
    int seed = 2,
    bool depart = true,
    String eventPrefix = 'reacquisition',
    String? trackId,
  }) {
    final start = (startedAt ?? DateTime.utc(2026)).toUtc();
    final random = math.Random(seed);
    final burstAt = start.add(silence);
    final activities = <ActivitySnapshot>[
      _periodic(TrackingActivityType.stationary, 100, start, 'still'),
    ];
    final locations = <LocationSample>[];
    void fix(
      Duration offset,
      double east,
      double north, {
      required double accuracy,
      double? speed,
      double? speedAccuracy,
      double? verticalAccuracy = 3,
    }) {
      final at = burstAt.add(offset);
      final activity = activities.lastWhere(
        (reading) => !reading.recordedAt!.isAfter(at),
      );
      locations.add(
        _syntheticFix(
          origin: origin,
          east: east,
          north: north,
          at: at,
          accuracy: accuracy,
          speed: speed,
          speedAccuracy: speedAccuracy,
          verticalAccuracy: verticalAccuracy,
          activity: activity,
          eventId: '$eventPrefix-${locations.length}',
          trackId: trackId,
        ),
      );
    }

    fix(
      Duration.zero,
      -120,
      -158,
      accuracy: 373,
      speed: 0,
      speedAccuracy: 8.5,
      verticalAccuracy: null,
    );
    var bearing = random.nextDouble() * 2 * math.pi;
    for (var step = 1; step <= 12; step += 1) {
      if (step == 8) {
        activities.add(
          _periodic(
            TrackingActivityType.unknown,
            100,
            burstAt.add(const Duration(seconds: 38)),
            'tilting',
          ),
        );
      }
      bearing += (random.nextDouble() - 0.5) * 1.2;
      final range = 35 + random.nextDouble() * 65;
      fix(
        Duration(seconds: step * 5),
        range * math.sin(bearing),
        range * math.cos(bearing),
        accuracy: 8 + random.nextDouble() * 6,
        speed: 0,
        speedAccuracy: 3 + random.nextDouble() * 11,
      );
    }
    for (var step = 0; step < 12; step += 1) {
      final offset = Duration(seconds: 70 + step * 8);
      if (step % 2 == 0) {
        activities.add(
          _periodic(
            TrackingActivityType.unknown,
            40,
            burstAt.add(offset - const Duration(seconds: 2)),
            'unknown',
          ),
        );
      }
      final range = 2 + random.nextDouble() * 21;
      final angle = random.nextDouble() * 2 * math.pi;
      fix(
        offset,
        range * math.sin(angle),
        range * math.cos(angle),
        accuracy: 4 + random.nextDouble() * 7,
        speed: 0,
        speedAccuracy: 2 + random.nextDouble() * 2,
      );
    }
    if (depart) {
      final departAt = const Duration(seconds: 214);
      activities.add(
        _periodic(
          TrackingActivityType.unknown,
          100,
          burstAt.add(departAt - const Duration(seconds: 1)),
          'tilting',
        ),
      );
      for (var step = 0; step < 24; step += 1) {
        final offset = departAt + Duration(seconds: step * 5);
        if (step == 4 || step == 5) {
          activities.add(
            _periodic(
              TrackingActivityType.inVehicle,
              96,
              burstAt.add(offset - const Duration(seconds: 1)),
              'inVehicle',
            ),
          );
        }
        final distance = 30.0 * (step + 1);
        fix(
          offset,
          distance,
          distance * 0.25,
          accuracy: step == 0 ? 13 : 2,
          speed: 3.4 + math.min(step, 4) * 0.7,
          speedAccuracy: 1.2,
        );
      }
    }
    return SyntheticTrackingRoute(locations, activities);
  }

  /// A slow ride through a lane where the positions stop following the
  /// vehicle, as a 2026-10-18 field test recorded it.
  ///
  /// For about three minutes the fixes stay within 16 metres of the lane
  /// entrance with 4 to 14 metres of accuracy and an inconclusive Doppler
  /// speed; activity is unknown with walking and in-vehicle transitions, and a
  /// final fix catches up 96 metres away. There is no confident still
  /// evidence, so this is not a stop. Seeded and synthetic.
  factory SyntheticTrackingRoute.slowLaneRide({
    DateTime? startedAt,
    ({double latitude, double longitude}) origin = syntheticOrigin,
    int seed = 3,
    String eventPrefix = 'lane',
    String? trackId,
  }) {
    final start = (startedAt ?? DateTime.utc(2026)).toUtc();
    final random = math.Random(seed);
    final activities = <ActivitySnapshot>[];
    final locations = <LocationSample>[];
    for (var step = 0; step < 14; step += 1) {
      final at = start.add(Duration(seconds: step * 14));
      final reading = step == 6
          ? ActivitySnapshot(
              type: TrackingActivityType.walking,
              confidence: 100,
              recordedAt: at.subtract(const Duration(seconds: 1)),
              source: 'android_activity_transition',
              rawType: 'walking',
            )
          : step == 12
              ? ActivitySnapshot(
                  type: TrackingActivityType.inVehicle,
                  confidence: 100,
                  recordedAt: at.subtract(const Duration(seconds: 1)),
                  source: 'android_activity_transition',
                  rawType: 'inVehicle',
                )
              : _periodic(
                  TrackingActivityType.unknown,
                  40,
                  at.subtract(const Duration(seconds: 1)),
                  'unknown',
                );
      activities.add(reading);
      final range = random.nextDouble() * 16;
      final angle = random.nextDouble() * 2 * math.pi;
      locations.add(
        _syntheticFix(
          origin: origin,
          east: range * math.sin(angle),
          north: range * math.cos(angle),
          at: at,
          accuracy: 4 + random.nextDouble() * 10,
          speed: random.nextDouble() * 1.5,
          speedAccuracy: 1.5 + random.nextDouble() * 12.5,
          verticalAccuracy: 3,
          activity: reading,
          eventId: '$eventPrefix-${locations.length}',
          trackId: trackId,
        ),
      );
    }
    locations.add(
      _syntheticFix(
        origin: origin,
        east: -55,
        north: 79,
        at: start.add(const Duration(seconds: 13 * 14 + 16)),
        accuracy: 6.2,
        speed: 0.8,
        speedAccuracy: 8.6,
        verticalAccuracy: 3,
        activity: activities.last,
        eventId: '$eventPrefix-${locations.length}',
        trackId: trackId,
      ),
    );
    return SyntheticTrackingRoute(locations, activities);
  }

  /// A stop with the phone in a pocket, as a 2026-10-19 field test recorded
  /// it at a temple and at home.
  ///
  /// The owner stands, sits or shifts about while outdoor-grade fixes report
  /// two to five metres of accuracy and wander several metres, delivered after
  /// five metres of apparent movement, with a precise Doppler speed near
  /// zero. Activity Recognition never reports confident still: readings are
  /// unknown, tilting or low-confidence still. Seeded and synthetic.
  factory SyntheticTrackingRoute.pocketStop({
    Duration duration = const Duration(minutes: 10),
    DateTime? startedAt,
    ({double latitude, double longitude}) origin = syntheticOrigin,
    int seed = 4,
    String eventPrefix = 'pocket-stop',
    String? trackId,
  }) {
    final start = (startedAt ?? DateTime.utc(2026)).toUtc();
    final random = math.Random(seed);
    final noise = _GaussMarkovNoise(random, sigmaMeters: 5, tauSeconds: 30);
    final activities = <ActivitySnapshot>[];
    final locations = <LocationSample>[];
    (double, double)? delivered;
    for (var second = 0; second <= duration.inSeconds; second += 1) {
      final (east, north) = noise.next();
      if (second % 5 != 0) continue;
      final at = start.add(Duration(seconds: second));
      final roll = random.nextDouble();
      final reading = roll < 0.7
          ? _periodic(TrackingActivityType.unknown, 40, at, 'unknown')
          : roll < 0.9
              ? _periodic(TrackingActivityType.unknown, 100, at, 'tilting')
              : _periodic(
                  TrackingActivityType.stationary,
                  40 + random.nextInt(21),
                  at,
                  'still',
                );
      activities.add(reading);
      final last = delivered;
      if (last != null &&
          math.sqrt(
                  math.pow(east - last.$1, 2) + math.pow(north - last.$2, 2)) <
              5) {
        continue;
      }
      delivered = (east, north);
      locations.add(
        _syntheticFix(
          origin: origin,
          east: east,
          north: north,
          at: at,
          accuracy: 2.5 + random.nextDouble() * 2.5,
          speed: random.nextDouble() * 0.3,
          speedAccuracy: 0.12 + random.nextDouble() * 0.28,
          verticalAccuracy: 3,
          activity: reading,
          eventId: '$eventPrefix-${locations.length}',
          trackId: trackId,
        ),
      );
    }
    return SyntheticTrackingRoute(locations, activities);
  }

  /// Walking about inside one place, such as between rooms or around a
  /// temple courtyard: a loop of about eight metres at 0.8 m/s with on-foot
  /// readings and a precise walking Doppler speed, delivered every five metres.
  /// Part of a stop, not a journey. Seeded and synthetic.
  factory SyntheticTrackingRoute.placeWander({
    Duration duration = const Duration(minutes: 3),
    DateTime? startedAt,
    ({double latitude, double longitude}) origin = syntheticOrigin,
    int seed = 5,
    String eventPrefix = 'place-wander',
    String? trackId,
  }) {
    final start = (startedAt ?? DateTime.utc(2026)).toUtc();
    final random = math.Random(seed);
    const loopRadius = 8.0;
    const speed = 0.8;
    final activities = <ActivitySnapshot>[];
    final locations = <LocationSample>[];
    (double, double)? delivered;
    for (var second = 0; second <= duration.inSeconds; second += 1) {
      final angle = speed * second / loopRadius;
      final east = loopRadius * math.sin(angle) + (random.nextDouble() - 0.5);
      final north = loopRadius * math.cos(angle) + (random.nextDouble() - 0.5);
      final at = start.add(Duration(seconds: second));
      if (second % 5 == 0) {
        activities.add(
          _periodic(
            TrackingActivityType.walking,
            85 + random.nextInt(13),
            at,
            'onFoot',
          ),
        );
      }
      final last = delivered;
      if (last != null &&
          math.sqrt(
                  math.pow(east - last.$1, 2) + math.pow(north - last.$2, 2)) <
              5) {
        continue;
      }
      delivered = (east, north);
      locations.add(
        _syntheticFix(
          origin: origin,
          east: east,
          north: north,
          at: at,
          accuracy: 3 + random.nextDouble() * 3,
          speed: speed + (random.nextDouble() - 0.5) * 0.3,
          speedAccuracy: 0.2 + random.nextDouble() * 0.1,
          verticalAccuracy: 3,
          activity: activities.last,
          eventId: '$eventPrefix-${locations.length}',
          trackId: trackId,
        ),
      );
    }
    return SyntheticTrackingRoute(locations, activities);
  }

  /// A motorbike stop at the roadside, as a 2026-10-19 field test recorded
  /// it.
  ///
  /// The bike arrives at 6 m/s with in-vehicle readings and stops for [stop]
  /// with the phone in a jacket pocket: activity is unknown, fixes report
  /// 1.7 to 4 metres of accuracy yet scatter about 8 metres per axis, so
  /// consecutive fixes land 10 to 25 metres apart, the provider reports
  /// exactly zero speed with a speed accuracy of 0.8 to 2.4 m/s, and fixes
  /// thin out the longer the stop lasts. With [depart], the bike leaves east
  /// at 6 m/s. Seeded and synthetic.
  factory SyntheticTrackingRoute.roadsideStop({
    Duration stop = const Duration(minutes: 6),
    DateTime? startedAt,
    ({double latitude, double longitude}) origin = syntheticOrigin,
    int seed = 6,
    bool depart = true,
    String eventPrefix = 'roadside',
    String? trackId,
  }) {
    final start = (startedAt ?? DateTime.utc(2026)).toUtc();
    final random = math.Random(seed);
    final activities = <ActivitySnapshot>[];
    final locations = <LocationSample>[];
    void fix(
      DateTime at,
      double east,
      double north, {
      required double accuracy,
      required double speed,
      required double speedAccuracy,
      required ActivitySnapshot activity,
    }) =>
        locations.add(
          _syntheticFix(
            origin: origin,
            east: east,
            north: north,
            at: at,
            accuracy: accuracy,
            speed: speed,
            speedAccuracy: speedAccuracy,
            verticalAccuracy: 2,
            activity: activity,
            eventId: '$eventPrefix-${locations.length}',
            trackId: trackId,
          ),
        );

    // Arrival at 6 m/s, braking over the last ten seconds.
    const arrival = <(int, double, double)>[
      (0, -180, 6),
      (5, -150, 6),
      (10, -120, 6),
      (15, -90, 6),
      (20, -60, 6),
      (25, -30, 5.5),
      (30, -12, 3),
      (35, -3, 1.2),
    ];
    for (final (second, east, speed) in arrival) {
      final at = start.add(Duration(seconds: second));
      final reading = _periodic(
        TrackingActivityType.inVehicle,
        96,
        at.subtract(const Duration(seconds: 1)),
        'inVehicle',
      );
      activities.add(reading);
      fix(
        at,
        east,
        0,
        accuracy: 1.8,
        speed: speed,
        speedAccuracy: 1.2,
        activity: reading,
      );
    }

    // The stop: unknown readings every five seconds, scattered fixes with an
    // exactly zero speed that arrive less often as the stop goes on.
    final stopAt = start.add(const Duration(seconds: 40));
    for (var second = 0; second < stop.inSeconds; second += 5) {
      activities.add(
        _periodic(
          TrackingActivityType.unknown,
          40,
          stopAt.add(Duration(seconds: second)),
          'unknown',
        ),
      );
    }
    double gaussian() {
      final u1 = math.max(random.nextDouble(), 1e-12);
      return math.sqrt(-2 * math.log(u1)) *
          math.cos(2 * math.pi * random.nextDouble());
    }

    var offset = 5;
    while (offset < stop.inSeconds) {
      final at = stopAt.add(Duration(seconds: offset));
      fix(
        at,
        8 * gaussian(),
        8 * gaussian(),
        accuracy: 1.7 + random.nextDouble() * 2.3,
        speed: 0,
        speedAccuracy: 0.8 + random.nextDouble() * 1.6,
        activity: activities.lastWhere(
          (reading) => !reading.recordedAt!.isAfter(at),
        ),
      );
      offset +=
          offset < 120 ? 10 + random.nextInt(11) : 60 + random.nextInt(61);
    }

    if (depart) {
      final departAt = stopAt.add(stop);
      for (var step = 0; step < 12; step += 1) {
        final at = departAt.add(Duration(seconds: step * 5));
        final reading = _periodic(
          TrackingActivityType.inVehicle,
          96,
          at.subtract(const Duration(seconds: 1)),
          'inVehicle',
        );
        activities.add(reading);
        fix(
          at,
          30.0 * (step + 1),
          0,
          accuracy: 1.9,
          speed: 6,
          speedAccuracy: 1.2,
          activity: reading,
        );
      }
    }
    return SyntheticTrackingRoute(locations, activities);
  }

  /// A slow walk east with short pauses, which must keep its distance.
  ///
  /// [legs] walks of 20 to 40 metres at 1 m/s with on-foot readings and a
  /// precise walking Doppler speed, each followed by a pause of 30 to 90
  /// seconds with unknown readings and at most one jitter fix. Seeded and
  /// synthetic; the true path runs along the origin's latitude, so its length
  /// is the final fix's east offset.
  factory SyntheticTrackingRoute.slowStrollWithPauses({
    int legs = 6,
    DateTime? startedAt,
    ({double latitude, double longitude}) origin = syntheticOrigin,
    int seed = 7,
    String eventPrefix = 'stroll',
    String? trackId,
  }) {
    final start = (startedAt ?? DateTime.utc(2026)).toUtc();
    final random = math.Random(seed);
    final activities = <ActivitySnapshot>[];
    final locations = <LocationSample>[];
    var at = start;
    var east = 0.0;
    void fix({
      required double accuracy,
      required double speed,
      required double speedAccuracy,
      double north = 0,
    }) =>
        locations.add(
          _syntheticFix(
            origin: origin,
            east: east,
            north: north,
            at: at,
            accuracy: accuracy,
            speed: speed,
            speedAccuracy: speedAccuracy,
            verticalAccuracy: 3,
            activity: activities.lastWhere(
              (reading) => !reading.recordedAt!.isAfter(at),
            ),
            eventId: '$eventPrefix-${locations.length}',
            trackId: trackId,
          ),
        );

    activities.add(
      _periodic(TrackingActivityType.walking, 92, at, 'onFoot'),
    );
    fix(accuracy: 4, speed: 1, speedAccuracy: 0.25);
    for (var leg = 0; leg < legs; leg += 1) {
      final length = 20 + random.nextInt(21);
      for (var walked = 5; walked <= length; walked += 5) {
        at = at.add(const Duration(seconds: 5));
        east += 5;
        activities.add(
          _periodic(
            TrackingActivityType.walking,
            85 + random.nextInt(13),
            at.subtract(const Duration(milliseconds: 500)),
            'onFoot',
          ),
        );
        fix(
          accuracy: 3 + random.nextDouble() * 3,
          speed: 1 + (random.nextDouble() - 0.5) * 0.2,
          speedAccuracy: 0.2 + random.nextDouble() * 0.1,
        );
      }
      final pause = 30 + random.nextInt(61);
      for (var second = 5; second < pause; second += 5) {
        activities.add(
          _periodic(
            TrackingActivityType.unknown,
            40,
            at.add(Duration(seconds: second)),
            'unknown',
          ),
        );
      }
      if (random.nextBool()) {
        at = at.add(Duration(seconds: pause ~/ 2));
        fix(
          accuracy: 4,
          speed: 0.1,
          speedAccuracy: 0.2,
          north: (random.nextDouble() - 0.5) * 4,
        );
        at = at.add(Duration(seconds: pause - pause ~/ 2));
      } else {
        at = at.add(Duration(seconds: pause));
      }
    }
    return SyntheticTrackingRoute(locations, activities);
  }

  /// Synthetic origin of the field-test replicas, far from any real trace.
  static const ({double latitude, double longitude}) syntheticOrigin = (
    latitude: 0.5,
    longitude: 0.5,
  );

  /// This route followed by [next].
  SyntheticTrackingRoute followedBy(SyntheticTrackingRoute next) =>
      SyntheticTrackingRoute(
        <LocationSample>[...locations, ...next.locations],
        <ActivitySnapshot>[...activities, ...next.activities],
      );

  void emitTo(FakeTrackerAdapter adapter) {
    for (final activity in activities) {
      adapter.emitActivity(activity);
    }
    for (final location in locations) {
      adapter.emitLocation(location);
    }
  }

  /// Emits activities and locations interleaved by evidence time, the order
  /// a live device produces them.
  void emitChronologicallyTo(FakeTrackerAdapter adapter) {
    final pending = List<ActivitySnapshot>.of(activities)
      ..sort((a, b) => (a.recordedAt ?? DateTime.utc(0))
          .compareTo(b.recordedAt ?? DateTime.utc(0)));
    var next = 0;
    for (final location in locations) {
      while (next < pending.length &&
          !(pending[next].recordedAt ?? DateTime.utc(0))
              .isAfter(location.capturedAt)) {
        adapter.emitActivity(pending[next]);
        next += 1;
      }
      adapter.emitLocation(location);
    }
    for (; next < pending.length; next += 1) {
      adapter.emitActivity(pending[next]);
    }
  }

  static ActivitySnapshot _periodic(
    TrackingActivityType type,
    int confidence,
    DateTime at,
    String rawType,
  ) =>
      ActivitySnapshot(
        type: type,
        confidence: confidence,
        recordedAt: at,
        source: 'android_activity_recognition',
        rawType: rawType,
      );

  static LocationSample _syntheticFix({
    required ({double latitude, double longitude}) origin,
    required double east,
    required double north,
    required DateTime at,
    required double accuracy,
    required double? speed,
    required double? speedAccuracy,
    required double? verticalAccuracy,
    required ActivitySnapshot activity,
    required String eventId,
    required String? trackId,
  }) {
    const metersPerDegree = 111195.07973436875;
    final latitude = origin.latitude + north / metersPerDegree;
    final longitude = origin.longitude +
        east / (metersPerDegree * math.cos(origin.latitude * math.pi / 180));
    return LocationSample(
      latitude: latitude,
      longitude: longitude,
      capturedAt: at,
      horizontalAccuracy: accuracy,
      verticalAccuracy: verticalAccuracy,
      speed: speed,
      speedAccuracy: speedAccuracy,
      provider: 'fused',
      eventId: eventId,
      trackId: trackId,
      capturedActivity: activity,
      nativeReceivedAt: at.add(const Duration(milliseconds: 100)),
      providerTimeDeltaMsAtReceipt: 100,
      captureGenerationId: 'synthetic-generation',
      nativeLifecycle: TrackerLifecycle.tracking,
      mockDetectionAvailable: true,
    );
  }
}

/// Seeded first-order Gauss–Markov position error in metres, sampled at 1 Hz.
///
/// Phone errors are correlated for tens of seconds, which is why a still
/// phone's positions drift instead of scattering independently.
final class _GaussMarkovNoise {
  _GaussMarkovNoise(
    this._random, {
    required double sigmaMeters,
    required double tauSeconds,
  })  : _sigma = sigmaMeters,
        _rho = math.exp(-1 / tauSeconds);

  final math.Random _random;
  final double _sigma;
  final double _rho;
  double _east = 0;
  double _north = 0;

  (double, double) next() {
    final innovation = _sigma * math.sqrt(1 - _rho * _rho);
    _east = _rho * _east + innovation * _gaussian();
    _north = _rho * _north + innovation * _gaussian();
    return (_east, _north);
  }

  double _gaussian() {
    final u1 = math.max(_random.nextDouble(), 1e-12);
    final u2 = _random.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }
}

/// Common permission fixtures for readiness and settings tests.
abstract final class TrackingPermissionFixtures {
  static const ready = FakeTrackerAdapter.fullyReadyPermissionState;
  static const notDetermined = TrackingPermissionState(
    platform: 'fake',
    location: LocationPermissionLevel.unknown,
    locationServiceEnabled: true,
    preciseLocation: true,
    activityRecognitionGranted: false,
    notificationGranted: true,
  );
  static const foregroundOnly = TrackingPermissionState(
    platform: 'fake',
    location: LocationPermissionLevel.whileInUse,
    locationServiceEnabled: true,
    preciseLocation: true,
    activityRecognitionGranted: true,
    notificationGranted: true,
  );
  static const deniedForever = TrackingPermissionState(
    platform: 'fake',
    location: LocationPermissionLevel.deniedForever,
    locationServiceEnabled: true,
    preciseLocation: false,
    activityRecognitionGranted: false,
    notificationGranted: false,
  );
  static const servicesDisabled = TrackingPermissionState(
    platform: 'fake',
    location: LocationPermissionLevel.always,
    locationServiceEnabled: false,
    preciseLocation: true,
    activityRecognitionGranted: true,
    notificationGranted: true,
  );
}

/// In-memory export writer with optional deterministic failure injection.
final class FakeExportFileWriter implements ExportFileWriter {
  final Map<String, String> files = <String, String>{};
  Object? nextWriteError;
  Object? nextDeleteError;

  @override
  Future<String> write({
    required String fileName,
    required String contents,
    String? mimeType,
  }) async {
    final failure = nextWriteError;
    nextWriteError = null;
    if (failure != null) throw failure;
    final path = '/fake/$fileName';
    files[path] = contents;
    return path;
  }

  @override
  Future<void> delete(String path) async {
    final failure = nextDeleteError;
    nextDeleteError = null;
    if (failure != null) throw failure;
    files.remove(path);
  }
}

/// One recorded fake call with sanitized arguments.
final class FakeTrackingCall {
  const FakeTrackingCall(this.method, [this.arguments = const {}]);

  final String method;
  final Map<String, Object?> arguments;
}

/// Deterministic platform adapter for testing a real [TrackingClient].
final class FakeTrackerAdapter
    implements TrackerAdapter, StagedPermissionAdapter, NativeProtocolAdapter {
  FakeTrackerAdapter({
    this.permissionState = fullyReadyPermissionState,
    this.capabilityReport = fullySupportedCapabilityReport,
    NativeTrackingProtocol? protocol,
  }) : protocol = protocol ?? NativeTrackingProtocol.legacy();

  static const fullyReadyPermissionState = TrackingPermissionState(
    platform: 'fake',
    location: LocationPermissionLevel.always,
    locationServiceEnabled: true,
    preciseLocation: true,
    activityRecognitionGranted: true,
    notificationGranted: true,
  );

  static const fullySupportedCapabilityReport = TrackingCapabilityReport(
    platform: 'fake',
    backgroundTracking: true,
    activityRecognition: true,
    mockDetection: true,
    pauseResume: true,
    adaptiveSampling: true,
    terminatedRecovery: false,
  );

  TrackingPermissionState permissionState;
  TrackingCapabilityReport capabilityReport;
  NativeTrackingProtocol protocol;
  final List<FakeTrackingCall> calls = <FakeTrackingCall>[];
  final Map<String, Object> failures = <String, Object>{};
  final List<LocationSample> pending = <LocationSample>[];
  final StreamController<LocationSample> _locations =
      StreamController<LocationSample>.broadcast();
  final StreamController<ActivitySnapshot> _activities =
      StreamController<ActivitySnapshot>.broadcast();
  final StreamController<TrackerStatus> _statuses =
      StreamController<TrackerStatus>.broadcast();
  bool _running = false;
  String? _trackId;
  LocationSample? _lastLocation;

  @override
  Stream<LocationSample> get locationStream => _locations.stream;
  @override
  Stream<ActivitySnapshot> get activityStream => _activities.stream;
  @override
  Stream<TrackerStatus> get statusStream => _statuses.stream;

  void emitLocation(LocationSample sample, {bool durablePending = false}) {
    _lastLocation = sample;
    if (durablePending) pending.add(sample);
    _locations.add(sample);
  }

  void emitActivity(ActivitySnapshot activity) => _activities.add(activity);
  void emitStatus(TrackerStatus status) => _statuses.add(status);

  @override
  Future<void> initialize() async {
    _throwIfScheduled('initialize');
    calls.add(const FakeTrackingCall('initialize'));
  }

  @override
  Future<TrackingCapabilityReport> capabilities() async {
    calls.add(const FakeTrackingCall('capabilities'));
    return capabilityReport;
  }

  @override
  Future<TrackingPermissionState> permissions({bool request = false}) async {
    calls.add(FakeTrackingCall('permissions', <String, Object?>{
      'request': request,
    }));
    return permissionState;
  }

  @override
  Future<TrackingPermissionState> requestPermissionStep({
    required TrackingReadinessAction action,
    required int expectedReadinessRevision,
  }) async {
    calls.add(FakeTrackingCall('requestPermissionStep', <String, Object?>{
      'action': action.name,
      'expectedReadinessRevision': expectedReadinessRevision,
    }));
    return permissionState;
  }

  @override
  Future<void> start({
    required String trackId,
    required TrackingConfig config,
  }) async {
    _throwIfScheduled('start');
    calls.add(FakeTrackingCall('start', <String, Object?>{'trackId': trackId}));
    _trackId = trackId;
    _running = true;
  }

  @override
  Future<void> pause({required String trackId}) async {
    _throwIfScheduled('pause');
    calls.add(FakeTrackingCall('pause', <String, Object?>{'trackId': trackId}));
    _running = false;
  }

  @override
  Future<void> resume({
    required String trackId,
    required TrackingConfig config,
  }) async {
    _throwIfScheduled('resume');
    calls
        .add(FakeTrackingCall('resume', <String, Object?>{'trackId': trackId}));
    _trackId = trackId;
    _running = true;
  }

  @override
  Future<void> stop({required String trackId, required String reason}) async {
    _throwIfScheduled('stop');
    calls.add(FakeTrackingCall('stop', <String, Object?>{
      'trackId': trackId,
      'reason': reason,
    }));
    _trackId = null;
    _running = false;
  }

  @override
  Future<void> updateConfig({
    required String trackId,
    required TrackingConfig config,
  }) async {
    _throwIfScheduled('updateConfig');
    calls.add(
      FakeTrackingCall('updateConfig', <String, Object?>{'trackId': trackId}),
    );
  }

  @override
  Future<bool> isRunning() async => _running;

  @override
  Future<TrackerStatus> runtimeState() async => TrackerStatus(
        lifecycle: _running ? TrackerLifecycle.tracking : TrackerLifecycle.idle,
        trackId: _trackId,
      );

  @override
  Future<LocationSample?> lastLocation() async => _lastLocation;

  @override
  Future<List<LocationSample>> pendingLocations() async =>
      List<LocationSample>.unmodifiable(pending);

  @override
  Future<void> acknowledgeLocations(Iterable<String> eventIds) async {
    _throwIfScheduled('acknowledgeLocations');
    final ids = eventIds.toSet();
    calls.add(FakeTrackingCall('acknowledgeLocations', <String, Object?>{
      'count': ids.length,
    }));
    pending.removeWhere((sample) => ids.contains(sample.eventId));
  }

  @override
  Future<bool> openAppSettings() async {
    calls.add(const FakeTrackingCall('openAppSettings'));
    return true;
  }

  @override
  Future<NativeTrackingProtocol> protocolInfo() async => protocol;

  @override
  Future<void> dispose() async {
    calls.add(const FakeTrackingCall('dispose'));
    await _locations.close();
    await _activities.close();
    await _statuses.close();
  }

  void _throwIfScheduled(String method) {
    final failure = failures.remove(method);
    if (failure != null) throw failure;
  }
}

/// In-memory implementation of the normal host facade.
///
/// It is intentionally deterministic and supports the complete lifecycle used
/// by widget tests. Export data is represented by a fake path and route maps
/// contain the points injected through [emitPoint].
final class FakeTrackingController
    implements TrackingController, TrackingConfigurationController {
  FakeTrackingController({
    required TrackingOwner owner,
    DateTime Function()? clock,
    TrackingReadiness? readiness,
  })  : _owner = owner,
        _clock = clock ?? DateTime.now,
        _readiness = readiness ?? _ready();

  TrackingOwner _owner;
  final DateTime Function() _clock;
  TrackingReadiness _readiness;
  final Map<String, Track> _tracks = <String, Track>{};
  final Map<String, List<TrackPoint>> _points = <String, List<TrackPoint>>{};
  final List<FakeTrackingCall> calls = <FakeTrackingCall>[];
  final StreamController<TrackingSessionSnapshot> _sessions =
      StreamController<TrackingSessionSnapshot>.broadcast();
  final StreamController<TrackHistoryEvent> _history =
      StreamController<TrackHistoryEvent>.broadcast();
  ActivitySnapshot _activity = const ActivitySnapshot.unknown();
  TrackingSessionSnapshot? _snapshot;
  int _revision = 0;
  int _nextTrack = 1;
  bool _disposed = false;

  static TrackingReadiness _ready() => TrackingReadiness(
        revision: 1,
        permissions: FakeTrackerAdapter.fullyReadyPermissionState,
        capabilities: FakeTrackerAdapter.fullySupportedCapabilityReport,
        issues: const <TrackingReadinessIssue>[],
        nextAction: TrackingReadinessAction.none,
      );

  @override
  bool get isInitialized => !_disposed;
  @override
  TrackingOwner get currentOwner => _owner;
  @override
  TrackerStatus get currentStatus => currentSession.status;
  @override
  ActivitySnapshot get currentActivity => _activity;
  @override
  TrackingSessionSnapshot get currentSession => _snapshot ??= _buildSnapshot();
  @override
  bool get supportsPagedHistory => true;
  @override
  Stream<TrackHistoryEvent> get trackHistoryEvents => _history.stream;

  @override
  Stream<TrackingSessionSnapshot> get sessionStream =>
      Stream<TrackingSessionSnapshot>.multi(
        (controller) {
          controller.add(currentSession);
          final subscription = _sessions.stream.listen(
            controller.add,
            onError: controller.addError,
            onDone: controller.close,
          );
          controller.onCancel = subscription.cancel;
        },
        isBroadcast: true,
      );

  @override
  Stream<TrackerStatus> get statusStream =>
      sessionStream.map((snapshot) => snapshot.status);
  @override
  Stream<ActivitySnapshot> get activityStream =>
      sessionStream.map((snapshot) => snapshot.activity);
  @override
  Stream<TrackPoint> get pointStream => _pointStream.stream;
  final StreamController<TrackPoint> _pointStream =
      StreamController<TrackPoint>.broadcast();

  @override
  Stream<Track?> watchCurrentTrack() =>
      sessionStream.map((snapshot) => snapshot.currentTrack);

  @override
  Future<void> initialize() async {}
  @override
  Future<TrackingCapabilityReport> capabilities() async =>
      _readiness.capabilities;
  @override
  Future<TrackingPermissionState> permissions({bool request = false}) async =>
      _readiness.permissions;
  @override
  Future<TrackingReadiness> checkReadiness() async {
    calls.add(const FakeTrackingCall('checkReadiness'));
    return _readiness;
  }

  @override
  Future<TrackingReadiness> requestNextPermission() async {
    calls.add(const FakeTrackingCall('requestNextPermission'));
    return _readiness;
  }

  @override
  Future<TrackingReadiness> acknowledgeReadinessEducation(
      String issueCode) async {
    calls.add(FakeTrackingCall(
      'acknowledgeReadinessEducation',
      <String, Object?>{'issueCode': issueCode},
    ));
    return _readiness;
  }

  void setReadiness(TrackingReadiness readiness) {
    _readiness = readiness;
    _publish();
  }

  void emitActivity(ActivitySnapshot activity) {
    _activity = activity;
    _publish();
  }

  TrackPoint emitPoint({
    required double latitude,
    required double longitude,
    bool accepted = true,
  }) {
    final track = _currentTrack;
    if (track == null || track.status != TrackStatus.active) {
      throw StateError('Start or resume a fake route before emitting points.');
    }
    final values = _points.putIfAbsent(track.id, () => <TrackPoint>[]);
    final now = _clock().toUtc();
    final point = TrackPoint(
      id: 'fake-point-${values.length + 1}',
      trackId: track.id,
      segmentId: track.currentSegmentId!,
      sequence: values.length + 1,
      latitude: latitude,
      longitude: longitude,
      capturedAt: now,
      persistedAt: now,
      activityType: _activity.type,
      activityConfidence: _activity.confidence,
      motionState: MotionState.moving,
      isMocked: false,
      mockDetectionAvailable: true,
      accepted: accepted,
      qualityFlags: TrackPointQualityFlag.none,
    );
    values.add(point);
    _tracks[track.id] = _copyTrack(
      track,
      acceptedPointCount: track.acceptedPointCount + (accepted ? 1 : 0),
      rejectedPointCount: track.rejectedPointCount + (accepted ? 0 : 1),
      nextSequence: point.sequence + 1,
      lastPointAt: now,
    );
    _pointStream.add(point);
    _publish();
    return point;
  }

  /// Seeds a resumable interrupted route to simulate process restoration.
  Track seedInterruptedTrack({
    String trackId = 'fake-interrupted-track',
    String? routeId,
    TrackingConfig config = const TrackingConfig(),
  }) {
    final now = _clock().toUtc();
    final track = Track(
      id: trackId,
      userId: _owner.userId,
      organizationId: _owner.organizationId,
      routeId: routeId,
      status: TrackStatus.interrupted,
      startedAt: now.subtract(const Duration(minutes: 5)),
      pausedAt: now,
      totalDistanceMeters: 0,
      acceptedPointCount: 0,
      rejectedPointCount: 0,
      segmentCount: 1,
      nextSequence: 1,
      currentSegmentId: null,
      completionReason: 'process_terminated',
      config: config,
    );
    _tracks[trackId] = track;
    _points[trackId] = <TrackPoint>[];
    calls.add(FakeTrackingCall(
      'seedInterruptedTrack',
      <String, Object?>{'trackId': trackId},
    ));
    _publish();
    return track;
  }

  @override
  Future<TrackStartResult> startNewTrack(TrackStartRequest request) async {
    _requireOwner(request.owner);
    if (_currentTrack?.isResumable == true ||
        _currentTrack?.status == TrackStatus.active) {
      throw const TrackingConflictException(
        code: 'active_track_conflict',
        message: 'A fake route is already active or resumable.',
      );
    }
    if (!_readiness.canStart) {
      throw const TrackingNotReadyException(
        code: 'tracking_not_ready',
        message: 'Fake readiness blocks Start.',
      );
    }
    final now = _clock().toUtc();
    final id = request.requestedTrackId ?? 'fake-track-${_nextTrack++}';
    final track = Track(
      id: id,
      userId: _owner.userId,
      organizationId: _owner.organizationId,
      routeId:
          request.routeId == null ? null : createRouteId(request.routeId!, now),
      status: TrackStatus.active,
      startedAt: now,
      totalDistanceMeters: 0,
      acceptedPointCount: 0,
      rejectedPointCount: 0,
      segmentCount: 1,
      nextSequence: 1,
      currentSegmentId: '$id-segment-1',
      config: request.config ?? const TrackingConfig(),
    );
    _tracks[id] = track;
    _points[id] = <TrackPoint>[];
    calls.add(
        FakeTrackingCall('startNewTrack', <String, Object?>{'trackId': id}));
    _history.add(
        TrackHistoryEvent(kind: TrackHistoryChangeKind.created, trackId: id));
    _publish();
    return TrackStartResult(
      track: track,
      disposition: TrackStartDisposition.created,
      readiness: _readiness,
    );
  }

  @override
  Future<TrackStartResult> startOrRecoverTrack(
      TrackStartRequest request) async {
    _requireOwner(request.owner);
    final current = _currentTrack;
    if (current == null || current.isTerminal) return startNewTrack(request);
    if (current.status == TrackStatus.active) {
      return TrackStartResult(
        track: current,
        disposition: TrackStartDisposition.reusedActive,
        readiness: _readiness,
      );
    }
    return _resume(current);
  }

  @override
  Future<TrackStartResult> resumeCurrentTrack() async {
    final track = _currentTrack;
    if (track == null || !track.isResumable) {
      throw const TrackingConflictException(
        code: 'no_resumable_track',
        message: 'There is no resumable fake route.',
      );
    }
    return _resume(track);
  }

  Future<TrackStartResult> _resume(Track track) async {
    final updated = _copyTrack(
      track,
      status: TrackStatus.active,
      resumedAt: _clock().toUtc(),
      currentSegmentId: '${track.id}-segment-${track.segmentCount + 1}',
      segmentCount: track.segmentCount + 1,
    );
    _tracks[track.id] = updated;
    calls.add(
        FakeTrackingCall('resume', <String, Object?>{'trackId': track.id}));
    _publish();
    return TrackStartResult(
      track: updated,
      disposition: track.status == TrackStatus.interrupted
          ? TrackStartDisposition.resumedInterrupted
          : TrackStartDisposition.resumedPaused,
      readiness: _readiness,
    );
  }

  @override
  Future<TrackLifecycleResult> pauseCurrentTrack({
    String reason = 'user_paused',
  }) async {
    final track = _requireCurrent();
    final updated = _copyTrack(
      track,
      status: TrackStatus.paused,
      pausedAt: _clock().toUtc(),
      currentSegmentId: null,
      clearCurrentSegment: true,
    );
    _tracks[track.id] = updated;
    calls
        .add(FakeTrackingCall('pause', <String, Object?>{'trackId': track.id}));
    _publish();
    return TrackLifecycleResult(track: updated, status: currentStatus);
  }

  @override
  Future<TrackLifecycleResult> completeCurrentTrack({
    String reason = 'user_completed',
  }) async {
    final track = _requireCurrent();
    final updated = _copyTrack(
      track,
      status: TrackStatus.completed,
      endedAt: _clock().toUtc(),
      completionReason: reason,
      currentSegmentId: null,
      clearCurrentSegment: true,
    );
    _tracks[track.id] = updated;
    calls.add(
        FakeTrackingCall('complete', <String, Object?>{'trackId': track.id}));
    _publish();
    return TrackLifecycleResult(track: updated, status: currentStatus);
  }

  @override
  Future<OwnerSwitchResult> switchOwner(
    TrackingOwner next, {
    OwnerSwitchPolicy policy = OwnerSwitchPolicy.rejectIfResumable,
  }) async {
    final previous = _owner;
    if (_currentTrack?.status == TrackStatus.active) {
      if (policy != OwnerSwitchPolicy.pauseAndPreserveCurrent) {
        throw const TrackingConflictException(
          code: 'active_track_conflict',
          message: 'Pause the fake route before switching owner.',
        );
      }
      await pauseCurrentTrack(reason: 'owner_switched');
    }
    _owner = next;
    _publish();
    return OwnerSwitchResult(previous: previous, current: next);
  }

  @override
  Future<OwnerConflictResolutionResult> resolveOwnerConflict(
    OwnerConflictResolutionRequest request,
  ) async {
    if (!request.confirmed) {
      throw const TrackingOwnershipException(
        code: 'owner_conflict_resolution_not_confirmed',
        message: 'Fake owner-conflict resolution requires confirmation.',
      );
    }
    return const OwnerConflictResolutionResult(
      disposition: OwnerConflictResolutionDisposition.alreadyResolved,
    );
  }

  @override
  Future<String> startTrack({
    required String userId,
    required String organizationId,
    String? routeId,
    String? requestedTrackId,
    TrackingConfig? config,
  }) async =>
      (await startOrRecoverTrack(TrackStartRequest(
        owner: TrackingOwner(userId: userId, organizationId: organizationId),
        routeId: routeId,
        requestedTrackId: requestedTrackId,
        config: config,
      )))
          .trackId;

  @override
  Future<void> pauseTrack(
      {String? trackId,
      String reason = 'user_paused',
      String? operationId}) async {
    _requireTrack(trackId);
    await pauseCurrentTrack(reason: reason);
  }

  @override
  Future<void> resumeTrack(String trackId) async {
    _requireTrack(trackId);
    await resumeCurrentTrack();
  }

  @override
  Future<void> completeTrack(
      {String? trackId,
      String reason = 'user_completed',
      String? operationId}) async {
    _requireTrack(trackId);
    await completeCurrentTrack(reason: reason);
  }

  @override
  Future<Track?> getTrack(String trackId) async {
    final track = _tracks[trackId];
    return track != null && _owner.owns(track) ? track : null;
  }

  @override
  Future<TrackPage> listTrackPage(TrackQuery query) async {
    final values = _tracks.values.where(_owner.owns).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return TrackPage(
      items: List<Track>.unmodifiable(values.take(query.limit)),
      hasMore: values.length > query.limit,
    );
  }

  @override
  Future<TrackBundle> loadTrackBundle(String trackId) async {
    final track = await getTrack(trackId);
    if (track == null) throw StateError('Unknown fake route.');
    final points = List<TrackPoint>.unmodifiable(_points[trackId] ?? const []);
    final segments = <TrackSegmentWithPoints>[];
    for (var number = 1; number <= track.segmentCount; number += 1) {
      final id = '${track.id}-segment-$number';
      final segmentPoints = points
          .where((point) => point.segmentId == id)
          .toList(growable: false);
      segments.add(TrackSegmentWithPoints(
        segment: TrackSegment(
          id: id,
          trackId: track.id,
          segmentNumber: number,
          status: track.status == TrackStatus.completed
              ? TrackSegmentStatus.completed
              : number == track.segmentCount &&
                      track.status == TrackStatus.active
                  ? TrackSegmentStatus.active
                  : TrackSegmentStatus.paused,
          startedAt: segmentPoints.isEmpty
              ? track.startedAt
              : segmentPoints.first.capturedAt,
          endedAt: track.status == TrackStatus.completed ? track.endedAt : null,
          distanceMeters: 0,
          acceptedPointCount:
              segmentPoints.where((point) => point.accepted).length,
        ),
        points: List<TrackPoint>.unmodifiable(segmentPoints),
      ));
    }
    return TrackBundle(
      track: track,
      segments: segments,
    );
  }

  @override
  Future<TrackExportResult> exportTrack({
    required String trackId,
    required TrackExportFormat format,
    TrackExportOptions options = const TrackExportOptions(),
    String? fileName,
  }) async {
    final track = await getTrack(trackId);
    if (track == null) throw StateError('Unknown fake route.');
    final extension = switch (format) {
      TrackExportFormat.geoJson => 'geojson',
      TrackExportFormat.kml => 'kml',
      TrackExportFormat.gpx => 'gpx',
    };
    final name = fileName ?? '${track.routeId ?? track.id}.$extension';
    calls.add(
        FakeTrackingCall('exportTrack', <String, Object?>{'trackId': trackId}));
    return TrackExportResult(
      trackId: trackId,
      format: format,
      fileName: name,
      mimeType: 'application/octet-stream',
      path: '/fake/$name',
      pointCount: _points[trackId]?.length ?? 0,
      segmentCount: track.segmentCount,
    );
  }

  @override
  Future<void> deleteTrack(String trackId) async {
    final track = await getTrack(trackId);
    if (track == null) throw StateError('Unknown fake route.');
    if (!track.isTerminal) throw StateError('Complete the fake route first.');
    _tracks.remove(trackId);
    _points.remove(trackId);
    _history.add(TrackHistoryEvent(
        kind: TrackHistoryChangeKind.deleted, trackId: trackId));
    _publish();
  }

  @override
  Future<TrackingSettingsResult> openSettings(
    TrackingSettingsDestination destination,
  ) async {
    calls.add(
      FakeTrackingCall(
        'openSettings',
        <String, Object?>{'destination': destination.name},
      ),
    );
    return TrackingSettingsResult(
      destination: destination,
      supported: true,
      opened: true,
    );
  }

  @override
  Future<TrackingConfigurationUpdateResult> updateTrackingConfig(
    TrackingConfig config,
  ) async {
    config.validate(context: 'Fake runtime TrackingConfig');
    final track = _requireCurrent();
    if (track.status != TrackStatus.active) {
      throw StateError('A fake route must be active to update configuration.');
    }
    final updated = Track(
      id: track.id,
      userId: track.userId,
      organizationId: track.organizationId,
      routeId: track.routeId,
      status: track.status,
      startedAt: track.startedAt,
      pausedAt: track.pausedAt,
      resumedAt: track.resumedAt,
      endedAt: track.endedAt,
      totalDistanceMeters: track.totalDistanceMeters,
      acceptedPointCount: track.acceptedPointCount,
      rejectedPointCount: track.rejectedPointCount,
      segmentCount: track.segmentCount,
      nextSequence: track.nextSequence,
      currentSegmentId: track.currentSegmentId,
      lastPointAt: track.lastPointAt,
      completionReason: track.completionReason,
      config: config,
    );
    _tracks[track.id] = updated;
    final now = _clock().toUtc();
    final epoch = TrackingConfigurationEpoch(
      id: 'fake-epoch-${track.id}-${track.nextSequence}',
      trackId: track.id,
      epochNumber: track.segmentCount + 1,
      resolvedConfig: config,
      presetDefinitionVersion: TrackingPolicyVersions.presetDefinition,
      qualityPolicyVersion: TrackingPolicyVersions.qualityPolicy,
      createdAt: now,
      activationSequence: track.nextSequence,
      activatedAt: now,
    );
    calls.add(FakeTrackingCall(
      'updateTrackingConfig',
      <String, Object?>{'trackId': track.id},
    ));
    _publish();
    return TrackingConfigurationUpdateResult(
      trackId: track.id,
      epoch: epoch,
      resumedCapture: true,
    );
  }

  Track? get _currentTrack {
    final candidates = _tracks.values.where(
      (track) =>
          _owner.owns(track) &&
          (track.status == TrackStatus.active || track.isResumable),
    );
    return candidates.isEmpty ? null : candidates.last;
  }

  Track _requireCurrent() {
    final track = _currentTrack;
    if (track == null) throw StateError('There is no current fake route.');
    return track;
  }

  void _requireTrack(String? trackId) {
    if (trackId != null && _currentTrack?.id != trackId) {
      throw StateError('The fake route is not current.');
    }
    _requireCurrent();
  }

  void _requireOwner(TrackingOwner owner) {
    if (owner.userId != _owner.userId ||
        owner.organizationId != _owner.organizationId) {
      throw const TrackingOwnershipException(
        code: 'owner_scope_conflict',
        message: 'The fake request owner does not match the bound owner.',
      );
    }
  }

  TrackingSessionSnapshot _buildSnapshot() {
    final track = _currentTrack;
    final lifecycle = switch (track?.status) {
      TrackStatus.active => TrackerLifecycle.tracking,
      TrackStatus.paused => TrackerLifecycle.paused,
      TrackStatus.interrupted => TrackerLifecycle.interrupted,
      _ => TrackerLifecycle.idle,
    };
    final status = TrackerStatus(lifecycle: lifecycle, trackId: track?.id);
    return TrackingSessionSnapshot(
      revision: ++_revision,
      observedAt: _clock().toUtc(),
      status: status,
      currentTrack: track,
      activity: _activity,
      lastPoint: track == null || (_points[track.id]?.isEmpty ?? true)
          ? null
          : _points[track.id]!.last,
      readiness: _readiness,
      allowedActions: TrackingLifecycleActions.fromState(
        status: status,
        currentTrack: track,
        readiness: _readiness,
      ),
    );
  }

  void _publish() {
    _snapshot = _buildSnapshot();
    if (!_sessions.isClosed) _sessions.add(_snapshot!);
  }

  static Track _copyTrack(
    Track source, {
    TrackStatus? status,
    DateTime? pausedAt,
    DateTime? resumedAt,
    DateTime? endedAt,
    int? acceptedPointCount,
    int? rejectedPointCount,
    int? segmentCount,
    int? nextSequence,
    String? currentSegmentId,
    bool clearCurrentSegment = false,
    DateTime? lastPointAt,
    String? completionReason,
  }) =>
      Track(
        id: source.id,
        userId: source.userId,
        organizationId: source.organizationId,
        routeId: source.routeId,
        status: status ?? source.status,
        startedAt: source.startedAt,
        pausedAt: pausedAt ?? source.pausedAt,
        resumedAt: resumedAt ?? source.resumedAt,
        endedAt: endedAt ?? source.endedAt,
        totalDistanceMeters: source.totalDistanceMeters,
        acceptedPointCount: acceptedPointCount ?? source.acceptedPointCount,
        rejectedPointCount: rejectedPointCount ?? source.rejectedPointCount,
        segmentCount: segmentCount ?? source.segmentCount,
        nextSequence: nextSequence ?? source.nextSequence,
        currentSegmentId: clearCurrentSegment
            ? null
            : (currentSegmentId ?? source.currentSegmentId),
        lastPointAt: lastPointAt ?? source.lastPointAt,
        completionReason: completionReason ?? source.completionReason,
        terminalReasonCode: source.terminalReasonCode,
        sessionControlToken: source.sessionControlToken,
        config: source.config,
      );

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _sessions.close();
    await _history.close();
    await _pointStream.close();
  }
}
