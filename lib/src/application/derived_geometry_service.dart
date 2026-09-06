import 'dart:math' as math;
import '../domain/derived_geometry.dart';
import '../domain/route_geometry.dart';
import '../domain/route_geometry_processor.dart';
import '../domain/track_point.dart';
import '../domain/track_data_page.dart';
import '../domain/tracking_error.dart';
import '../domain/tracking_start.dart';
import '../storage/track_repository.dart';
import 'uncertainty_route_smoother.dart';

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
    if (request.algorithm != 'exponential_moving_average' &&
        request.algorithm != 'uncertainty_weighted_smoothing') {
      throw const TrackingConfigurationException(
        code: 'derived_algorithm_unsupported',
        message: 'The built-in service supports exponential_moving_average '
            'and uncertainty_weighted_smoothing.',
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
    final run = await store.beginDerivedGeometryRun(
      owner: owner,
      trackId: trackId,
      request: request,
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
          if (request.algorithm == 'uncertainty_weighted_smoothing') {
            await _deriveUncertaintyWeightedSegment(
              stream: stream,
              store: store,
              owner: owner,
              snapshot: snapshot,
              segmentId: segment.id,
              runId: run.id,
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
              longitude = longitude == null
                  ? point.longitude
                  : longitude +
                      request.smoothingFactor * (point.longitude - longitude);
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

  Future<void> _deriveUncertaintyWeightedSegment({
    required StreamingTrackRepository stream,
    required DerivedGeometryRepository store,
    required TrackingOwner owner,
    required TrackDataSnapshot snapshot,
    required String segmentId,
    required String runId,
  }) async {
    final raw = <TrackPoint>[];
    String? cursor;
    do {
      final page = await stream.listPointPage(
        owner: owner,
        trackId: snapshot.trackId,
        segmentId: segmentId,
        limit: pageSize,
        cursor: cursor,
        acceptedOnly: true,
        snapshot: snapshot,
      );
      raw.addAll(page.items);
      cursor = page.nextCursor;
    } while (cursor != null);
    final smoothed = const UncertaintyWeightedRouteSmoother().smooth(raw);
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
    const radius = 6371008.8;
    final lat1 = latitude1 * math.pi / 180;
    final lat2 = latitude2 * math.pi / 180;
    final deltaLatitude = (latitude2 - latitude1) * math.pi / 180;
    final deltaLongitude = (longitude2 - longitude1) * math.pi / 180;
    final a = math.sin(deltaLatitude / 2) * math.sin(deltaLatitude / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(deltaLongitude / 2) *
            math.sin(deltaLongitude / 2);
    return radius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
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
