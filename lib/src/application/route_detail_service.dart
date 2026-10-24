import 'dart:isolate';

import '../domain/derived_geometry.dart';
import '../domain/motion_policy.dart';
import '../domain/route_summary.dart';
import '../domain/stop_site.dart';
import '../domain/track.dart';
import '../domain/track_geodesy.dart';
import '../domain/track_point.dart';
import '../domain/track_segment.dart';
import '../domain/track_stop.dart';
import '../domain/tracking_config.dart';
import '../domain/tracking_configuration_epoch.dart';
import '../domain/tracking_error.dart';
import '../domain/tracking_start.dart';
import '../storage/track_repository.dart';
import 'derived_geometry_service.dart';
import 'route_reviewer.dart';
import 'stop_episode_detector.dart';

/// Optional facade capability: route details kept in the route database
/// ([RouteSummary], [TripSummary]) and the current cleaned view.
abstract interface class TrackingSummaryController {
  /// [trackId]'s stored summary; a completed route recorded without live
  /// stop records has its stops derived first.
  Future<RouteSummary> routeSummary(String trackId);

  /// Totals over [tripId]'s legs.
  Future<TripSummary> tripSummary(String tripId);

  /// [trackId]'s current stop-aware cleaned view: the newest completed run
  /// when it covers the route's newest point under the current cleaning
  /// version, otherwise a new one. Older runs are deleted, and the cleaned
  /// distance is stored in the route's summary.
  Future<DerivedGeometryRun> currentCleanedGeometry(String trackId);
}

/// Keeps a route's derived details in the route database: stops for routes
/// recorded without live stop records, and the cleaned view's distance.
final class RouteDetailService {
  RouteDetailService(this.repository);

  final TrackRepository repository;

  /// Derives and stores [trackId]'s stops once it has completed, when its
  /// stops are still [TrackStopSource.pending]. Stops come from the stored
  /// points with the offline stay rule ([StopEpisodeDetector]); the points
  /// never change.
  Future<void> ensureStops(String trackId) async {
    final store = repository;
    if (store is! RouteSummaryRepository) return;
    final summaries = store as RouteSummaryRepository;
    final summary = await summaries.routeSummary(trackId);
    if (summary == null || summary.stopsSource != TrackStopSource.pending) {
      return;
    }
    final track = await repository.getTrack(trackId);
    if (track == null ||
        (track.status != TrackStatus.completed &&
            track.status != TrackStatus.failed)) {
      return;
    }
    final bundle = await repository.loadTrackBundle(trackId);
    await summaries.storeDerivedStops(
      trackId,
      deriveStops(bundle, track.config),
    );
  }

  /// Decides [trackId] again under the current rules ([RouteReviewer]) once
  /// it has completed under older ones, and stores the review beside what it
  /// recorded: its stops, gaps, quality runs, step decisions and corrected
  /// distance then come from the review. Its points, their acceptance, its
  /// measured distance and its uploads never change.
  Future<void> ensureReviewed(String trackId) async {
    final store = repository;
    if (store is! RouteReviewRepository) return;
    final reviews = store as RouteReviewRepository;
    if (!await reviews.awaitsReview(trackId)) return;
    final track = await repository.getTrack(trackId);
    if (track == null) return;
    final bundle = await repository.loadTrackBundle(trackId);
    final epochs = await reviews.configurationEpochsOf(trackId);
    final points = <TrackPoint>[
      for (final segment in bundle.segments) ...segment.points,
    ];
    final segments = <TrackSegment>[
      for (final segment in bundle.segments) segment.segment,
    ];
    final epochsById = <String, TrackingConfigurationEpoch>{
      for (final epoch in epochs) epoch.id: epoch,
    };
    final config = track.config;
    // A long route's replay runs off the UI isolate.
    final review = await Isolate.run(
      () => const RouteReviewer().review(
        trackId: trackId,
        points: points,
        segments: segments,
        epochs: epochsById,
        fallbackConfig: config,
      ),
    );
    await reviews.storeRouteReview(review);
  }

  /// Reviews completed routes still waiting for it, oldest first, [batch] at
  /// a time; with [owner], only that owner's.
  Future<void> backfillReviews({TrackingOwner? owner, int batch = 10}) async {
    final store = repository;
    if (store is! RouteReviewRepository) return;
    final reviews = store as RouteReviewRepository;
    final seen = <String>{};
    while (true) {
      final pending = (await reviews.tracksAwaitingReview(
        limit: batch,
        owner: owner,
      ))
          .where(seen.add)
          .toList();
      if (pending.isEmpty) return;
      for (final trackId in pending) {
        await ensureReviewed(trackId);
      }
    }
  }

  /// Derives stops for completed routes still waiting for them, oldest
  /// first, [batch] at a time; with [owner], only that owner's.
  Future<void> backfillStops({int batch = 20, TrackingOwner? owner}) async {
    final store = repository;
    if (store is! RouteSummaryRepository) return;
    final summaries = store as RouteSummaryRepository;
    final seen = <String>{};
    while (true) {
      final pending = (await summaries.tracksAwaitingStops(
        limit: batch,
        owner: owner,
      ))
          .where(seen.add)
          .toList();
      if (pending.isEmpty) return;
      for (final trackId in pending) {
        await ensureStops(trackId);
      }
    }
  }

  /// Stops of [bundle]'s segments by the offline stay rule.
  static List<TrackStop> deriveStops(
      TrackBundle bundle, TrackingConfig config) {
    final detector = StopEpisodeDetector(config);
    final stops = <TrackStop>[];
    for (final source in bundle.segments) {
      final accepted = source.points.where((point) => point.accepted).toList()
        ..sort((a, b) => a.sequence.compareTo(b.sequence));
      if (accepted.length < 2) continue;
      final held = source.points.where((point) => !point.accepted).toList();
      for (final episode in detector.detect(accepted, heldEvidence: held)) {
        final first = accepted[episode.firstIndex];
        final last = accepted[episode.lastIndex];
        final departure = episode.lastIndex + 1 < accepted.length
            ? accepted[episode.lastIndex + 1]
            : null;
        final members = <TrackPoint>[
          ...accepted.sublist(episode.firstIndex, episode.lastIndex + 1),
          ...held.where(
            (point) =>
                point.sequence > first.sequence &&
                point.sequence < (departure?.sequence ?? last.sequence + 1),
          ),
        ]..sort((a, b) => a.sequence.compareTo(b.sequence));
        final centre = DwellRun.centreOf(<DwellFix>[
          for (final point in members)
            DwellFix(
              latitude: point.latitude,
              longitude: point.longitude,
              sigmaMeters: MotionPolicyV2.sigmaMeters(
                horizontalAccuracy: point.horizontalAccuracy,
                hasSpeedAccuracy: point.speedAccuracy != null,
                hasVerticalAccuracy: point.verticalAccuracy != null,
                fallbackAccuracyMeters: config.maximumAcceptedAccuracyMeters,
              ),
              capturedAt: point.capturedAt,
            ),
        ]);
        stops.add(
          TrackStop(
            id: '',
            trackId: bundle.track.id,
            segmentId: source.segment.id,
            kind: TrackStopKind.dwell,
            latitude: episode.latitude,
            longitude: episode.longitude,
            centreSigmaMeters: centre.sigmaMeters,
            radiusMeters: MotionPolicyV2.holdRadiusMeters(
              anchorSigmaMeters: centre.sigmaMeters,
              fixSigmaMeters: centre.sigmaMeters,
            ),
            startedAt: first.capturedAt,
            lastSeenAt: members.last.capturedAt,
            endedAt: departure?.capturedAt ?? members.last.capturedAt,
            evidenceCount: members.length,
            qualityPolicyVersion: first.qualityPolicyVersion ?? 1,
            firstSequence: first.sequence,
            lastSequence: members.last.sequence,
            arrivalPointId: episode.firstIndex > 0
                ? accepted[episode.firstIndex - 1].id
                : null,
            departurePointId: departure?.id,
          ),
        );
      }
    }
    return stops;
  }

  /// See [TrackingSummaryController.currentCleanedGeometry].
  Future<DerivedGeometryRun> currentCleanedGeometry(
    TrackingOwner owner,
    String trackId,
  ) async {
    final store = repository;
    if (store is! DerivedGeometryRepository) {
      throw const TrackingStorageException(
        code: 'capability_unsupported',
        message: 'This repository does not support derived geometry.',
      );
    }
    final derived = store as DerivedGeometryRepository;
    final track = await repository.getTrack(trackId);
    if (track == null || !owner.owns(track)) {
      throw const TrackingOwnershipException(
        code: 'track_not_found_in_owner_scope',
        message: 'The route is not available in the current owner scope.',
      );
    }
    final runs = (await derived.listDerivedGeometryRuns(
      owner: owner,
      trackId: trackId,
    ))
        .where(
          (run) =>
              run.algorithm ==
                  DerivedGeometryAlgorithm.stopAwareRouteCleaning &&
              run.status == DerivedGeometryRunStatus.completed,
        )
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final newestSequence = track.nextSequence - 1;
    final reusable = runs.isNotEmpty &&
        runs.first.sourceMaximumSequence >= newestSequence &&
        runs.first.algorithmVersion ==
            DerivedGeometryAlgorithm.stopAwareRouteCleaningVersion;
    final service = DerivedGeometryService(repository);
    final current = reusable
        ? runs.first
        : await service.derive(
            owner: owner,
            trackId: trackId,
            request: const DerivedGeometryRequest(
              name: 'cleaned',
              algorithm: DerivedGeometryAlgorithm.stopAwareRouteCleaning,
            ),
          );
    for (final stale in runs.where((run) => run.id != current.id)) {
      await derived.deleteDerivedGeometryRun(
        owner: owner,
        trackId: trackId,
        runId: stale.id,
      );
    }
    if (store is RouteSummaryRepository) {
      final summaries = store as RouteSummaryRepository;
      final summary = await summaries.routeSummary(trackId);
      if (summary?.cleanedRunId != current.id) {
        final bundle = await service.loadForMap(
          owner: owner,
          trackId: trackId,
          geometry: TrackGeometrySelection.derived(current.id),
        );
        await summaries.recordCleanedGeometry(
          trackId,
          runId: current.id,
          distanceMeters: _acceptedPathMeters(bundle),
        );
      }
    }
    return current;
  }

  /// Length of [bundle]'s accepted points, segment by segment.
  static double _acceptedPathMeters(TrackBundle bundle) {
    var total = 0.0;
    for (final segment in bundle.segments) {
      TrackPoint? previous;
      for (final point in segment.points) {
        if (!point.accepted) continue;
        if (previous != null) {
          total += TrackGeodesy.sphericalHaversineMeters(
            previous.latitude,
            previous.longitude,
            point.latitude,
            point.longitude,
          );
        }
        previous = point;
      }
    }
    return total;
  }
}
