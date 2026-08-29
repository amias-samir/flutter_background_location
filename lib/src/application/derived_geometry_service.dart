import '../domain/derived_geometry.dart';
import '../domain/track_point.dart';
import '../domain/tracking_error.dart';
import '../domain/tracking_start.dart';
import '../storage/track_repository.dart';

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
    if (request.algorithm != 'exponential_moving_average') {
      throw const TrackingConfigurationException(
        code: 'derived_algorithm_unsupported',
        message: 'The built-in service supports exponential_moving_average.',
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

  Future<void> deleteDerivedGeometry(String trackId, String runId);
}
