import 'dart:math' as math;

import '../domain/activity_snapshot.dart';
import '../domain/fix_quality.dart';
import '../domain/kinematic_policy.dart';
import '../domain/location_sample.dart';
import '../domain/motion_policy.dart';
import '../domain/stop_site.dart';
import '../domain/track_geodesy.dart';
import '../domain/track_point.dart';
import '../domain/track_stop.dart';
import '../domain/tracking_config.dart';
import '../domain/tracking_continuity.dart';
import '../domain/uncertainty_model.dart';
import 'motion_gate.dart';

/// Decisions of quality policy 5 for one route, fix by fix.
///
/// Quality policy 5 keeps the canonical route consistent across chipsets:
/// the first far fix after a silence must prove itself (`K2`), a fix the route
/// could not have reached is held back (`K1`), and a later fix that agrees
/// with such a suspect re-anchors the route (`K3`). Stays follow
/// [StopSitePolicyV5]. Every input is evidence stored with a fix (its attached
/// activity snapshot and the readings journaled with it), so a route decided
/// live, decided again after a restart, or reviewed offline gets the same
/// answers.
///
/// Decisions are two-phase: [decide] plans without changing state, and
/// [commit] advances the state once the fix is stored, so a failed write never
/// leaves the engine ahead of the database.
final class RouteDecisionEngine {
  RouteDecisionEngine(this.config) : _gate = MotionGate(config);

  final TrackingConfig config;
  final MotionGate _gate;

  /// Quality policy this engine applies.
  static const int policyVersion = 5;

  /// Accepted fixes kept for the recent speed and observed uncertainty.
  static const int recentAcceptedFixes = 30;

  /// Members kept per stay, oldest dropped first.
  static const int maximumStayMembers = 256;

  /// Longest silence across which a stay explains a gap by itself.
  static const stayGapSilence = Duration(seconds: 60);

  String? _segmentId;
  DateTime? _segmentStartedAt;
  TrackPoint? _lastAccepted;
  bool _lastAcceptedOpensSegment = false;
  final List<TrackPoint> _recentAccepted = <TrackPoint>[];
  DateTime? _lastPassedAt;
  DateTime? _lastRawAt;
  Duration _longestSilence = Duration.zero;
  bool _reacquisitionArmed = false;
  final List<_Suspect> _suspects = <_Suspect>[];
  _Stay? _stay;

  ActivitySnapshot? _latestReading;
  bool _activitySeen = false;
  final DwellRun _fallbackDwell = DwellRun();
  DateTime? _lastMovingEvidenceAt;
  DateTime? _lastMovingTransitionAt;
  final List<DateTime> _movingReadingTimes = <DateTime>[];
  final List<String> _recentReadingKeys = <String>[];

  /// Whether a stay is current.
  bool get stayCurrent => _stay != null;

  /// Whether the current stay has an open stop record.
  bool get stopRecordOpen => _stay?.recordOpen ?? false;

  /// Plans the decision for [sample], the next fix of segment [segmentId].
  ///
  /// [readings] are activity readings journaled with the fix; the fix's own
  /// attached snapshot is added. [anchor] is the stored last accepted point of
  /// the segment, when the caller has it: a different one means the route
  /// changed outside this engine, and the engine starts over from it.
  DecisionStep decide(
    LocationSample sample, {
    required String segmentId,
    DateTime? segmentStartedAt,
    List<ActivitySnapshot> readings = const <ActivitySnapshot>[],
    TrackPoint? anchor,
    bool syncAnchor = false,
  }) {
    if (segmentId != _segmentId) {
      _beginSegment(segmentId, segmentStartedAt);
    } else if (segmentStartedAt != null) {
      _segmentStartedAt ??= segmentStartedAt;
    }
    if (syncAnchor && anchor?.id != _lastAccepted?.id) {
      // The stored route moved on without this engine: restart from it.
      _clearStay();
      _suspects.clear();
      _reacquisitionArmed = false;
      _lastAccepted = anchor;
      _lastAcceptedOpensSegment = false;
      _recentAccepted
        ..clear()
        ..addAll(<TrackPoint>[if (anchor != null) anchor]);
    }
    final capturedAt = sample.capturedAt;
    _applyReadings(sample, readings);
    _gate.evaluate(capturedAt);

    final base = FixQualityPolicy(config, version: policyVersion).evaluate(
      sample: sample,
      previous: _lastAccepted,
      // A stored receipt time keeps the future-time check deterministic.
      now: sample.nativeReceivedAt ?? capturedAt,
    );
    final stay = _stay;
    final passes = base.acceptedForGeometry;
    if (config.captureIntent != RouteCaptureIntent.adaptive) {
      return DecisionStep._(
        decision: base,
        kind: passes ? _Kind.accepted : _Kind.rejected,
        passedVersion1: passes,
        capturedAt: capturedAt,
      );
    }
    if (!passes) {
      return DecisionStep._(
        decision: stay == null
            ? base
            : _withFlags(base, TrackPointQualityFlag.duringStop),
        kind: _Kind.rejected,
        passedVersion1: false,
        capturedAt: capturedAt,
        stopChange:
            stay != null && stay.recordOpen ? const TrackStopExtend() : null,
      );
    }

    final last = _lastAccepted;
    if (last == null) {
      // The first fix of a segment opens the route.
      return DecisionStep._(
        decision: base,
        kind: _Kind.accepted,
        passedVersion1: true,
        capturedAt: capturedAt,
      );
    }

    final fixSigma = _effectiveSigma(sample);
    final reference = _reference(last, fixSigma);
    final distanceToReference = _meters(
      reference.latitude,
      reference.longitude,
      sample.latitude,
      sample.longitude,
    );
    final distance = math.max(0.0, distanceToReference - reference.radius);
    final elapsed = capturedAt.difference(reference.time);
    final uncertainty =
        KinematicPolicy.uncertaintyMeters(reference.sigma, fixSigma);
    final referenceSpeed = _referenceSpeed(last.capturedAt);
    final mode = KinematicPolicy.modeOf(
      _freshReading(capturedAt),
      referenceSpeed: referenceSpeed,
    );
    final contextBound = KinematicPolicy.contextSpeedBound(
      mode: mode,
      referenceSpeed: referenceSpeed,
      elapsed: elapsed,
    );
    final ownBound = KinematicPolicy.ownSpeedBound(
          speed: sample.speed,
          speedAccuracy: sample.speedAccuracy,
        ) ??
        0;
    final reachable = KinematicPolicy.reachable(
      distanceMeters: distance,
      uncertainty: uncertainty,
      speedBound: math.max(contextBound, ownBound),
      elapsed: elapsed,
    );
    final lastPassedAt = _lastPassedAt;
    final armed = _reacquisitionArmed ||
        (lastPassedAt != null &&
            capturedAt.difference(lastPassedAt) >=
                KinematicPolicy.reacquisitionSilence(config.movingInterval));
    final far = distance >=
        math.max(KinematicPolicy.reacquisitionMinimumMeters, uncertainty);
    final provisional = armed &&
        far &&
        !KinematicPolicy.vouchedAfterSilence(
          distanceMeters: distance,
          uncertainty: uncertainty,
          elapsed: elapsed,
          speed: sample.speed,
          speedAccuracy: sample.speedAccuracy,
        );
    final stayBefore = stay != null;
    if (!reachable || provisional) {
      final doppler = KinematicPolicy.classify(
        speed: sample.speed,
        speedAccuracy: sample.speedAccuracy,
      );
      final point = KinematicPoint(
        latitude: sample.latitude,
        longitude: sample.longitude,
        capturedAt: capturedAt,
      );
      if (_reanchors(
        point: point,
        doppler: doppler,
        fixSigma: fixSigma,
        mode: mode,
        referenceSpeed: referenceSpeed,
        uncertainty: uncertainty,
        ownBound: ownBound,
      )) {
        return _accepted(
          base,
          sample,
          kind: _Kind.reanchor,
          armed: armed,
          stayBefore: stayBefore,
        );
      }
      final flags = TrackPointQualityFlag.implausibleSpeed |
          (stay != null ? TrackPointQualityFlag.duringStop : 0);
      return DecisionStep._(
        decision: FixQualityDecision(
          acceptedForGeometry: false,
          acceptedForMotionEvidence: false,
          issues: <String>[
            ...base.issues,
            provisional && reachable
                ? KinematicPolicy.unconfirmedAfterGapIssue
                : KinematicPolicy.kinematicOutlierReason,
          ],
          policyVersion: policyVersion,
          qualityFlags: base.qualityFlags | flags,
          rejectionReason: KinematicPolicy.kinematicOutlierReason,
        ),
        kind: _Kind.suspect,
        passedVersion1: true,
        capturedAt: capturedAt,
        armed: armed,
        suspect: _Suspect(point, fixSigma),
        stopChange:
            stay != null && stay.recordOpen ? const TrackStopExtend() : null,
      );
    }

    // A clean fix: kinematically plausible. Routes still on motion policy 1
    // keep no stays, as under quality policy 3.
    if (_gate.policyVersion < 2) {
      return _accepted(base, sample,
          kind: _Kind.accepted, armed: armed, stayBefore: false);
    }
    var current = stay;
    _Stay? started;
    if (current == null) {
      started = _plannedStay(sample, last, fixSigma, capturedAt);
      current = started;
    }
    if (current == null) {
      return _accepted(base, sample,
          kind: _Kind.accepted, armed: armed, stayBefore: false);
    }
    return _stayDecision(
      base,
      sample,
      current,
      started: started,
      fixSigma: fixSigma,
      armed: armed,
      stayBefore: stayBefore,
    );
  }

  /// Advances the state after the fix of [step] was stored as [stored].
  ///
  /// A replayed duplicate was decided, and its state advanced, when it was
  /// first stored.
  void commit(DecisionStep step, TrackPoint stored, {bool duplicate = false}) {
    if (duplicate) return;
    final capturedAt = stored.capturedAt;
    final lastRaw = _lastRawAt;
    if (lastRaw != null && capturedAt.isAfter(lastRaw)) {
      final silence = capturedAt.difference(lastRaw);
      if (silence > _longestSilence) _longestSilence = silence;
    }
    if (lastRaw == null || capturedAt.isAfter(lastRaw)) _lastRawAt = capturedAt;
    if (step.passedVersion1) _lastPassedAt = capturedAt;

    final started = step._startedStay;
    if (started != null) _stay = started;
    final stay = _stay;

    if (stored.accepted) {
      _acceptStored(stored, endedStay: stay != null);
      if (stay == null) {
        _trackFallbackDwell(stored, unknown: step.unknownEvidence);
      } else {
        _fallbackDwell.reset();
      }
      return;
    }
    switch (step._kind) {
      case _Kind.suspect:
        final suspect = step._suspect;
        if (suspect != null) _suspects.add(suspect);
        if (step.armed) _reacquisitionArmed = true;
      case _Kind.held || _Kind.outlier || _Kind.heldReanchor:
        _suspects.clear();
        _reacquisitionArmed = false;
      case _Kind.rejected || _Kind.accepted || _Kind.reanchor || _Kind.leave:
        break;
    }
    if (stay == null) return;
    stay
      ..heldCount += 1
      ..firstHeldSequence ??= stored.sequence
      ..lastHeldSequence = stored.sequence
      ..lastHeldAt = capturedAt;
    switch (step._kind) {
      case _Kind.held:
        final member = step._member;
        if (member != null) stay.addMember(member);
        stay.outsideRun.clear();
      case _Kind.outlier:
        final outside = step._outside;
        if (outside != null) stay.outsideRun.add(outside);
      case _Kind.heldReanchor:
        final centre = step._reanchorCentre;
        if (centre != null) {
          stay
            ..centre = centre
            ..members.clear()
            ..members.addAll(step._reanchorMembers)
            ..reanchored = true;
        }
        stay.outsideRun.clear();
      case _Kind.rejected ||
            _Kind.suspect ||
            _Kind.accepted ||
            _Kind.reanchor ||
            _Kind.leave:
        break;
    }
    if (_gate.stillEpisodeActive) stay.stillSeen = true;
    final promote = step.promote;
    if (promote != null) {
      stay
        ..isStop = true
        ..centre = promote;
      stay.outsideRun.clear();
    }
    if (step.stopChange is TrackStopOpen) stay.recordOpen = true;
  }

  /// Ends the current stay without a departure, as a pause or the end of a
  /// day closes its stop.
  void endStay() {
    _clearStay();
  }

  /// Without activity evidence a stay fails open, as native capture does.
  /// Returns whether a stay with an open record ended.
  bool activitySourceFailed(DateTime at) {
    final stay = _stay;
    if (stay == null) return false;
    _clearStay();
    _gate.endStillEpisode(at);
    return stay.recordOpen;
  }

  /// Rebuilds the state from [tail], the newest stored points of segment
  /// [segmentId] in sequence order, as after a restart. Each point is decided
  /// again from its stored evidence; its stored decision wins where they
  /// differ, and [openStop] decides whether a stop record is open.
  void restore({
    required List<RestoredFix> tail,
    required String segmentId,
    DateTime? segmentStartedAt,
    TrackStop? openStop,
  }) {
    _reset();
    _beginSegment(segmentId, segmentStartedAt);
    for (final fix in tail) {
      final point = fix.point;
      if (point.segmentId != segmentId) continue;
      final step = decide(
        fix.sample,
        segmentId: segmentId,
        segmentStartedAt: segmentStartedAt,
        readings: fix.readings,
      );
      commit(_reconciled(step, point), point);
    }
    final stay = _stay;
    if (openStop != null && openStop.segmentId == segmentId) {
      final centre = StopSiteAnchor(
        latitude: openStop.latitude,
        longitude: openStop.longitude,
        sigmaMeters: openStop.centreSigmaMeters,
      );
      if (stay == null) {
        _stay = _Stay(
          centre: centre,
          anchorPointId: openStop.arrivalPointId,
          startedAt: openStop.startedAt,
          anchorMember: null,
        )
          ..isStop = true
          ..recordOpen = true
          ..stillSeen = openStop.kind == TrackStopKind.still
          ..heldCount = openStop.evidenceCount
          ..firstHeldSequence = openStop.firstSequence
          ..lastHeldSequence = openStop.lastSequence
          ..lastHeldAt = openStop.lastSeenAt;
      } else {
        stay
          ..isStop = true
          ..recordOpen = true
          ..centre = centre;
      }
    } else if (stay != null && stay.recordOpen) {
      // The record was closed by a lifecycle event the tail doesn't show.
      _clearStay();
    }
  }

  void _reset() {
    _segmentId = null;
    _segmentStartedAt = null;
    _lastAccepted = null;
    _lastAcceptedOpensSegment = false;
    _recentAccepted.clear();
    _lastPassedAt = null;
    _lastRawAt = null;
    _longestSilence = Duration.zero;
    _reacquisitionArmed = false;
    _suspects.clear();
    _stay = null;
  }

  void _beginSegment(String segmentId, DateTime? startedAt) {
    _fallbackDwell.reset();
    _segmentId = segmentId;
    _segmentStartedAt = startedAt;
    _lastAccepted = null;
    _lastAcceptedOpensSegment = false;
    _recentAccepted.clear();
    _lastPassedAt = null;
    _lastRawAt = null;
    _longestSilence = Duration.zero;
    _reacquisitionArmed = false;
    _suspects.clear();
    _stay = null;
  }

  void _clearStay() {
    _stay = null;
  }

  /// Whether a fix carries evidence either way: activity readings seen on
  /// the route, or a usable Doppler speed.
  bool _knownEvidence(LocationSample sample) =>
      _activitySeen ||
      KinematicPolicy.isUsable(
        KinematicPolicy.classify(
          speed: sample.speed,
          speedAccuracy: sample.speedAccuracy,
        ),
      );

  /// Without activity evidence, two minutes of confined accepted fixes with
  /// no net progress make a stop; its fixes until then stay in the route.
  void _trackFallbackDwell(TrackPoint stored, {required bool unknown}) {
    if (!unknown || _gate.policyVersion < 2) {
      _fallbackDwell.reset();
      return;
    }
    final sigma = _pointSigma(stored);
    _fallbackDwell.add(
      DwellFix(
        latitude: stored.latitude,
        longitude: stored.longitude,
        sigmaMeters: sigma,
        capturedAt: stored.capturedAt,
      ),
    );
    final dwell = _fallbackDwell.dwellAnchor();
    if (dwell == null) return;
    final members = _fallbackDwell.fixes;
    _fallbackDwell.reset();
    _stay = _Stay(
      centre: dwell,
      anchorPointId: stored.id,
      startedAt: members.first.capturedAt,
      anchorMember: null,
    )
      ..isStop = true
      ..members.addAll(members);
  }

  void _acceptStored(TrackPoint stored, {required bool endedStay}) {
    _lastAcceptedOpensSegment = _lastAccepted == null;
    _lastAccepted = stored;
    _recentAccepted.add(stored);
    while (_recentAccepted.length > recentAcceptedFixes) {
      _recentAccepted.removeAt(0);
    }
    _suspects.clear();
    _reacquisitionArmed = false;
    _longestSilence = Duration.zero;
    if (endedStay) {
      _clearStay();
      _gate.endStillEpisode(stored.capturedAt);
    }
  }

  DecisionStep _reconciled(DecisionStep step, TrackPoint stored) {
    final storedAccepted = stored.accepted;
    final plannedAccepted = step.decision.acceptedForGeometry;
    if (storedAccepted == plannedAccepted) return step;
    // The stored decision wins: a route recorded by another build of this
    // policy, or written outside the engine.
    return DecisionStep._(
      decision: step.decision,
      kind: storedAccepted
          ? _Kind.accepted
          : switch (stored.rejectionReason) {
              FixQualityIssue.stationaryHold => _Kind.held,
              FixQualityIssue.stationaryOutlier => _Kind.outlier,
              KinematicPolicy.kinematicOutlierReason => _Kind.suspect,
              _ => _Kind.rejected,
            },
      passedVersion1: step.passedVersion1,
      capturedAt: step.capturedAt,
      armed: step.armed,
      suspect: step._suspect ??
          _Suspect(
            KinematicPoint(
              latitude: stored.latitude,
              longitude: stored.longitude,
              capturedAt: stored.capturedAt,
            ),
            KinematicPolicy.minimumSigmaMeters,
          ),
      startedStay: storedAccepted ? null : step._startedStay,
    );
  }

  DecisionStep _accepted(
    FixQualityDecision base,
    LocationSample sample, {
    required _Kind kind,
    required bool armed,
    required bool stayBefore,
  }) {
    final stay = _stay;
    TrackStopChange? change;
    if (stay != null) {
      change = stay.recordOpen
          ? const TrackStopClose(departure: true)
          : _recordAtDeparture(stay, sample);
    }
    return DecisionStep._(
      decision: base,
      kind: kind,
      passedVersion1: true,
      capturedAt: sample.capturedAt,
      armed: armed,
      stopChange: change,
      stayCurrentBefore: stayBefore,
      // A stay recorded as a stop as it is left explains its gap as a stop.
      stayExplainsGap: stay != null
          ? _stayExplainsGap(
              stay,
              sample,
              stop: stay.isStop || change is TrackStopRecord,
            )
          : _stillWithinRadius(sample),
      unknownEvidence: !_knownEvidence(sample),
    );
  }

  DecisionStep _stayDecision(
    FixQualityDecision base,
    LocationSample sample,
    _Stay stay, {
    required _Stay? started,
    required double fixSigma,
    required bool armed,
    required bool stayBefore,
  }) {
    final capturedAt = sample.capturedAt;
    final network = _isNetwork(sample);
    final gnss = _isGnss(sample);
    final centreSigma = _centreSigma(stay);
    final radius = StopSitePolicyV5.holdRadiusMeters(
      centreSigmaMeters: centreSigma,
      fixSigmaMeters: fixSigma,
    );
    final distance = _meters(
      stay.centre.latitude,
      stay.centre.longitude,
      sample.latitude,
      sample.longitude,
    );
    // Only full GNSS fixes are members: they set the radius and make a stay a
    // stop; a fix without a speed or vertical accuracy is only held.
    final member = !gnss
        ? null
        : DwellFix(
            latitude: sample.latitude,
            longitude: sample.longitude,
            sigmaMeters: fixSigma,
            capturedAt: capturedAt,
          );
    if (distance <= radius) {
      // A pause, not yet a stop, ends inside its radius on walking that both
      // the Doppler speed and confirmed readings show, so a walk on keeps its
      // vertices. Pocket sway or one reading never ends it, and walking about
      // inside a stop is part of the stop, also one this fix makes a stop.
      if (!stay.isStop &&
          !network &&
          StopSitePolicyV5.dopplerLeaves(
            speed: sample.speed,
            speedAccuracy: sample.speedAccuracy,
            stop: false,
          ) &&
          _confirmedActivity(capturedAt, since: stay.startedAt) &&
          !_promotesWith(stay, member, capturedAt)) {
        return _accepted(
          base,
          sample,
          kind: _Kind.leave,
          armed: armed,
          stayBefore: stayBefore,
        );
      }
      return _held(
        base,
        stay,
        started: started,
        kind: _Kind.held,
        reason: FixQualityIssue.stationaryHold,
        member: member,
        capturedAt: capturedAt,
        armed: armed,
        sample: sample,
      );
    }
    final outside = _Outside(
      point: KinematicPoint(
        latitude: sample.latitude,
        longitude: sample.longitude,
        capturedAt: capturedAt,
      ),
      distance: distance,
      sigma: fixSigma,
    );
    if (!network) {
      if (StopSitePolicyV5.dopplerLeaves(
        speed: sample.speed,
        speedAccuracy: sample.speedAccuracy,
        stop: stay.isStop,
      )) {
        return _accepted(base, sample,
            kind: _Kind.leave, armed: armed, stayBefore: stayBefore);
      }
      final blocked = StopSitePolicyV5.stillBlocks(
        reading: _latestReading,
        capturedAt: capturedAt,
        speed: sample.speed,
        speedAccuracy: sample.speedAccuracy,
      );
      if (!blocked) {
        final run = stay.outsideRun;
        if (_confirmedActivity(capturedAt, since: stay.startedAt) &&
            run.isNotEmpty &&
            distance > run.last.distance) {
          return _accepted(base, sample,
              kind: _Kind.leave, armed: armed, stayBefore: stayBefore);
        }
        if (_progresses(stay, outside, radius)) {
          return _accepted(base, sample,
              kind: _Kind.leave, armed: armed, stayBefore: stayBefore);
        }
      }
      if (!stay.isStop && !stay.reanchored) {
        final cluster = _reanchorCluster(stay, outside, fixSigma);
        if (cluster != null) {
          return _held(
            base,
            stay,
            started: started,
            kind: _Kind.heldReanchor,
            reason: FixQualityIssue.stationaryHold,
            member: member,
            capturedAt: capturedAt,
            armed: armed,
            sample: sample,
            reanchorCentre: DwellRun.centreOf(cluster),
            reanchorMembers: cluster,
          );
        }
      }
    }
    return _held(
      base,
      stay,
      started: started,
      kind: _Kind.outlier,
      reason: FixQualityIssue.stationaryOutlier,
      member: null,
      outside: network ? null : outside,
      capturedAt: capturedAt,
      armed: armed,
      sample: sample,
    );
  }

  DecisionStep _held(
    FixQualityDecision base,
    _Stay stay, {
    required _Stay? started,
    required _Kind kind,
    required String reason,
    required DwellFix? member,
    required DateTime capturedAt,
    required bool armed,
    required LocationSample sample,
    _Outside? outside,
    StopSiteAnchor? reanchorCentre,
    List<DwellFix> reanchorMembers = const <DwellFix>[],
  }) {
    final decision = FixQualityDecision(
      acceptedForGeometry: false,
      acceptedForMotionEvidence: false,
      issues: <String>[...base.issues, reason],
      policyVersion: policyVersion,
      qualityFlags: base.qualityFlags | TrackPointQualityFlag.duringStop,
      rejectionReason: reason,
    );
    TrackStopChange? change;
    StopSiteAnchor? promote;
    if (stay.recordOpen) {
      change = const TrackStopExtend();
    } else if (stay.isStop) {
      // Recognised from accepted fixes alone: open its record around the
      // centre it already holds.
      change = TrackStopOpen(
        kind: stay.stillSeen ? TrackStopKind.still : TrackStopKind.dwell,
        latitude: stay.centre.latitude,
        longitude: stay.centre.longitude,
        centreSigmaMeters: stay.centre.sigmaMeters,
        radiusMeters: StopSitePolicyV5.holdRadiusMeters(
          centreSigmaMeters: stay.centre.sigmaMeters,
          fixSigmaMeters: stay.centre.sigmaMeters,
        ),
        startedAt: stay.startedAt,
        qualityPolicyVersion: policyVersion,
        firstSequence: stay.firstHeldSequence,
        arrivalPointId: stay.anchorPointId,
        priorEvidenceCount: stay.heldCount,
      );
    } else {
      final members = <DwellFix>[
        ...(reanchorCentre != null ? reanchorMembers : stay.members),
        if (kind == _Kind.held && member != null) member,
      ];
      final lastPassedAt = _lastPassedAt;
      final silentArrival = kind == _Kind.held &&
          member != null &&
          lastPassedAt != null &&
          capturedAt.difference(lastPassedAt) >=
              KinematicPolicy.reacquisitionSilence(config.movingInterval);
      if (_promotes(
        stay,
        members,
        until: capturedAt,
        stillSeen: stay.stillSeen || _gate.stillEpisodeActive,
        silentArrival: silentArrival,
      )) {
        promote = _centreOf(members);
        change = TrackStopOpen(
          kind: stay.stillSeen || _gate.stillEpisodeActive
              ? TrackStopKind.still
              : TrackStopKind.dwell,
          latitude: promote.latitude,
          longitude: promote.longitude,
          centreSigmaMeters: promote.sigmaMeters,
          radiusMeters: StopSitePolicyV5.holdRadiusMeters(
            centreSigmaMeters: promote.sigmaMeters,
            fixSigmaMeters: promote.sigmaMeters,
          ),
          startedAt: stay.startedAt,
          qualityPolicyVersion: policyVersion,
          firstSequence: stay.firstHeldSequence,
          arrivalPointId: stay.anchorPointId,
          priorEvidenceCount: stay.heldCount,
        );
      }
    }
    return DecisionStep._(
      decision: decision,
      kind: kind,
      passedVersion1: true,
      capturedAt: capturedAt,
      armed: armed,
      stopChange: change,
      promote: promote,
      member: kind == _Kind.held ? member : null,
      outside: outside,
      reanchorCentre: reanchorCentre,
      reanchorMembers: reanchorMembers,
      startedStay: started,
    );
  }

  /// Quality policy 5 stay start (`S6`): a quiet fix inside the hold radius of
  /// the last accepted point, or a still episode.
  _Stay? _plannedStay(
    LocationSample sample,
    TrackPoint anchor,
    double fixSigma,
    DateTime capturedAt,
  ) {
    final still = _gate.stillEpisodeActive;
    if (!still) {
      // Without activity evidence on the route and without a usable Doppler
      // speed the fix's evidence is unknown: only the fallback dwell can
      // start a stop, as under quality policy 3.
      if (!_knownEvidence(sample)) return null;
      final anchorSigma = _pointSigma(anchor);
      final radius = StopSitePolicyV5.holdRadiusMeters(
        centreSigmaMeters: anchorSigma,
        fixSigmaMeters: fixSigma,
      );
      final distance = _meters(
        anchor.latitude,
        anchor.longitude,
        sample.latitude,
        sample.longitude,
      );
      if (distance > radius) return null;
      if (StopSitePolicyV5.dopplerLeaves(
        speed: sample.speed,
        speedAccuracy: sample.speedAccuracy,
        stop: false,
      )) {
        return null;
      }
      // Moving readings arrive late; a precise Doppler speed showing the
      // device still is newer evidence than they are.
      if (_confirmedActivity(capturedAt) &&
          !StopSitePolicy.dopplerShowsStillness(
            speed: sample.speed,
            speedAccuracy: sample.speedAccuracy,
          )) {
        return null;
      }
    }
    // A stay begins where the movement ended: the later of the last route
    // point and the last moving evidence; at the start of a segment, when
    // recording began.
    var startedAt = anchor.capturedAt;
    final stillSince = _gate.stillEpisodeStartedAt;
    final endOfMovement = still ? stillSince : _lastMovingEvidenceAt;
    if (endOfMovement != null && endOfMovement.isAfter(startedAt)) {
      startedAt = endOfMovement;
    } else if (_lastAcceptedOpensSegment) {
      final segmentStart = _segmentStartedAt;
      if (segmentStart != null && segmentStart.isBefore(startedAt)) {
        startedAt = segmentStart;
      }
    }
    if (startedAt.isAfter(capturedAt)) startedAt = capturedAt;
    // The anchor was still moving and the provider then fell silent: the
    // movement may have gone on for the whole silence, so only the fixes
    // after it count towards the two minutes.
    var clockStartedAt = startedAt;
    if (!still &&
        startedAt == anchor.capturedAt &&
        capturedAt.difference(anchor.capturedAt) >=
            KinematicPolicy.reacquisitionSilence(config.movingInterval) &&
        _movingAt(anchor)) {
      clockStartedAt = capturedAt;
    }
    final anchorSigma = _pointSigma(anchor);
    return _Stay(
      centre: StopSiteAnchor(
        latitude: anchor.latitude,
        longitude: anchor.longitude,
        sigmaMeters: anchorSigma,
      ),
      anchorPointId: anchor.id,
      startedAt: startedAt,
      clockStartedAt: clockStartedAt,
      anchorMember: !_isGnssPoint(anchor)
          ? null
          : DwellFix(
              latitude: anchor.latitude,
              longitude: anchor.longitude,
              sigmaMeters: anchorSigma,
              capturedAt: anchor.capturedAt,
            ),
    );
  }

  /// Whether holding [member] at [capturedAt] would make [stay] a stop.
  bool _promotesWith(_Stay stay, DwellFix? member, DateTime capturedAt) {
    final lastPassedAt = _lastPassedAt;
    return _promotes(
      stay,
      <DwellFix>[...stay.members, if (member != null) member],
      until: capturedAt,
      stillSeen: stay.stillSeen || _gate.stillEpisodeActive,
      silentArrival: member != null &&
          lastPassedAt != null &&
          capturedAt.difference(lastPassedAt) >=
              KinematicPolicy.reacquisitionSilence(config.movingInterval),
    );
  }

  /// Whether a stay of [members] has become a stop (`S5`).
  bool _promotes(
    _Stay stay,
    List<DwellFix> members, {
    required DateTime until,
    required bool stillSeen,
    required bool silentArrival,
  }) {
    if (until.difference(stay.clockStartedAt) <
        StopSitePolicy.dwellMinimumDuration) {
      return false;
    }
    if (stillSeen && members.length >= StopSitePolicyV5.stillPromotionMembers) {
      return true;
    }
    if (silentArrival && members.length >= 2) return true;
    if (members.length < StopSitePolicyV5.promotionMembers) return false;
    final span = members.last.capturedAt.difference(members.first.capturedAt);
    if (span < StopSitePolicyV5.promotionSpan) return false;
    return DwellRun.progressSpeedMetersPerSecond(members) <=
        StopSitePolicy.dwellMaximumTrendSpeedMetersPerSecond;
  }

  TrackStopRecord? _recordAtDeparture(_Stay stay, LocationSample departure) {
    final lastHeldAt = stay.lastHeldAt;
    if (lastHeldAt == null) return null;
    final members = stay.members;
    final silentUntil = _silentDepartureAt(stay, departure);
    final lastRaw = _lastRawAt;
    // After a silence the stay lasted only as long as evidence shows: until
    // its last held fix, or until the departure the first fix after the
    // silence shows.
    final silent = lastRaw != null &&
        departure.capturedAt.difference(lastRaw) >= stayGapSilence;
    final until = silent ? silentUntil ?? lastHeldAt : departure.capturedAt;
    if (!_promotes(
          stay,
          members,
          until: until,
          stillSeen: stay.stillSeen,
          silentArrival: false,
        ) &&
        !(silentUntil != null &&
            members.isNotEmpty &&
            silentUntil.difference(stay.clockStartedAt) >=
                StopSitePolicy.dwellMinimumDuration)) {
      return null;
    }
    final centre = _centreOf(members);
    return TrackStopRecord(
      kind: stay.stillSeen ? TrackStopKind.still : TrackStopKind.dwell,
      latitude: centre.latitude,
      longitude: centre.longitude,
      centreSigmaMeters: centre.sigmaMeters,
      radiusMeters: StopSitePolicyV5.holdRadiusMeters(
        centreSigmaMeters: centre.sigmaMeters,
        fixSigmaMeters: centre.sigmaMeters,
      ),
      startedAt: stay.startedAt,
      lastSeenAt: lastHeldAt,
      evidenceCount: stay.heldCount,
      qualityPolicyVersion: policyVersion,
      firstSequence: stay.firstHeldSequence,
      lastSequence: stay.lastHeldSequence,
      arrivalPointId: stay.anchorPointId,
    );
  }

  /// When a stay the provider fell silent in was left, if [departure], the
  /// first fix after the silence, shows it: its Doppler speed covers the way
  /// out of the radius within [stayGapSilence], so the device stayed until
  /// shortly before it. Moving readings recorded during the silence move the
  /// departure earlier. Null when the stay was not silent or the fix can't
  /// tell.
  DateTime? _silentDepartureAt(_Stay stay, LocationSample departure) {
    final lastRaw = _lastRawAt;
    if (lastRaw == null ||
        departure.capturedAt.difference(lastRaw) < stayGapSilence) {
      return null;
    }
    final speed = departure.speed;
    if (speed == null ||
        speed < 1 ||
        !KinematicPolicy.isUsable(
          KinematicPolicy.classify(
            speed: speed,
            speedAccuracy: departure.speedAccuracy,
          ),
        )) {
      return null;
    }
    final radius = StopSitePolicyV5.holdRadiusMeters(
      centreSigmaMeters: _centreSigma(stay),
      fixSigmaMeters: _effectiveSigma(departure),
    );
    final beyond = math.max(
      0.0,
      _meters(
            stay.centre.latitude,
            stay.centre.longitude,
            departure.latitude,
            departure.longitude,
          ) -
          radius,
    );
    final travelSeconds = beyond / speed;
    if (travelSeconds > stayGapSilence.inSeconds) return null;
    var departedAt = departure.capturedAt.subtract(
      Duration(milliseconds: (travelSeconds * 1000).round()),
    );
    for (final time in <DateTime?>[
      ..._movingReadingTimes,
      _lastMovingTransitionAt,
    ]) {
      if (time != null && time.isAfter(lastRaw) && time.isBefore(departedAt)) {
        departedAt = time;
      }
    }
    return departedAt.isAfter(lastRaw) ? departedAt : null;
  }

  /// Whether [point] showed movement: a usable Doppler speed of at least the
  /// pause-leaving speed, or confirmed moving readings.
  bool _movingAt(TrackPoint point) {
    final speed = point.speed;
    if (speed != null &&
        speed >= StopSitePolicyV5.pauseLeavingSpeedMetersPerSecond &&
        KinematicPolicy.isUsable(
          KinematicPolicy.classify(
            speed: speed,
            speedAccuracy: point.speedAccuracy,
          ),
        )) {
      return true;
    }
    return _confirmedActivity(point.capturedAt);
  }

  /// A gap that ends at [sample] within two hold radii of the last accepted
  /// point left no hole in the route: the device stayed about where it was,
  /// even though no stay had begun before the silence.
  bool _stillWithinRadius(LocationSample sample) {
    final last = _lastAccepted;
    if (last == null) return false;
    final radius = StopSitePolicyV5.holdRadiusMeters(
      centreSigmaMeters: _pointSigma(last),
      fixSigmaMeters: _effectiveSigma(sample),
    );
    return _meters(
          last.latitude,
          last.longitude,
          sample.latitude,
          sample.longitude,
        ) <=
        2 * radius;
  }

  /// Rule `C1`: a stay explains a gap that ends at [sample] when the silence
  /// stayed short, the fix is still near the stay, or a stop's departure
  /// speed covers the distance in time.
  bool _stayExplainsGap(
    _Stay stay,
    LocationSample sample, {
    required bool stop,
  }) {
    final lastRaw = _lastRawAt;
    var longest = _longestSilence;
    if (lastRaw != null && sample.capturedAt.isAfter(lastRaw)) {
      final tail = sample.capturedAt.difference(lastRaw);
      if (tail > longest) longest = tail;
    }
    if (longest < stayGapSilence) return true;
    final radius = StopSitePolicyV5.holdRadiusMeters(
      centreSigmaMeters: _centreSigma(stay),
      fixSigmaMeters: _effectiveSigma(sample),
    );
    final distance = _meters(
      stay.centre.latitude,
      stay.centre.longitude,
      sample.latitude,
      sample.longitude,
    );
    // A departure fix at most the visible straight-line distance beyond the
    // radius hides no more of the route than any gap that short.
    if (distance - radius <= TrackingContinuityGap.visibleStraightLineMeters) {
      return true;
    }
    if (!stop) return false;
    final speed = sample.speed;
    if (speed == null ||
        speed < 1 ||
        !KinematicPolicy.isUsable(
          KinematicPolicy.classify(
            speed: speed,
            speedAccuracy: sample.speedAccuracy,
          ),
        )) {
      return false;
    }
    return (distance - radius) / speed <= stayGapSilence.inSeconds;
  }

  bool _reanchors({
    required KinematicPoint point,
    required DopplerClass doppler,
    required double fixSigma,
    required KinematicMode mode,
    required double referenceSpeed,
    required double uncertainty,
    required double ownBound,
  }) {
    if (_suspects.isEmpty) return false;
    final previous = _suspects.last;
    if (KinematicPolicy.isUsable(doppler)) {
      final elapsed = point.capturedAt.difference(previous.point.capturedAt);
      final bound = math.max(
        KinematicPolicy.contextSpeedBound(
          mode: mode,
          referenceSpeed: referenceSpeed,
          elapsed: elapsed,
        ),
        ownBound,
      );
      final distance = _meters(
        previous.point.latitude,
        previous.point.longitude,
        point.latitude,
        point.longitude,
      );
      if (KinematicPolicy.reachable(
        distanceMeters: distance,
        uncertainty:
            KinematicPolicy.uncertaintyMeters(previous.sigma, fixSigma),
        speedBound: bound,
        elapsed: elapsed,
      )) {
        return true;
      }
    }
    final run = <KinematicPoint>[
      ..._suspects.map((suspect) => suspect.point),
      point,
    ];
    if (run.length < KinematicPolicy.suspectConsensusFixes) return false;
    if (point.capturedAt.difference(run.first.capturedAt) <
        KinematicPolicy.suspectPersistence) {
      return false;
    }
    final residual = KinematicPolicy.constantVelocityResidualMeters(
      run.sublist(run.length - KinematicPolicy.suspectConsensusFixes),
    );
    return residual != null && residual <= uncertainty;
  }

  /// Steady outward progress from a stay (`S3`).
  bool _progresses(_Stay stay, _Outside outside, double radius) {
    final run = <_Outside>[...stay.outsideRun, outside];
    final farEnough =
        outside.distance >= StopSitePolicyV5.progressRadiusFactor * radius;
    if (!farEnough) return false;
    if (!stay.isStop) {
      if (run.length < StopSitePolicyV5.pauseProgressFixes) return false;
      final last =
          run.sublist(run.length - StopSitePolicyV5.pauseProgressFixes);
      for (var index = 1; index < last.length; index += 1) {
        if (last[index].distance <= last[index - 1].distance) return false;
      }
      return last.last.point.capturedAt
              .difference(last.first.point.capturedAt) >=
          StopSitePolicyV5.pauseProgressSpan;
    }
    final span =
        outside.point.capturedAt.difference(run.first.point.capturedAt);
    if (span < StopSitePolicyV5.stopProgressSpan) return false;
    if (run.any((fix) => fix.distance > outside.distance)) return false;
    return _distanceTrend(run) >=
        StopSitePolicyV5.stopProgressTrendMetersPerSecond;
  }

  /// One-time re-anchoring of a pause (`S4`): consecutive outside fixes over
  /// [StopSitePolicyV5.reanchorSpan] that agree with each other and make no
  /// progress were the place all along.
  List<DwellFix>? _reanchorCluster(
      _Stay stay, _Outside outside, double fixSigma) {
    final run = <_Outside>[...stay.outsideRun, outside];
    if (run.length < StopSitePolicyV5.reanchorFixes) return null;
    final last = run.sublist(run.length - StopSitePolicyV5.reanchorFixes);
    if (last.last.point.capturedAt.difference(last.first.point.capturedAt) <
        StopSitePolicyV5.reanchorSpan) {
      return null;
    }
    final fixes = <DwellFix>[
      for (final fix in last)
        DwellFix(
          latitude: fix.point.latitude,
          longitude: fix.point.longitude,
          sigmaMeters: fix.sigma,
          capturedAt: fix.point.capturedAt,
        ),
    ];
    final centre = DwellRun.centreOf(fixes);
    for (final fix in fixes) {
      final radius = StopSitePolicyV5.holdRadiusMeters(
        centreSigmaMeters: centre.sigmaMeters,
        fixSigmaMeters: fix.sigmaMeters,
      );
      if (_meters(
              centre.latitude, centre.longitude, fix.latitude, fix.longitude) >
          radius) {
        return null;
      }
    }
    if (DwellRun.trendSpeedMetersPerSecond(fixes) >
        StopSitePolicy.dwellMaximumTrendSpeedMetersPerSecond) {
      return null;
    }
    return fixes;
  }

  /// Whether moving activity is confirmed at [at]: two moving readings at
  /// most [StopSitePolicyV5.confirmedReadingsWindow] apart, the newest at most
  /// [StopSitePolicyV5.confirmedReadingFreshness] old, or one moving
  /// transition that recent; only evidence after [since] counts.
  bool _confirmedActivity(DateTime at, {DateTime? since}) {
    final freshness = StopSitePolicyV5.confirmedReadingFreshness;
    final transition = _lastMovingTransitionAt;
    if (transition != null &&
        (since == null || transition.isAfter(since)) &&
        !transition.isAfter(at) &&
        at.difference(transition) <= freshness) {
      return true;
    }
    final times = _movingReadingTimes
        .where((time) =>
            (since == null || time.isAfter(since)) && !time.isAfter(at))
        .toList();
    if (times.length < 2) return false;
    final newest = times.last;
    if (at.difference(newest) > freshness) return false;
    final previous = times[times.length - 2];
    return newest.difference(previous) <=
        StopSitePolicyV5.confirmedReadingsWindow;
  }

  void _applyReadings(LocationSample sample, List<ActivitySnapshot> readings) {
    final capturedAt = sample.capturedAt;
    final all = <ActivitySnapshot>[
      ...readings.where((reading) => reading.recordedAt != null),
      if (sample.capturedActivity case final attached?
          when attached.recordedAt != null)
        attached,
    ]..sort((a, b) => a.recordedAt!.compareTo(b.recordedAt!));
    for (final reading in all) {
      final key =
          '${reading.source}|${reading.recordedAt!.microsecondsSinceEpoch}|'
          '${reading.type.name}|${reading.confidence}';
      if (_recentReadingKeys.contains(key)) continue;
      _recentReadingKeys.add(key);
      while (_recentReadingKeys.length > 128) {
        _recentReadingKeys.removeAt(0);
      }
      final recordedAt = reading.recordedAt!;
      final at = recordedAt.isAfter(capturedAt) ? capturedAt : recordedAt;
      _gate.add(reading, at);
      _activitySeen = true;
      final latest = _latestReading?.recordedAt;
      if (latest == null || !recordedAt.isBefore(latest)) {
        _latestReading = reading;
      }
      if (MotionPolicyV2.isMovingTransitionEnter(reading) ||
          MotionPolicyV2.isStillTransitionExit(reading)) {
        final previous = _lastMovingTransitionAt;
        if (previous == null || recordedAt.isAfter(previous)) {
          _lastMovingTransitionAt = recordedAt;
        }
      }
      if (StopSitePolicy.isMovingEvidence(
        reading,
        movingConfidenceThreshold: config.movingConfidenceThreshold,
      )) {
        final previous = _lastMovingEvidenceAt;
        if (previous == null || recordedAt.isAfter(previous)) {
          _lastMovingEvidenceAt = recordedAt;
        }
        if (reading.source != MotionPolicyV2.transitionSource) {
          _movingReadingTimes
            ..add(recordedAt)
            ..sort();
          while (_movingReadingTimes.length > 16) {
            _movingReadingTimes.removeAt(0);
          }
        }
      }
    }
  }

  ActivitySnapshot? _freshReading(DateTime at) {
    final reading = _latestReading;
    final recordedAt = reading?.recordedAt;
    if (reading == null || recordedAt == null) return null;
    return at.difference(recordedAt) <= config.activityFreshnessThreshold
        ? reading
        : null;
  }

  /// The point a fix is compared with (`K1`): the last accepted point, or
  /// during a stay its centre, timed at its newest held fix and widened by
  /// its radius.
  _Reference _reference(TrackPoint last, double fixSigma) {
    final stay = _stay;
    if (stay == null) {
      return _Reference(
        latitude: last.latitude,
        longitude: last.longitude,
        time: last.capturedAt,
        sigma: _pointSigma(last),
        radius: 0,
      );
    }
    final centreSigma = _centreSigma(stay);
    return _Reference(
      latitude: stay.centre.latitude,
      longitude: stay.centre.longitude,
      time: stay.lastHeldAt ?? last.capturedAt,
      sigma: centreSigma,
      radius: StopSitePolicyV5.holdRadiusMeters(
        centreSigmaMeters: centreSigma,
        fixSigmaMeters: fixSigma,
      ),
    );
  }

  /// Recent speed before [at]: the larger of the median leg speed and the
  /// median precise Doppler speed of the accepted fixes in the minute before.
  double _referenceSpeed(DateTime at) {
    final window = _recentAccepted
        .where(
          (point) =>
              !point.capturedAt.isAfter(at) &&
              at.difference(point.capturedAt) <= KinematicPolicy.contextWindow,
        )
        .toList();
    final legs = <double>[];
    for (var index = 1; index < window.length; index += 1) {
      final seconds = window[index]
              .capturedAt
              .difference(window[index - 1].capturedAt)
              .inMilliseconds /
          1000;
      if (seconds <= 0) continue;
      legs.add(
        _meters(
              window[index - 1].latitude,
              window[index - 1].longitude,
              window[index].latitude,
              window[index].longitude,
            ) /
            seconds,
      );
    }
    final doppler = <double>[
      for (final point in window)
        if (KinematicPolicy.classify(
              speed: point.speed,
              speedAccuracy: point.speedAccuracy,
            ) ==
            DopplerClass.precise)
          point.speed!,
    ];
    return math.max(_median(legs) ?? 0, _median(doppler) ?? 0);
  }

  double _effectiveSigma(LocationSample sample) =>
      KinematicPolicy.effectiveSigma(
        reportedSigmaMeters: MotionPolicyV2.sigmaMeters(
          horizontalAccuracy: sample.horizontalAccuracy,
          hasSpeedAccuracy: sample.speedAccuracy != null,
          hasVerticalAccuracy: sample.verticalAccuracy != null,
          fallbackAccuracyMeters: config.maximumAcceptedAccuracyMeters,
          producedByAccessory: sample.isProducedByAccessory,
        ),
        observedSigmaMeters: _observedSigma(),
      );

  double _pointSigma(TrackPoint point) => KinematicPolicy.effectiveSigma(
        reportedSigmaMeters: MotionPolicyV2.sigmaMeters(
          horizontalAccuracy: point.horizontalAccuracy,
          hasSpeedAccuracy: point.speedAccuracy != null,
          hasVerticalAccuracy: point.verticalAccuracy != null,
          fallbackAccuracyMeters: config.maximumAcceptedAccuracyMeters,
        ),
        observedSigmaMeters: _observedSigma(),
      );

  /// What the fixes show: the stay's scatter during a stay, otherwise the
  /// moving route's second differences.
  double? _observedSigma() {
    final stay = _stay;
    if (stay != null) {
      final scatter = _stayScatter(stay);
      if (scatter != null) return scatter;
    }
    return KinematicPolicy.observedMovingSigma(<KinematicPoint>[
      for (final point in _recentAccepted)
        KinematicPoint(
          latitude: point.latitude,
          longitude: point.longitude,
          capturedAt: point.capturedAt,
        ),
    ]);
  }

  double? _stayScatter(_Stay stay) {
    final members = stay.members;
    if (members.length < 5) return null;
    final distances = <double>[
      for (final member in members)
        _meters(
          stay.centre.latitude,
          stay.centre.longitude,
          member.latitude,
          member.longitude,
        ),
    ];
    return _median(distances)! / KinematicPolicy.rayleighMedianFactor;
  }

  double _centreSigma(_Stay stay) {
    final members = stay.members;
    final base = members.isEmpty
        ? stay.centre.sigmaMeters
        : _median(members.map((member) => member.sigmaMeters))!;
    return KinematicPolicy.effectiveSigma(
      reportedSigmaMeters: base,
      observedSigmaMeters: _stayScatter(stay),
    );
  }

  StopSiteAnchor _centreOf(List<DwellFix> members) {
    if (members.isEmpty) {
      return _stay?.centre ??
          const StopSiteAnchor(latitude: 0, longitude: 0, sigmaMeters: 1.5);
    }
    return DwellRun.centreOf(members);
  }

  bool _isGnss(LocationSample sample) =>
      UncertaintyModel.inferOriginFromEvidence(
        horizontalAccuracy: sample.horizontalAccuracy,
        hasSpeedAccuracy: sample.speedAccuracy != null,
        hasVerticalAccuracy: sample.verticalAccuracy != null,
        producedByAccessory: sample.isProducedByAccessory,
      ) ==
      FixOriginClass.gnss;

  bool _isNetwork(LocationSample sample) =>
      UncertaintyModel.inferOriginFromEvidence(
        horizontalAccuracy: sample.horizontalAccuracy,
        hasSpeedAccuracy: sample.speedAccuracy != null,
        hasVerticalAccuracy: sample.verticalAccuracy != null,
        producedByAccessory: sample.isProducedByAccessory,
      ) ==
      FixOriginClass.network;

  bool _isGnssPoint(TrackPoint point) =>
      UncertaintyModel.inferOriginFromEvidence(
        horizontalAccuracy: point.horizontalAccuracy,
        hasSpeedAccuracy: point.speedAccuracy != null,
        hasVerticalAccuracy: point.verticalAccuracy != null,
      ) ==
      FixOriginClass.gnss;

  static FixQualityDecision _withFlags(
          FixQualityDecision decision, int flags) =>
      FixQualityDecision(
        acceptedForGeometry: decision.acceptedForGeometry,
        acceptedForMotionEvidence: decision.acceptedForMotionEvidence,
        issues: decision.issues,
        policyVersion: decision.policyVersion,
        qualityFlags: decision.qualityFlags | flags,
        rejectionReason: decision.rejectionReason,
      );

  static double _distanceTrend(List<_Outside> run) {
    if (run.length < 2) return 0;
    final origin = run.first.point.capturedAt;
    final times = <double>[
      for (final fix in run)
        fix.point.capturedAt.difference(origin).inMilliseconds / 1000,
    ];
    final meanTime = times.reduce((a, b) => a + b) / times.length;
    final meanDistance =
        run.map((fix) => fix.distance).reduce((a, b) => a + b) / run.length;
    var covariance = 0.0;
    var variance = 0.0;
    for (var index = 0; index < run.length; index += 1) {
      final dt = times[index] - meanTime;
      covariance += dt * (run[index].distance - meanDistance);
      variance += dt * dt;
    }
    return variance <= 0 ? 0 : covariance / variance;
  }

  static double _meters(
    double latitude1,
    double longitude1,
    double latitude2,
    double longitude2,
  ) =>
      TrackGeodesy.sphericalHaversineMeters(
        latitude1,
        longitude1,
        latitude2,
        longitude2,
      );

  static double? _median(Iterable<double> values) {
    final sorted = values.toList()..sort();
    if (sorted.isEmpty) return null;
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2;
  }
}

/// A stored fix fed back to [RouteDecisionEngine.restore].
final class RestoredFix {
  const RestoredFix({
    required this.point,
    required this.sample,
    this.readings = const <ActivitySnapshot>[],
  });

  final TrackPoint point;
  final LocationSample sample;
  final List<ActivitySnapshot> readings;
}

enum _Kind {
  accepted,
  rejected,
  suspect,
  reanchor,
  held,
  outlier,
  heldReanchor,
  leave
}

/// One planned decision of [RouteDecisionEngine.decide].
final class DecisionStep {
  DecisionStep._({
    required this.decision,
    required _Kind kind,
    required this.passedVersion1,
    required this.capturedAt,
    this.armed = false,
    this.stopChange,
    this.promote,
    this.stayCurrentBefore = false,
    this.stayExplainsGap = false,
    this.unknownEvidence = false,
    DwellFix? member,
    _Outside? outside,
    _Suspect? suspect,
    StopSiteAnchor? reanchorCentre,
    List<DwellFix> reanchorMembers = const <DwellFix>[],
    _Stay? startedStay,
  })  : _kind = kind,
        _member = member,
        _outside = outside,
        _suspect = suspect,
        _reanchorCentre = reanchorCentre,
        _reanchorMembers = reanchorMembers,
        _startedStay = startedStay;

  /// The fix's quality decision.
  final FixQualityDecision decision;

  /// The stop record change to store with the fix, if any.
  final TrackStopChange? stopChange;

  /// The centre the stay holds around from now on, when it became a stop.
  final StopSiteAnchor? promote;

  /// Whether a stay was current before this fix.
  final bool stayCurrentBefore;

  /// Rule `C1`: whether that stay explains a gap that ends at this accepted
  /// fix.
  final bool stayExplainsGap;

  /// Whether the fix carried no evidence either way (no activity readings on
  /// the route and no usable Doppler speed).
  final bool unknownEvidence;

  /// Whether the fix passed the version 1 checks.
  final bool passedVersion1;

  final DateTime capturedAt;

  /// Whether the fix came after a silence that makes far fixes prove
  /// themselves.
  final bool armed;

  final _Kind _kind;
  final DwellFix? _member;
  final _Outside? _outside;
  final _Suspect? _suspect;
  final StopSiteAnchor? _reanchorCentre;
  final List<DwellFix> _reanchorMembers;
  final _Stay? _startedStay;

  /// Whether the fix starts a stay.
  bool get startsStay => _startedStay != null;

  /// Whether the kinematic rules held the fix back.
  bool get suspected => _kind == _Kind.suspect;
}

final class _Reference {
  const _Reference({
    required this.latitude,
    required this.longitude,
    required this.time,
    required this.sigma,
    required this.radius,
  });

  final double latitude;
  final double longitude;
  final DateTime time;
  final double sigma;
  final double radius;
}

final class _Suspect {
  const _Suspect(this.point, this.sigma);

  final KinematicPoint point;
  final double sigma;
}

final class _Outside {
  const _Outside({
    required this.point,
    required this.distance,
    required this.sigma,
  });

  final KinematicPoint point;
  final double distance;
  final double sigma;
}

final class _Stay {
  _Stay({
    required this.centre,
    required this.anchorPointId,
    required this.startedAt,
    required DwellFix? anchorMember,
    DateTime? clockStartedAt,
  }) : clockStartedAt = clockStartedAt ?? startedAt {
    if (anchorMember != null) members.add(anchorMember);
  }

  StopSiteAnchor centre;
  final String? anchorPointId;
  final DateTime startedAt;

  /// Where the two minutes that make a stop start counting: [startedAt],
  /// unless the movement may have gone on into a silence after the anchor.
  final DateTime clockStartedAt;
  final List<DwellFix> members = <DwellFix>[];
  final List<_Outside> outsideRun = <_Outside>[];
  bool isStop = false;
  bool recordOpen = false;
  bool stillSeen = false;
  bool reanchored = false;
  int heldCount = 0;
  int? firstHeldSequence;
  int? lastHeldSequence;
  DateTime? lastHeldAt;

  void addMember(DwellFix member) {
    members.add(member);
    while (members.length > RouteDecisionEngine.maximumStayMembers) {
      members.removeAt(0);
    }
  }
}

/// What [RouteDecisionEngine] decides from, rebuilt from stored rows or
/// normalized to what a live fix will store.
abstract final class RouteDecisionInputs {
  /// The activity reading [point] stored as attached to its fix.
  static ActivitySnapshot activityOf(TrackPoint point) => ActivitySnapshot(
        type: point.activityType,
        confidence: point.activityConfidence,
        recordedAt: point.activityRecordedAt ??
            (point.activityAge == null
                ? null
                : point.capturedAt.subtract(point.activityAge!)),
        evidenceState: point.activityEvidenceState,
        source: point.activitySource ?? 'platform_activity',
        rawType: point.activityRawType,
        age: point.activityAge,
        probabilities: point.activityProbabilities,
      );

  /// The fix [point] was stored from, as the engine judges it.
  static RestoredFix restoredFix(TrackPoint point) => RestoredFix(
        point: point,
        sample: sampleOf(point),
        readings: point.activityReadings,
      );

  /// The sample [point] was stored from.
  static LocationSample sampleOf(TrackPoint point) => LocationSample(
        latitude: point.latitude,
        longitude: point.longitude,
        capturedAt: point.capturedAt,
        altitude: point.altitude,
        horizontalAccuracy: point.horizontalAccuracy,
        verticalAccuracy: point.verticalAccuracy,
        speed: point.speed,
        speedAccuracy: point.speedAccuracy,
        heading: point.heading,
        headingAccuracy: point.headingAccuracy,
        isMocked: point.isMocked,
        mockDetectionAvailable: point.mockDetectionAvailable,
        mockEvidence: point.mockEvidence,
        provider: point.provider,
        eventId: point.nativeEventId,
        trackId: point.trackId,
        capturedActivity: activityOf(point),
        capturedMotionState: point.motionState,
        nativeReceivedAt: point.nativeReceivedAt,
        providerTimeDeltaMsAtReceipt: point.providerTimeDeltaMsAtReceipt,
        monotonicFixNanos: point.monotonicFixNanos,
        monotonicReceivedNanos: point.monotonicReceivedNanos,
        monotonicDomainId: point.monotonicDomainId,
        captureGenerationId: point.captureGenerationId,
        nativeSessionStartedAt: point.nativeSessionStartedAt,
        nativeLifecycle: point.nativeLifecycle,
        samplingProfile: point.samplingProfile,
        stepCount: point.stepCount,
        activityReadings: point.activityReadings,
      );

  /// [sample] carrying [activity], the reading that will be stored with it,
  /// so a live decision uses exactly the evidence a later one re-reads.
  static LocationSample withActivity(
    LocationSample sample,
    ActivitySnapshot activity,
  ) =>
      identical(sample.capturedActivity, activity)
          ? sample
          : LocationSample(
              latitude: sample.latitude,
              longitude: sample.longitude,
              capturedAt: sample.capturedAt,
              altitude: sample.altitude,
              horizontalAccuracy: sample.horizontalAccuracy,
              verticalAccuracy: sample.verticalAccuracy,
              speed: sample.speed,
              speedAccuracy: sample.speedAccuracy,
              heading: sample.heading,
              headingAccuracy: sample.headingAccuracy,
              isMocked: sample.isMocked,
              mockDetectionAvailable: sample.mockDetectionAvailable,
              isProducedByAccessory: sample.isProducedByAccessory,
              mockEvidence: sample.mockEvidence,
              provider: sample.provider,
              eventId: sample.eventId,
              trackId: sample.trackId,
              capturedActivity: activity,
              capturedMotionState: sample.capturedMotionState,
              capturedMotionEvidence: sample.capturedMotionEvidence,
              nativeReceivedAt: sample.nativeReceivedAt,
              providerTimeDeltaMsAtReceipt: sample.providerTimeDeltaMsAtReceipt,
              monotonicFixNanos: sample.monotonicFixNanos,
              monotonicReceivedNanos: sample.monotonicReceivedNanos,
              monotonicDomainId: sample.monotonicDomainId,
              captureGenerationId: sample.captureGenerationId,
              nativeSessionStartedAt: sample.nativeSessionStartedAt,
              nativeLifecycle: sample.nativeLifecycle,
              samplingProfile: sample.samplingProfile,
              stepCount: sample.stepCount,
              activityReadings: sample.activityReadings,
              activityReadingsDropped: sample.activityReadingsDropped,
              stepCoverage: sample.stepCoverage,
              profileTransitions: sample.profileTransitions,
            );
}
