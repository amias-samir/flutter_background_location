import 'package:path/path.dart' as path_util;

import '../application/route_geometry_assembler.dart';
import '../domain/derived_geometry.dart';
import '../domain/export_models.dart';
import '../domain/route_geometry.dart';
import '../domain/track.dart';
import '../domain/track_point.dart';
import '../domain/trip.dart';
import '../domain/tracking_continuity.dart';
import '../domain/tracking_error.dart';
import '../domain/tracking_start.dart';
import '../storage/track_repository.dart';
import '../storage/trip_repository.dart';
import 'track_export_service.dart';

/// Combined multi-day Trip exporter using the same geometry/format contract as
/// Track export.
///
/// Daily Track rows remain terminal and unchanged. This service reads each leg
/// in chronological order and creates one revisioned snapshot artifact.
final class TripExportService {
  TripExportService({
    required this.repository,
    required this.fileWriter,
    this.maximumMaterializedPoints = 100000,
  }) {
    if (maximumMaterializedPoints < 1) {
      throw ArgumentError.value(
        maximumMaterializedPoints,
        'maximumMaterializedPoints',
      );
    }
  }

  final TrackRepository repository;
  final ExportFileWriter fileWriter;

  /// Safety ceiling for this compatibility string exporter.
  ///
  /// Large hosts should page/archive daily legs or use their own streaming
  /// sink. The ceiling prevents an accidental unbounded in-memory artifact.
  final int maximumMaterializedPoints;

  TripRepository get _trips {
    final store = repository;
    if (store is TripRepository) return store as TripRepository;
    throw const TrackingStorageException(
      code: 'capability_unsupported',
      message: 'This repository does not support multi-day Trip export.',
    );
  }

  Future<TripExportResult> exportTrip({
    required TrackingOwner owner,
    required String tripId,
    required TrackExportFormat format,
    TrackExportOptions options = const TrackExportOptions(),
    String? fileName,
    MultiDayRoutePresentation? routePresentationOverride,
  }) async {
    if (options.geometry is! RawTrackGeometry) {
      throw const TrackingStorageException(
        code: 'trip_derived_geometry_unsupported',
        message: 'Combined Trip export currently requires raw geometry.',
      );
    }
    final tripBundle = await _trips.loadTripBundleForOwner(owner, tripId);
    final sourceParts = <RouteGeometrySourcePart>[];
    final combinedSegments = <TrackSegmentWithPoints>[];
    final allGaps = <TrackingContinuityGap>[];
    Track? firstTrack;
    var materializedPoints = 0;

    for (final leg in tripBundle.legs) {
      final track = await repository.getTrack(leg.trackId);
      if (track == null || !owner.owns(track)) {
        throw const TrackingOwnershipException(
          code: 'trip_leg_not_found_in_owner_scope',
          message: 'A Trip leg is unavailable in the current owner scope.',
        );
      }
      firstTrack ??= track;
      final trackBundle = await repository.loadTrackBundle(track.id);
      final legacyIds = repository is LegacyGapEvidenceRepository
          ? await (repository as LegacyGapEvidenceRepository)
              .safeLegacyAutomaticAfterSegmentIds(track.id)
          : const <String>{};
      for (final segment in trackBundle.segments) {
        materializedPoints += segment.points.length;
        if (materializedPoints > maximumMaterializedPoints) {
          throw TrackingExportException(
            code: 'trip_export_too_large_for_legacy_api',
            message: 'The Trip exceeds the compatibility export point limit.',
            trackId: track.id,
          );
        }
        combinedSegments.add(segment);
        sourceParts.add(
          RouteGeometrySourcePart(
            legNumber: leg.legNumber,
            segment: segment.segment,
            points: segment.points,
            legacyAutomaticGapEligible: legacyIds.contains(segment.segment.id),
          ),
        );
      }
      if (repository is ContinuityTrackRepository) {
        allGaps.addAll(
          await (repository as ContinuityTrackRepository)
              .listContinuityGaps(track.id),
        );
      }
    }
    if (firstTrack == null) {
      throw const TrackingStorageException(
        code: 'trip_has_no_legs',
        message: 'The Trip has no route legs to export.',
      );
    }
    final trip = tripBundle.trip;
    if (trip.status != TripStatus.completed &&
        !options.allowIncompleteTrackSnapshot) {
      throw const TrackingStorageException(
        code: 'export_trip_incomplete',
        message: 'Only completed Trips can be exported by default.',
      );
    }
    final report = const RouteGeometryAssembler().assemble(
      sourceParts: sourceParts,
      gaps: allGaps,
      continuity: routePresentationOverride?.geometryContinuity ??
          (options.geometryContinuity ==
                  RouteGeometryContinuity.preserveEvidenceSegments
              ? trip.routePresentation.geometryContinuity
              : options.geometryContinuity),
    );
    final syntheticTrack = Track(
      id: trip.id,
      userId: trip.userId,
      organizationId: trip.organizationId,
      routeId: trip.routeId,
      status: _trackStatus(trip.status),
      startedAt: trip.startedAt,
      pausedAt: trip.suspendedAt,
      endedAt: trip.endedAt,
      totalDistanceMeters: trip.measuredDistanceMeters,
      acceptedPointCount: trip.acceptedPointCount,
      rejectedPointCount: trip.rejectedPointCount,
      segmentCount: report.sourceSegmentCount,
      nextSequence: trip.acceptedPointCount + trip.rejectedPointCount + 1,
      currentSegmentId: null,
      config: firstTrack.config,
    );
    final bundle = TrackBundle(
      track: syntheticTrack,
      segments: combinedSegments,
    );
    final trackArtifact = TrackExportService(
      repository: repository,
      fileWriter: fileWriter,
    ).renderAssembledBundle(
      bundle: bundle,
      format: format,
      options: options,
      report: report,
    );
    final fallback = trackArtifact.fileName.replaceFirst('track_', 'trip_');
    final resolvedName = resolveExportFileName(
      format: format,
      fallbackFileName: fallback,
      requestedFileName: fileName,
    );
    final destination = await fileWriter.write(
      fileName: resolvedName,
      contents: trackArtifact.contents,
      mimeType: trackArtifact.mimeType,
    );
    return TripExportResult(
      tripId: trip.id,
      lifecycleRevision: trip.lifecycleRevision,
      format: format,
      fileName: path_util.basename(destination),
      mimeType: trackArtifact.mimeType,
      path: destination,
      pointCount: trackArtifact.pointCount,
      sourceSegmentCount: report.sourceSegmentCount,
      geometryPartCount: report.geometryPartCount,
      gapCount: report.gapCount,
      inferredConnectorCount: report.inferredConnectorCount,
      geometryContinuity: report.continuity,
    );
  }

  static TrackStatus _trackStatus(TripStatus status) => switch (status) {
        TripStatus.active => TrackStatus.active,
        TripStatus.suspended => TrackStatus.paused,
        TripStatus.completed => TrackStatus.completed,
        TripStatus.failed => TrackStatus.failed,
      };
}
