import '../domain/derived_geometry.dart';
import '../domain/route_geometry.dart';
import '../domain/route_geometry_processor.dart';
import '../domain/route_review.dart';
import '../domain/track_point.dart';
import '../domain/track_data_page.dart';
import '../domain/tracking_error.dart';
import '../domain/tracking_start.dart';
import '../storage/track_repository.dart';
import 'stop_episode_detector.dart';
import 'uncertainty_route_smoother.dart';
import '../domain/motion_policy.dart';
import '../domain/stop_site.dart';
import '../domain/track_geodesy.dart';
import '../domain/tracking_config.dart';

/// Runs optional post-capture derivation without delaying raw point commits.
final class DerivedGeometryService {
  const DerivedGeometryService(this.repository, {this.pageSize = 500});

  final TrackRepository repository;
  final int pageSize;

  Future<DerivedGeometryRun> derive({
    required TrackingOwner owner,
    required String trackId,
    DerivedGeometryRequest request = const DerivedGeometryRequest(),
  }) async {
    if (repository is! StreamingTrackRepository ||
        repository is! DerivedGeometryRepository) {
      throw const TrackingStorageException(
        code: 'capability_unsupported',
        message: 'This repository does not support derived geometry.',
      );
    }
    if (request.algorithm !=
            DerivedGeometryAlgorithm.exponentialMovingAverage &&
        request.algorithm !=
            DerivedGeometryAlgorithm.uncertaintyWeightedSmoothing &&
        request.algorithm != DerivedGeometryAlgorithm.stopAwareRouteCleaning) {
      throw const TrackingConfigurationException(
        code: 'derived_algorithm_unsupported',
        message: 'The built-in service supports exponential_moving_average, '
            'uncertainty_weighted_smoothing and stop_aware_route_cleaning.',
      );
    }
    if (pageSize < 1 || pageSize > 1000) {
      throw ArgumentError.value(pageSize, 'pageSize');
    }
    final stream = repository as StreamingTrackRepository;
    final store = repository as DerivedGeometryRepository;
    final snapshot = await stream.createTrackDataSnapshot(
      owner: owner,
      trackId: trackId,
    );
    final cleaning =
        request.algorithm == DerivedGeometryAlgorithm.stopAwareRouteCleaning;
    final detector = cleaning
        ? StopEpisodeDetector(
            (await repository.getTrack(trackId))?.config ??
                const TrackingConfig(),
          )
        : null;
    final run = await store.beginDerivedGeometryRun(
      owner: owner,
      trackId: trackId,
      request: request.algorithm ==
              DerivedGeometryAlgorithm.uncertaintyWeightedSmoothing
          ? _withAppliedConfiguration(
              request,
              const UncertaintyWeightedRouteSmoother().classifier.configuration,
            )
          : cleaning
              ? _withAppliedConfiguration(
                  request,
                  <String, Object?>{
                    ...const UncertaintyWeightedRouteSmoother()
                        .classifier
                        .configuration,
                    'stopHoldRadiusFloorMeters':
                        MotionPolicyV2.holdRadiusFloorMeters,
                    'stopHoldChiSquare': MotionPolicyV2.holdChiSquare,
                    'stopEpisodeMinimumSpanSeconds':
                        MotionPolicyV2.stillEpisodeMinimumSpan.inSeconds,
                    'stopDepartureSpeedMetersPerSecond':
                        MotionPolicyV2.departureSpeedMetersPerSecond,
                    'stopSustainedOutsideSeconds':
                        MotionPolicyV2.sustainedOutsideDuration.inSeconds,
                    'stopMovingEvidenceWindowSeconds':
                        StopSitePolicy.movingEvidenceWindow.inSeconds,
                    'stopDwellMinimumSeconds':
                        StopSitePolicy.dwellMinimumDuration.inSeconds,
                    'stopDwellMaximumTrendMetersPerSecond':
                        StopSitePolicy.dwellMaximumTrendSpeedMetersPerSecond,
                    'stopMaximumCollapseDistanceMeters':
                        StopEpisodeDetector.maximumCollapseDistanceMeters,
                  },
                  algorithmVersion:
                      DerivedGeometryAlgorithm.stopAwareRouteCleaningVersion,
                )
              : request,
      sourceMaximumSequence: snapshot.upperSequence,
    );
    try {
      String? segmentCursor;
      do {
        final segments = await stream.listSegmentPage(
          owner: owner,
          trackId: trackId,
          limit: 100,
          cursor: segmentCursor,
          snapshot: snapshot,
        );
        for (final segment in segments.items) {
          if (request.algorithm ==
                  DerivedGeometryAlgorithm.uncertaintyWeightedSmoothing ||
              detector != null) {
            await _deriveUncertaintyWeightedSegment(
              stream: stream,
              store: store,
              owner: owner,
              snapshot: snapshot,
              segmentId: segment.id,
              runId: run.id,
              stops: detector,
            );
            continue;
          }
          double? latitude;
          double? longitude;
          String? pointCursor;
          do {
            final points = await stream.listPointPage(
              owner: owner,
              trackId: trackId,
              segmentId: segment.id,
              limit: pageSize,
              cursor: pointCursor,
              acceptedOnly: true,
              snapshot: snapshot,
            );
            final derived = <DerivedGeometryPoint>[];
            for (final point in points.items) {
              latitude = latitude == null
                  ? point.latitude
                  : latitude +
                      request.smoothingFactor * (point.latitude - latitude);
              // Blend the short way across the antimeridian, then wrap.
              longitude = longitude == null
                  ? point.longitude
                  : TrackGeodesy.wrapLongitude(
                      longitude +
                          request.smoothingFactor *
                              TrackGeodesy.longitudeDelta(
                                longitude,
                                point.longitude,
                              ),
                    );
              derived.add(DerivedGeometryPoint(
                runId: run.id,
                sourcePointId: point.id,
                segmentId: point.segmentId,
                sequence: point.sequence,
                latitude: latitude,
                longitude: longitude,
              ));
            }
            await store.appendDerivedGeometryPoints(
              runId: run.id,
              points: derived,
            );
            pointCursor = points.nextCursor;
          } while (pointCursor != null);
        }
        segmentCursor = segments.nextCursor;
      } while (segmentCursor != null);
      return await store.completeDerivedGeometryRun(run.id);
    } on Object {
      await store.failDerivedGeometryRun(run.id, code: 'derivation_failed');
      rethrow;
    }
  }

  /// [request] with the parameters, and optionally the version, the built-in
  /// algorithm applies, so the run's provenance records them.
  static DerivedGeometryRequest _withAppliedConfiguration(
    DerivedGeometryRequest request,
    Map<String, Object?> applied, {
    String? algorithmVersion,
  }) =>
      DerivedGeometryRequest(
        name: request.name,
        algorithm: request.algorithm,
        algorithmVersion: algorithmVersion ?? request.algorithmVersion,
        smoothingFactor: request.smoothingFactor,
        mapDataSource: request.mapDataSource,
        mapDataVersion: request.mapDataVersion,
        processorConfiguration: <String, Object?>{
          ...request.processorConfiguration,
          ...applied,
        },
      );

  Future<void> _deriveUncertaintyWeightedSegment({
    required StreamingTrackRepository stream,
    required DerivedGeometryRepository store,
    required TrackingOwner owner,
    required TrackDataSnapshot snapshot,
    required String segmentId,
    required String runId,
    StopEpisodeDetector? stops,
  }) async {
    final raw = <TrackPoint>[];
    // Stop cleaning also reads the points a stop hold rejected: they are the
    // evidence of the stop on routes recorded under quality policies 2 and 3.
    final held = <TrackPoint>[];
    String? cursor;
    do {
      final page = await stream.listPointPage(
        owner: owner,
        trackId: snapshot.trackId,
        segmentId: segmentId,
        limit: pageSize,
        cursor: cursor,
        acceptedOnly: stops == null,
        snapshot: snapshot,
      );
      for (final point in page.items) {
        (point.accepted ? raw : held).add(point);
      }
      cursor = page.nextCursor;
    } while (cursor != null);
    final smoothed = const UncertaintyWeightedRouteSmoother().smooth(raw);
    if (stops != null) {
      // Each stop collapses to its robust centre; a point too far from it
      // keeps its raw position. The 1:1 mapping to source points is kept.
      for (final stop in stops.detect(raw, heldEvidence: held)) {
        for (var index = stop.firstIndex; index <= stop.lastIndex; index += 1) {
          final point = raw[index];
          final distance = TrackGeodesy.sphericalHaversineMeters(
            stop.latitude,
            stop.longitude,
            point.latitude,
            point.longitude,
          );
          if (distance > StopEpisodeDetector.maximumCollapseDistanceMeters) {
            smoothed[index] = point;
            continue;
          }
          smoothed[index] = point.withCoordinates(
            latitude: stop.latitude,
            longitude: stop.longitude,
          );
        }
      }
    }
    for (var offset = 0; offset < smoothed.length; offset += pageSize) {
      final end = (offset + pageSize).clamp(0, smoothed.length);
      await store.appendDerivedGeometryPoints(
        runId: runId,
        points: <DerivedGeometryPoint>[
          for (final point in smoothed.sublist(offset, end))
            DerivedGeometryPoint(
              runId: runId,
              sourcePointId: point.id,
              segmentId: point.segmentId,
              sequence: point.sequence,
              latitude: point.latitude,
              longitude: point.longitude,
            ),
        ],
      );
    }
  }

  /// Runs an opt-in host map matcher in bounded overlapping pages.
  ///
  /// Low-confidence, missing, invalid, overly distant, or failed matches fall
  /// back to the corresponding immutable raw anchor.
  Future<DerivedGeometryRun> deriveWithProcessor({
    required TrackingOwner owner,
    required String trackId,
    required RouteGeometryProcessor processor,
    DerivedRouteMode mode = DerivedRouteMode.mapMatched,
    double minimumConfidence = 0.65,
    double maximumSnapDistanceMeters = 100,
    int overlapPointCount = 2,
  }) async {
    if (repository is! StreamingTrackRepository ||
        repository is! DerivedGeometryRepository) {
      throw const TrackingStorageException(
        code: 'capability_unsupported',
        message: 'This repository does not support derived geometry.',
      );
    }
    if (processor.name.trim().isEmpty || processor.version.trim().isEmpty) {
      throw const TrackingConfigurationException(
        code: 'invalid_route_geometry_processor',
        message: 'Processor name and version are required.',
      );
    }
    if (minimumConfidence < 0 || minimumConfidence > 1) {
      throw ArgumentError.value(minimumConfidence, 'minimumConfidence');
    }
    if (maximumSnapDistanceMeters <= 0) {
      throw ArgumentError.value(
        maximumSnapDistanceMeters,
        'maximumSnapDistanceMeters',
      );
    }
    if (overlapPointCount < 0 || overlapPointCount >= pageSize) {
      throw ArgumentError.value(overlapPointCount, 'overlapPointCount');
    }
    final stream = repository as StreamingTrackRepository;
    final store = repository as DerivedGeometryRepository;
    final snapshot = await stream.createTrackDataSnapshot(
      owner: owner,
      trackId: trackId,
    );
    final run = await store.beginDerivedGeometryRun(
      owner: owner,
      trackId: trackId,
      sourceMaximumSequence: snapshot.upperSequence,
      request: DerivedGeometryRequest(
        name: mode.name,
        algorithm: 'host_route_geometry_processor',
        algorithmVersion: processor.version,
        mapDataSource: processor.name,
        mapDataVersion: processor.version,
        processorConfiguration: <String, Object?>{
          'mode': mode.name,
          'minimumConfidence': minimumConfidence,
          'maximumSnapDistanceMeters': maximumSnapDistanceMeters,
          'pageSize': pageSize,
          'overlapPointCount': overlapPointCount,
          'rawFallback': true,
        },
      ),
    );
    try {
      String? segmentCursor;
      var pageNumber = 0;
      do {
        final segments = await stream.listSegmentPage(
          owner: owner,
          trackId: trackId,
          limit: 100,
          cursor: segmentCursor,
          snapshot: snapshot,
        );
        for (final segment in segments.items) {
          var overlap = <TrackPoint>[];
          String? pointCursor;
          do {
            final page = await stream.listPointPage(
              owner: owner,
              trackId: trackId,
              segmentId: segment.id,
              limit: pageSize - overlapPointCount,
              cursor: pointCursor,
              acceptedOnly: true,
              snapshot: snapshot,
            );
            final input = <TrackPoint>[...overlap, ...page.items];
            pageNumber += 1;
            RouteGeometryProcessorResult? processed;
            try {
              processed = await processor.process(
                RouteGeometryProcessorRequest(
                  trackId: trackId,
                  mode: mode,
                  points: input.map(RouteGeometryProcessorPoint.fromTrackPoint),
                  pageNumber: pageNumber,
                  isFinalPage: page.nextCursor == null,
                  overlapPointCount: overlap.length,
                ),
              );
            } on Object {
              processed = null;
            }
            final bySource = <String, ProcessedRoutePoint>{
              for (final point
                  in processed?.points ?? const <ProcessedRoutePoint>[])
                point.sourcePointId: point,
            };
            await store.appendDerivedGeometryPoints(
              runId: run.id,
              points: <DerivedGeometryPoint>[
                for (final raw in page.items)
                  _safeProcessedPoint(
                    runId: run.id,
                    raw: raw,
                    processed: bySource[raw.id],
                    minimumConfidence: minimumConfidence,
                    maximumSnapDistanceMeters: maximumSnapDistanceMeters,
                  ),
              ],
            );
            overlap = input.length <= overlapPointCount
                ? input
                : input.sublist(input.length - overlapPointCount);
            pointCursor = page.nextCursor;
          } while (pointCursor != null);
        }
        segmentCursor = segments.nextCursor;
      } while (segmentCursor != null);
      return await store.completeDerivedGeometryRun(run.id);
    } on Object {
      await store.failDerivedGeometryRun(
        run.id,
        code: 'route_processor_derivation_failed',
      );
      rethrow;
    }
  }

  DerivedGeometryPoint _safeProcessedPoint({
    required String runId,
    required TrackPoint raw,
    required ProcessedRoutePoint? processed,
    required double minimumConfidence,
    required double maximumSnapDistanceMeters,
  }) {
    final valid = processed != null &&
        processed.matched &&
        processed.confidence.isFinite &&
        processed.confidence >= minimumConfidence &&
        processed.confidence <= 1 &&
        processed.latitude.isFinite &&
        processed.longitude.isFinite &&
        processed.latitude >= -90 &&
        processed.latitude <= 90 &&
        processed.longitude >= -180 &&
        processed.longitude <= 180 &&
        _distanceMeters(
              raw.latitude,
              raw.longitude,
              processed.latitude,
              processed.longitude,
            ) <=
            maximumSnapDistanceMeters;
    return DerivedGeometryPoint(
      runId: runId,
      sourcePointId: raw.id,
      segmentId: raw.segmentId,
      sequence: raw.sequence,
      latitude: valid ? processed.latitude : raw.latitude,
      longitude: valid ? processed.longitude : raw.longitude,
      confidence: valid ? processed.confidence : processed?.confidence,
      matched: valid,
    );
  }

  static double _distanceMeters(
    double latitude1,
    double longitude1,
    double latitude2,
    double longitude2,
  ) {
    return TrackGeodesy.sphericalHaversineMeters(
      latitude1,
      longitude1,
      latitude2,
      longitude2,
    );
  }

  /// Loads a small route for map display using explicit raw/derived geometry.
  /// Large routes should use repository pages directly.
  Future<TrackBundle> loadForMap({
    required TrackingOwner owner,
    required String trackId,
    TrackGeometrySelection geometry = const TrackGeometrySelection.raw(),
  }) async {
    final track = repository is OwnerScopedTrackRepository
        ? await (repository as OwnerScopedTrackRepository)
            .getTrackForOwner(owner, trackId)
        : await repository.getTrack(trackId);
    if (track == null || !owner.owns(track)) {
      throw const TrackingOwnershipException(
        code: 'track_not_found_in_owner_scope',
        message: 'The route is not available in the current owner scope.',
      );
    }
    final bundle = await repository.loadTrackBundle(trackId);
    if (geometry is RawTrackGeometry) return bundle;
    if (repository is! DerivedGeometryRepository) {
      throw const TrackingStorageException(
        code: 'capability_unsupported',
        message: 'This repository does not support derived geometry.',
      );
    }
    final derived = geometry as DerivedTrackGeometry;
    final run =
        await (repository as DerivedGeometryRepository).getDerivedGeometryRun(
      owner: owner,
      trackId: trackId,
      runId: derived.runId,
    );
    if (run?.algorithm == DerivedGeometryAlgorithm.routeQualityReview &&
        repository is RouteReviewRepository) {
      // A review keeps fixes at their recorded coordinates: its view is the
      // route with exactly the kept fixes accepted.
      final kept =
          await (repository as RouteReviewRepository).keptPointIdsOf(run!.id);
      return TrackBundle(
        track: bundle.track,
        segments: <TrackSegmentWithPoints>[
          for (final segment in bundle.segments)
            TrackSegmentWithPoints(
              segment: segment.segment,
              points: <TrackPoint>[
                for (final point in segment.points)
                  point.accepted == kept.contains(point.id)
                      ? point
                      : point.withAcceptance(
                          accepted: kept.contains(point.id),
                          rejectionReason: RouteReview.notKeptReason,
                        ),
              ],
            ),
        ],
        stops: bundle.stops,
        summary: bundle.summary,
      );
    }
    final rawPoints = <TrackPoint>[
      for (final segment in bundle.segments)
        for (final point in segment.points)
          if (point.accepted) point,
    ];
    final coordinates = await (repository as DerivedGeometryRepository)
        .derivedCoordinatesForSourcePoints(
      owner: owner,
      trackId: trackId,
      runId: derived.runId,
      sourcePointIds: rawPoints.map((point) => point.id),
    );
    return TrackBundle(
      track: bundle.track,
      segments: <TrackSegmentWithPoints>[
        for (final segment in bundle.segments)
          TrackSegmentWithPoints(
            segment: segment.segment,
            points: <TrackPoint>[
              for (final point in segment.points)
                if (!point.accepted)
                  point
                else
                  point.withCoordinates(
                    latitude: coordinates[point.id]!.latitude,
                    longitude: coordinates[point.id]!.longitude,
                  ),
            ],
          ),
      ],
      stops: bundle.stops,
      summary: bundle.summary,
    );
  }
}

/// Additive facade contract for post-capture route geometry.
abstract interface class TrackingGeometryController {
  Future<DerivedGeometryRun> deriveGeometry(
    String trackId, {
    DerivedGeometryRequest request,
  });

  Future<List<DerivedGeometryRun>> listDerivedGeometry(String trackId);

  Future<TrackBundle> loadTrackGeometry(
    String trackId, {
    TrackGeometrySelection geometry,
  });

  /// Assembles presentation geometry with the same continuity policy used by
  /// exports. Canonical points, segments, and gap evidence are not modified.
  Future<RouteGeometryReport> assembleTrackRouteGeometry(
    String trackId, {
    RouteGeometryContinuity continuity =
        RouteGeometryContinuity.mergeAutomaticCallbackGaps,
  });

  Future<void> deleteDerivedGeometry(String trackId, String runId);
}
