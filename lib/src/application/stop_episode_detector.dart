import 'dart:math' as math;

import '../domain/activity_snapshot.dart';
import '../domain/fix_quality.dart';
import '../domain/motion_policy.dart';
import '../domain/stop_site.dart';
import '../domain/track_geodesy.dart';
import '../domain/track_point.dart';
import '../domain/tracking_config.dart';
import '../domain/tracking_configuration_epoch.dart';
import 'motion_gate.dart';

/// A stop found by [StopEpisodeDetector]: the inclusive index range of a
/// segment's accepted points recorded during a stay at one place, and the
/// robust centre they collapse to.
final class StopEpisode {
  const StopEpisode({
    required this.firstIndex,
    required this.lastIndex,
    required this.latitude,
    required this.longitude,
  });

  final int firstIndex;
  final int lastIndex;
  final double latitude;
  final double longitude;
}

/// Finds stops in a segment's accepted points after capture, for derived
/// presentation only.
///
/// A stop is a stay at a place, with the rules quality policy 3 records by,
/// replayed from the evidence stored on each point:
///
/// * it starts at a still episode of motion policy 2, or at a dwell: points
///   with no moving evidence that stay within the hold radius for
///   [StopSitePolicy.dwellMinimumDuration] without net progress. A phone in
///   a pocket rarely reports still while its owner stands, sits or walks
///   about in one place.
/// * walking inside the hold radius stays part of it.
/// * it ends when a point leaves the radius with a Doppler speed, with current
///   moving evidence on a second outside point, or for good.
///
/// Unlike the causal pipeline, a stop also covers the points before it was
/// recognised: a dwell's first two minutes, a stay whose fixes the provider
/// withheld, and the arrival inside the hold radius. Routes recorded under
/// any policy are cleaned the same way; their canonical points are never
/// changed.
final class StopEpisodeDetector {
  StopEpisodeDetector(TrackingConfig config)
      : _config = TrackingConfig.fromMap(<String, Object?>{
          ...config.toMap(),
          'captureIntent': RouteCaptureIntent.adaptive.name,
          'motionPolicyVersion': TrackingPolicyVersions.motionPolicy,
        });

  final TrackingConfig _config;

  /// Points farther than this from a stop's centre keep their raw position,
  /// so a genuine anomaly stays visible.
  static const maximumCollapseDistanceMeters = 150.0;

  /// Stops among [points], a segment's accepted points; episode indices
  /// refer to [points].
  ///
  /// [heldEvidence] may carry the segment's rejected points: those a stop hold
  /// stored as `stationary_hold` are evidence of the stop they were held in,
  /// so a route recorded under quality policy 2 or 3, whose stops are mostly
  /// held points, is cleaned like an older one. Their coordinates are never
  /// output.
  List<StopEpisode> detect(
    List<TrackPoint> points, {
    Iterable<TrackPoint> heldEvidence = const <TrackPoint>[],
  }) {
    if (points.isEmpty) return const <StopEpisode>[];
    final acceptedIndex = <String, int>{
      for (final (index, point) in points.indexed) point.id: index,
    };
    final evidence = <TrackPoint>[
      ...points,
      ...heldEvidence.where(
        (point) =>
            !point.accepted &&
            point.rejectionReason == FixQualityIssue.stationaryHold &&
            !acceptedIndex.containsKey(point.id),
      ),
    ]..sort((a, b) => a.sequence.compareTo(b.sequence));
    if (evidence.length < 2) return const <StopEpisode>[];
    final fixes = <DwellFix>[
      for (final point in evidence)
        DwellFix(
          latitude: point.latitude,
          longitude: point.longitude,
          sigmaMeters: _sigma(point),
          capturedAt: point.capturedAt,
        ),
    ];

    final episodes = <StopEpisode>[];
    var previousEnd = -1;
    for (final (first, last) in _stays(evidence, fixes)) {
      final centre = DwellRun.centreOf(fixes.sublist(first, last + 1));
      // Arriving inside the hold radius is part of the stop, as leaving it
      // is: earlier points within the radius of the stop's centre join it,
      // walking or not.
      var extended = first;
      while (extended - 1 > previousEnd) {
        final candidate = fixes[extended - 1];
        final distance = TrackGeodesy.sphericalHaversineMeters(
          centre.latitude,
          centre.longitude,
          candidate.latitude,
          candidate.longitude,
        );
        if (distance >
            MotionPolicyV2.holdRadiusMeters(
              anchorSigmaMeters: centre.sigmaMeters,
              fixSigmaMeters: candidate.sigmaMeters,
            )) {
          break;
        }
        extended -= 1;
      }
      previousEnd = last;
      final accepted = <int>[
        for (var index = extended; index <= last; index += 1)
          if (acceptedIndex[evidence[index].id] case final position?) position,
      ];
      if (accepted.isEmpty) continue;
      episodes.add(StopEpisode(
        firstIndex: accepted.first,
        lastIndex: accepted.last,
        latitude: centre.latitude,
        longitude: centre.longitude,
      ));
    }
    return episodes;
  }

  /// Stays as inclusive index ranges. A stay of a single point or shorter
  /// than [MotionPolicyV2.stillEpisodeMinimumSpan] is not reported.
  List<(int, int)> _stays(List<TrackPoint> points, List<DwellFix> fixes) {
    final gate = MotionGate(_config);
    final stays = <(int, int)>[];
    final run = <int>[];
    DateTime? lastMovingAt;

    // The current stop, if any.
    int? start;
    StopSiteAnchor? site;
    var startedAt = points.first.capturedAt;
    DateTime? outsideSince;
    var outsideCount = 0;
    var farthest = 0.0;

    // A run broken off at [at] was a stay if, silence until [at] included, it
    // lasted the dwell time without net progress. Only offline can a stay
    // whose fixes the provider withheld be recognised.
    void flush(DateTime at) {
      if (run.length < 2) return;
      final first = points[run.first].capturedAt;
      final stay = at.difference(first);
      final span = points[run.last].capturedAt.difference(first);
      if (stay < StopSitePolicy.dwellMinimumDuration ||
          span >= StopSitePolicy.dwellMinimumDuration) {
        return;
      }
      final net = TrackGeodesy.sphericalHaversineMeters(
        points[run.first].latitude,
        points[run.first].longitude,
        points[run.last].latitude,
        points[run.last].longitude,
      );
      if (net / (stay.inMilliseconds / 1000) <=
          StopSitePolicy.dwellMaximumTrendSpeedMetersPerSecond) {
        stays.add((run.first, run.last));
        run.clear();
      }
    }

    void close(int last) {
      final first = start;
      if (first != null && last > first) {
        final leftAt = last + 1 < points.length
            ? points[last + 1].capturedAt
            : points[last].capturedAt;
        if (leftAt.difference(points[first].capturedAt) >=
            MotionPolicyV2.stillEpisodeMinimumSpan) {
          stays.add((first, last));
        }
      }
      start = null;
      site = null;
      run.clear();
    }

    for (var index = 0; index < points.length; index += 1) {
      final point = points[index];
      final at = point.capturedAt;
      final activity = _activityOf(point);
      if (activity != null) {
        gate.add(activity, at);
        final recordedAt = activity.recordedAt;
        if (recordedAt != null &&
            StopSitePolicy.isMovingEvidence(
              activity,
              movingConfidenceThreshold: _config.movingConfidenceThreshold,
            ) &&
            (lastMovingAt == null || recordedAt.isAfter(lastMovingAt))) {
          lastMovingAt = recordedAt;
        }
      }
      gate.evaluate(at);

      final current = site;
      if (current == null) {
        if (gate.stillEpisodeActive) {
          final previous = index > 0 ? points[index - 1] : point;
          start = index;
          site = StopSiteAnchor(
            latitude: previous.latitude,
            longitude: previous.longitude,
            sigmaMeters: _sigma(previous),
          );
          startedAt = gate.stillEpisodeStartedAt ?? at;
          outsideSince = null;
          outsideCount = 0;
          farthest = 0;
          run.clear();
          continue;
        }
        // A dwell needs a confined run with no moving evidence in it.
        final movingAt = lastMovingAt;
        if (movingAt != null) {
          if (!at.isAfter(movingAt)) {
            flush(at);
            run.clear();
            continue;
          }
          if (run.isNotEmpty &&
              !points[run.last].capturedAt.isAfter(movingAt)) {
            flush(movingAt);
          }
          run.removeWhere(
            (member) => !points[member].capturedAt.isAfter(movingAt),
          );
        }
        if (StopSitePolicy.dopplerShowsMovement(
          speed: point.speed,
          speedAccuracy: point.speedAccuracy,
        )) {
          flush(at);
          run.clear();
          continue;
        }
        run.add(index);
        while (run.length > StopSitePolicy.maximumDwellRunFixes) {
          run.removeAt(0);
        }
        if (run.length > 1 && !_confined(fixes, run)) {
          run.removeLast();
          flush(at);
          run.add(index);
          while (run.length > 1 && !_confined(fixes, run)) {
            run.removeAt(0);
          }
        }
        final members = <DwellFix>[for (final member in run) fixes[member]];
        if (members.length >= 2 &&
            members.last.capturedAt.difference(members.first.capturedAt) >=
                StopSitePolicy.dwellMinimumDuration &&
            DwellRun.progressSpeedMetersPerSecond(members) <=
                StopSitePolicy.dwellMaximumTrendSpeedMetersPerSecond) {
          start = run.first;
          site = DwellRun.centreOf(members);
          startedAt = at;
          outsideSince = null;
          outsideCount = 0;
          farthest = 0;
          run.clear();
        }
        continue;
      }

      final distance = TrackGeodesy.sphericalHaversineMeters(
        current.latitude,
        current.longitude,
        point.latitude,
        point.longitude,
      );
      final radius = MotionPolicyV2.holdRadiusMeters(
        anchorSigmaMeters: current.sigmaMeters,
        fixSigmaMeters: _sigma(point),
      );
      if (distance <= radius) {
        // Walking about inside the place is part of the stop.
        outsideSince = null;
        outsideCount = 0;
        farthest = 0;
        continue;
      }
      final movingAt = lastMovingAt;
      final movingCurrent = movingAt != null &&
          movingAt.isAfter(startedAt) &&
          at.difference(movingAt) <= StopSitePolicy.movingEvidenceWindow;
      final since = outsideSince ?? at;
      outsideSince = since;
      final departs = MotionPolicyV2.dopplerConfirmsDeparture(
            speed: point.speed,
            speedAccuracy: point.speedAccuracy,
          ) ||
          (movingCurrent && outsideCount >= 1) ||
          (at.difference(since) >= MotionPolicyV2.sustainedOutsideDuration &&
              distance >= farthest &&
              distance >= MotionPolicyV2.sustainedOutsideRadiusFactor * radius);
      outsideCount += 1;
      farthest = math.max(farthest, distance);
      if (departs) {
        close(index - 1);
        gate.endStillEpisode(at);
      }
    }
    if (start != null) close(points.length - 1);
    return stays;
  }

  static bool _confined(List<DwellFix> fixes, List<int> run) {
    final members = <DwellFix>[for (final member in run) fixes[member]];
    final centre = DwellRun.centreOf(members);
    for (final fix in members) {
      final distance = TrackGeodesy.sphericalHaversineMeters(
        centre.latitude,
        centre.longitude,
        fix.latitude,
        fix.longitude,
      );
      if (distance >
          MotionPolicyV2.holdRadiusMeters(
            anchorSigmaMeters: centre.sigmaMeters,
            fixSigmaMeters: fix.sigmaMeters,
          )) {
        return false;
      }
    }
    return true;
  }

  ActivitySnapshot? _activityOf(TrackPoint point) {
    final source = point.activitySource;
    if (source == null ||
        point.activityEvidenceState == ActivityEvidenceState.unavailable) {
      return null;
    }
    return ActivitySnapshot(
      type: point.activityType,
      confidence: point.activityConfidence,
      recordedAt: point.capturedAt.subtract(point.activityAge ?? Duration.zero),
      evidenceState: point.activityEvidenceState,
      source: source,
      rawType: point.activityRawType,
    );
  }

  double _sigma(TrackPoint point) => MotionPolicyV2.sigmaMeters(
        horizontalAccuracy: point.horizontalAccuracy,
        hasSpeedAccuracy: point.speedAccuracy != null,
        hasVerticalAccuracy: point.verticalAccuracy != null,
        fallbackAccuracyMeters: _config.maximumAcceptedAccuracyMeters,
      );
}
