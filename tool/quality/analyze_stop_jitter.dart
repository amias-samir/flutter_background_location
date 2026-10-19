// Explains a field test from a diagnostic GeoJSON export (the example app's
// "Export diagnostic GeoJSON"): how much distance and how many fixes stops
// added while the device was still, how far reported accuracy understated the
// real spread, and whether the native stationary profile engaged.
//
//   dart run tool/quality/analyze_stop_jitter.dart <diagnostics.geojson>
//
// The report contains no coordinates: only counts, durations, metres and
// ratios. Run it on the private export locally; never commit the export.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const _earthRadiusMeters = 6371008.8;

/// A stop's fixes stay within this distance of their median, or within the
/// 99 % radius of their combined uncertainty when that is larger: the floor
/// of the package's hold radius.
const stopRadiusMeters = 25.0;

/// Shorter stays are pauses, not stops: the package's dwell time.
const minimumStopDuration = Duration(minutes: 2);

/// A stop makes no more net progress than this, in metres per second: the
/// least-squares velocity of its fixes less twice its standard error.
const maximumStopProgressMetersPerSecond = 0.15;

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln('usage: analyze_stop_jitter.dart <diagnostics.geojson>');
    exitCode = 64;
    return;
  }
  final json = jsonDecode(File(arguments.single).readAsStringSync());
  stdout.write(formatStopJitterReport(analyzeStopJitter(json as Map)));
}

/// One point feature of a diagnostic export.
final class DiagnosticPoint {
  DiagnosticPoint({
    required this.latitude,
    required this.longitude,
    required this.capturedAt,
    required this.accepted,
    this.accuracy,
    this.rejectionReason,
    this.samplingProfile,
    this.activityAge,
    this.speed,
    this.speedAccuracy,
    this.activityRawType,
    this.activityConfidence,
  });

  final double latitude;
  final double longitude;
  final DateTime capturedAt;
  final bool accepted;
  final double? accuracy;
  final String? rejectionReason;
  final String? samplingProfile;
  final Duration? activityAge;
  final double? speed;
  final double? speedAccuracy;
  final String? activityRawType;
  final int? activityConfidence;

  /// A fix the stop hold kept, or one accepted: stop evidence.
  bool get isStopEvidence => accepted || rejectionReason == 'stationary_hold';
}

/// Coordinate-free summary of one stop.
final class StopSummary {
  StopSummary({
    required this.duration,
    required this.acceptedCount,
    required this.heldCount,
    required this.otherRejectedCount,
    required this.phantomDistanceMeters,
    required this.spreadP50Meters,
    required this.spreadP90Meters,
    required this.spreadMaxMeters,
    required this.spreadToAccuracyP50,
    required this.spreadToAccuracyMax,
    required this.stationaryProfileShare,
    required this.longestActivitySilence,
    required this.stillEvidence,
    required this.activityMix,
    required this.reliableDopplerP50,
  });

  final Duration duration;
  final int acceptedCount;
  final int heldCount;
  final int otherRejectedCount;
  final double phantomDistanceMeters;
  final double spreadP50Meters;
  final double spreadP90Meters;
  final double spreadMaxMeters;

  /// Distance from the stop centre divided by reported accuracy.
  final double? spreadToAccuracyP50;
  final double? spreadToAccuracyMax;

  /// Share of the stop's points recorded in the native stationary profile.
  final double? stationaryProfileShare;
  final Duration? longestActivitySilence;

  /// Whether any fix carried a confident still reading (75 or more).
  final bool stillEvidence;

  /// The most frequent activity raw types on the stop's fixes, with counts.
  final Map<String, int> activityMix;

  /// Median Doppler speed of fixes whose speed accuracy is 0.4 m/s or
  /// better, when any are.
  final double? reliableDopplerP50;

  double get phantomMetersPerHour => duration.inSeconds == 0
      ? 0
      : phantomDistanceMeters / (duration.inSeconds / 3600);

  double get acceptedPerHour =>
      duration.inSeconds == 0 ? 0 : acceptedCount / (duration.inSeconds / 3600);
}

/// Coordinate-free report of a whole export.
final class StopJitterReport {
  StopJitterReport({
    required this.pointCount,
    required this.acceptedCount,
    required this.rejectionReasons,
    required this.acceptedDistanceMeters,
    required this.stops,
  });

  final int pointCount;
  final int acceptedCount;
  final Map<String, int> rejectionReasons;
  final double acceptedDistanceMeters;
  final List<StopSummary> stops;

  double get stopPhantomDistanceMeters =>
      stops.fold(0, (total, stop) => total + stop.phantomDistanceMeters);
}

StopJitterReport analyzeStopJitter(Map<Object?, Object?> geoJson) {
  final points = <DiagnosticPoint>[];
  for (final raw in geoJson['features'] as List<Object?>? ?? const []) {
    final feature = raw as Map;
    final geometry = feature['geometry'] as Map?;
    if (geometry?['type'] != 'Point') continue;
    final coordinates = geometry!['coordinates'] as List;
    final properties = (feature['properties'] as Map?) ?? const {};
    final capturedAt = DateTime.tryParse('${properties['capturedAt']}');
    if (capturedAt == null) continue;
    points.add(DiagnosticPoint(
      longitude: (coordinates[0] as num).toDouble(),
      latitude: (coordinates[1] as num).toDouble(),
      capturedAt: capturedAt.toUtc(),
      accepted: properties['accepted'] != false,
      accuracy: (properties['accuracy'] as num?)?.toDouble(),
      rejectionReason: properties['rejectionReason'] as String?,
      samplingProfile: properties['samplingProfile'] as String?,
      activityAge: properties['activityAgeMs'] is num
          ? Duration(milliseconds: (properties['activityAgeMs'] as num).toInt())
          : null,
      speed: (properties['speed'] as num?)?.toDouble(),
      speedAccuracy: (properties['speedAccuracy'] as num?)?.toDouble(),
      activityRawType: properties['activityRawType'] as String?,
      activityConfidence: (properties['activityConfidence'] as num?)?.toInt(),
    ));
  }
  points.sort((a, b) => a.capturedAt.compareTo(b.capturedAt));

  final accepted = points.where((point) => point.accepted).toList();
  final reasons = <String, int>{};
  for (final point in points.where((point) => !point.accepted)) {
    final reason = point.rejectionReason ?? 'unknown';
    reasons[reason] = (reasons[reason] ?? 0) + 1;
  }
  return StopJitterReport(
    pointCount: points.length,
    acceptedCount: accepted.length,
    rejectionReasons: reasons,
    acceptedDistanceMeters: _pathMeters(accepted),
    stops: _stops(points),
  );
}

List<StopSummary> _stops(List<DiagnosticPoint> points) {
  // The package's stop rule (quality policy 3, stop-aware cleaning v2) over
  // the fixes that say where the device was: accepted ones and those a stop
  // hold kept. A stay starts at held fixes or at two minutes confined with no
  // moving evidence and no net progress; walking inside it stays part of it;
  // it ends when a fix leaves the radius with a Doppler speed, with current
  // moving evidence on a second outside fix, or for good. Each summary covers
  // every fix of the stay's time span.
  final evidence = points.where((point) => point.isStopEvidence).toList();
  // First and last fix of each stay, and how long the stay lasted.
  final ranges = <(DateTime, DateTime, Duration)>[];
  final run = <DiagnosticPoint>[];
  DateTime? lastMovingAt;
  DiagnosticPoint? first;
  DiagnosticPoint? last;
  (double, double, double)? site;
  var startedAt = DateTime.utc(0);
  DateTime? outsideSince;
  var outsideCount = 0;
  var farthest = 0.0;

  void close() {
    final from = first, to = last;
    // Shorter stays, such as a hold during a walking pause, are pauses.
    if (from != null &&
        to != null &&
        to.capturedAt.difference(from.capturedAt) >= minimumStopDuration) {
      ranges.add((
        from.capturedAt,
        to.capturedAt,
        to.capturedAt.difference(from.capturedAt),
      ));
    }
    first = null;
    last = null;
    site = null;
    run.clear();
  }

  void flush(DateTime at) {
    if (run.length < 2) return;
    final stay = at.difference(run.first.capturedAt);
    if (stay >= minimumStopDuration &&
        _progress(run, stay) <= maximumStopProgressMetersPerSecond) {
      // The provider withheld fixes for most of this stay.
      ranges.add((run.first.capturedAt, run.last.capturedAt, stay));
    }
    run.clear();
  }

  for (var index = 0; index < evidence.length; index += 1) {
    final point = evidence[index];
    final at = point.capturedAt;
    final movingAt = _movingEvidenceAt(point);
    if (movingAt != null &&
        (lastMovingAt == null || movingAt.isAfter(lastMovingAt))) {
      lastMovingAt = movingAt;
    }
    final current = site;
    if (current == null) {
      if (point.rejectionReason == 'stationary_hold') {
        // The canonical pipeline held this fix: a stop was current.
        final anchor = index > 0 ? evidence[index - 1] : point;
        site = (anchor.latitude, anchor.longitude, _sigma(anchor));
        first = anchor;
        last = point;
        startedAt = at;
        outsideSince = null;
        outsideCount = 0;
        farthest = 0;
        run.clear();
        continue;
      }
      final moving = lastMovingAt;
      if ((moving != null && !at.isAfter(moving)) || _dopplerMoving(point)) {
        flush(at);
        continue;
      }
      if (moving != null) {
        run.removeWhere((member) => !member.capturedAt.isAfter(moving));
      }
      run.add(point);
      if (run.length > 1 && !_confined(run)) {
        run.removeLast();
        flush(at);
        run.add(point);
        while (run.length > 1 && !_confined(run)) {
          run.removeAt(0);
        }
      }
      if (run.length >= 2 &&
          run.last.capturedAt.difference(run.first.capturedAt) >=
              minimumStopDuration &&
          _progress(run, minimumStopDuration) <=
              maximumStopProgressMetersPerSecond) {
        final (latitude, longitude) = _medianCentre(run);
        final sigmas = run.map(_sigma).toList()..sort();
        site = (latitude, longitude, _quantile(sigmas, 0.5));
        first = run.first;
        last = point;
        startedAt = at;
        outsideSince = null;
        outsideCount = 0;
        farthest = 0;
        run.clear();
      }
      continue;
    }
    final (latitude, longitude, sigma) = current;
    final distance = _meters(latitude, longitude, point);
    final pointSigma = _sigma(point);
    final radius = math.max(
      stopRadiusMeters,
      math.sqrt(9.21 * (sigma * sigma + pointSigma * pointSigma)),
    );
    if (distance <= radius) {
      last = point;
      outsideSince = null;
      outsideCount = 0;
      farthest = 0;
      continue;
    }
    final moving = lastMovingAt;
    final movingCurrent = moving != null &&
        moving.isAfter(startedAt) &&
        at.difference(moving) <= const Duration(seconds: 60);
    final since = outsideSince ?? at;
    outsideSince = since;
    final speed = point.speed, speedAccuracy = point.speedAccuracy;
    final departs = (speed != null &&
            speedAccuracy != null &&
            speed >= math.max(1.2, 2 * speedAccuracy)) ||
        (movingCurrent && outsideCount >= 1) ||
        (at.difference(since) >= const Duration(seconds: 60) &&
            distance >= farthest &&
            distance >= 2 * radius);
    outsideCount += 1;
    farthest = math.max(farthest, distance);
    if (departs) {
      close();
    } else {
      last = point;
    }
  }
  close();

  return <StopSummary>[
    for (final (from, to, duration) in ranges)
      _summarize(
        points
            .where((point) =>
                !point.capturedAt.isBefore(from) &&
                !point.capturedAt.isAfter(to))
            .toList(),
        duration,
      ),
  ];
}

/// Evidence time of a moving reading on [point]: walking, running or cycling
/// at 60 or more, or in a vehicle at 75 or more.
DateTime? _movingEvidenceAt(DiagnosticPoint point) {
  final type = point.activityRawType;
  final confidence = point.activityConfidence ?? 0;
  final moving = switch (type) {
    'onFoot' || 'walking' || 'running' || 'onBicycle' => confidence >= 60,
    'inVehicle' => confidence >= 75,
    _ => false,
  };
  if (!moving) return null;
  return point.capturedAt.subtract(point.activityAge ?? Duration.zero);
}

/// A precisely measured walking or faster Doppler speed.
bool _dopplerMoving(DiagnosticPoint point) {
  final speed = point.speed, accuracy = point.speedAccuracy;
  return speed != null &&
      accuracy != null &&
      accuracy >= 0 &&
      accuracy <= 0.4 &&
      speed >= math.max(0.6, 2 * accuracy);
}

bool _confined(List<DiagnosticPoint> run) {
  final (latitude, longitude) = _medianCentre(run);
  final sigmas = run.map(_sigma).toList()..sort();
  final centreSigma = _quantile(sigmas, 0.5);
  return run.every((point) {
    final sigma = _sigma(point);
    final radius = math.max(
      stopRadiusMeters,
      math.sqrt(9.21 * (centreSigma * centreSigma + sigma * sigma)),
    );
    return _meters(latitude, longitude, point) <= radius;
  });
}

double _sigma(DiagnosticPoint point) =>
    math.max(1.5, (point.accuracy ?? 20) / 1.51);

/// Net progress of [run] over a stay of [stay]: least-squares velocity less
/// twice its standard error, or net displacement over the stay when silence
/// makes up most of it.
double _progress(List<DiagnosticPoint> run, Duration stay) {
  final span = run.last.capturedAt.difference(run.first.capturedAt);
  if (span < minimumStopDuration) {
    final seconds = stay.inMilliseconds / 1000;
    return seconds <= 0
        ? double.infinity
        : _meters(run.first.latitude, run.first.longitude, run.last) / seconds;
  }
  final origin = run.first;
  final cosine = math.cos(origin.latitude * math.pi / 180);
  const metersPerDegree = _earthRadiusMeters * math.pi / 180;
  final t = [
    for (final point in run)
      point.capturedAt.difference(origin.capturedAt).inMilliseconds / 1000,
  ];
  final e = [
    for (final point in run)
      (point.longitude - origin.longitude) * metersPerDegree * cosine,
  ];
  final n = [
    for (final point in run)
      (point.latitude - origin.latitude) * metersPerDegree,
  ];
  double mean(List<double> values) =>
      values.reduce((a, b) => a + b) / values.length;
  final tm = mean(t), em = mean(e), nm = mean(n);
  var stt = 0.0, ste = 0.0, stn = 0.0;
  for (var i = 0; i < run.length; i += 1) {
    stt += (t[i] - tm) * (t[i] - tm);
    ste += (t[i] - tm) * (e[i] - em);
    stn += (t[i] - tm) * (n[i] - nm);
  }
  if (stt <= 0) return 0;
  final ve = ste / stt, vn = stn / stt;
  var rss = 0.0;
  for (var i = 0; i < run.length; i += 1) {
    final re = e[i] - em - ve * (t[i] - tm);
    final rn = n[i] - nm - vn * (t[i] - tm);
    rss += re * re + rn * rn;
  }
  final sigmas = run.map(_sigma).toList()..sort();
  final sigma = _quantile(sigmas, 0.5);
  final variance = math.max(
    run.length > 2 ? rss / (2 * (run.length - 2)) : 0.0,
    sigma * sigma,
  );
  return math.max(
      0, math.sqrt(ve * ve + vn * vn) - 2 * math.sqrt(variance / stt));
}

StopSummary _summarize(List<DiagnosticPoint> members, Duration duration) {
  final accepted = members.where((point) => point.accepted).toList();
  final (latitude, longitude) =
      _medianCentre(accepted.isEmpty ? members : accepted);
  final spread = <double>[
    for (final point in accepted) _meters(latitude, longitude, point),
  ]..sort();
  final ratios = <double>[
    for (final point in accepted)
      if ((point.accuracy ?? 0) > 0)
        _meters(latitude, longitude, point) / point.accuracy!,
  ]..sort();
  final profiles = members.where((point) => point.samplingProfile != null);
  final ages = members
      .map((point) => point.activityAge)
      .whereType<Duration>()
      .toList()
    ..sort();
  const holdReasons = <String>{'stationary_hold', 'stationary_outlier'};
  final mix = <String, int>{};
  for (final point in members) {
    final type = point.activityRawType;
    if (type != null) mix[type] = (mix[type] ?? 0) + 1;
  }
  final topMix = (mix.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value)))
      .take(3);
  final reliable = members
      .where((point) =>
          point.speed != null &&
          point.speedAccuracy != null &&
          point.speedAccuracy! <= 0.4)
      .map((point) => point.speed!)
      .toList()
    ..sort();
  return StopSummary(
    duration: duration,
    acceptedCount: accepted.length,
    heldCount: members
        .where((point) => holdReasons.contains(point.rejectionReason))
        .length,
    otherRejectedCount: members
        .where((point) =>
            !point.accepted && !holdReasons.contains(point.rejectionReason))
        .length,
    phantomDistanceMeters: _pathMeters(accepted),
    spreadP50Meters: _quantile(spread, 0.5),
    spreadP90Meters: _quantile(spread, 0.9),
    spreadMaxMeters: spread.isEmpty ? 0 : spread.last,
    spreadToAccuracyP50: ratios.isEmpty ? null : _quantile(ratios, 0.5),
    spreadToAccuracyMax: ratios.isEmpty ? null : ratios.last,
    stationaryProfileShare: profiles.isEmpty
        ? null
        : profiles
                .where((point) => point.samplingProfile == 'stationary')
                .length /
            profiles.length,
    longestActivitySilence: ages.isEmpty ? null : ages.last,
    stillEvidence: members.any((point) =>
        point.activityRawType == 'still' &&
        (point.activityConfidence ?? 0) >= 75),
    activityMix: <String, int>{
      for (final entry in topMix) entry.key: entry.value,
    },
    reliableDopplerP50: reliable.isEmpty ? null : _quantile(reliable, 0.5),
  );
}

String formatStopJitterReport(StopJitterReport report) {
  final buffer = StringBuffer()
    ..writeln('points ${report.pointCount}, accepted ${report.acceptedCount}, '
        'rejected ${report.pointCount - report.acceptedCount} '
        '${report.rejectionReasons}')
    ..writeln('accepted distance ${report.acceptedDistanceMeters.round()} m, '
        'of which stops ${report.stopPhantomDistanceMeters.round()} m')
    ..writeln('stops (>= ${minimumStopDuration.inMinutes} min within '
        '${stopRadiusMeters.round()} m, no net progress): '
        '${report.stops.length}');
  String fixed(double? value, [int digits = 1]) =>
      value == null ? '-' : value.toStringAsFixed(digits);
  for (final (index, stop) in report.stops.indexed) {
    buffer
      ..writeln('  stop ${index + 1}: ${stop.duration.inMinutes} min, '
          'accepted ${stop.acceptedCount} (${fixed(stop.acceptedPerHour)}/h), '
          'held ${stop.heldCount}, other rejected ${stop.otherRejectedCount}')
      ..writeln('    phantom distance ${stop.phantomDistanceMeters.round()} m '
          '(${stop.phantomMetersPerHour.round()} m/h); spread p50/p90/max '
          '${fixed(stop.spreadP50Meters)}/${fixed(stop.spreadP90Meters)}/'
          '${fixed(stop.spreadMaxMeters)} m')
      ..writeln('    spread/accuracy p50 ${fixed(stop.spreadToAccuracyP50)}, '
          'max ${fixed(stop.spreadToAccuracyMax)}; native stationary '
          '${stop.stationaryProfileShare == null ? '-' : '${(stop.stationaryProfileShare! * 100).round()} %'}; '
          'longest activity silence '
          '${stop.longestActivitySilence == null ? '-' : '${stop.longestActivitySilence!.inSeconds} s'}')
      ..writeln('    still evidence ${stop.stillEvidence ? 'yes' : 'no'}; '
          'activity ${stop.activityMix}; reliable Doppler p50 '
          '${fixed(stop.reliableDopplerP50, 2)} m/s');
  }
  return buffer.toString();
}

(double, double) _medianCentre(List<DiagnosticPoint> points) {
  final latitudes = points.map((point) => point.latitude).toList()..sort();
  final longitudes = points.map((point) => point.longitude).toList()..sort();
  return (_quantile(latitudes, 0.5), _quantile(longitudes, 0.5));
}

double _quantile(List<double> sorted, double fraction) {
  if (sorted.isEmpty) return 0;
  final index = (fraction * (sorted.length - 1)).round();
  return sorted[index];
}

double _pathMeters(List<DiagnosticPoint> points) {
  var total = 0.0;
  for (var index = 1; index < points.length; index += 1) {
    total += _meters(
      points[index - 1].latitude,
      points[index - 1].longitude,
      points[index],
    );
  }
  return total;
}

double _meters(double latitude, double longitude, DiagnosticPoint to) {
  final phi1 = latitude * math.pi / 180;
  final phi2 = to.latitude * math.pi / 180;
  final deltaPhi = phi2 - phi1;
  final deltaLambda = (to.longitude - longitude) * math.pi / 180;
  final h = math.pow(math.sin(deltaPhi / 2), 2) +
      math.cos(phi1) * math.cos(phi2) * math.pow(math.sin(deltaLambda / 2), 2);
  return 2 * _earthRadiusMeters * math.asin(math.min(1, math.sqrt(h)));
}
