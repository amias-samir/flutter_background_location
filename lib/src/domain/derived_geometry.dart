import 'dart:collection';

import 'tracking_start.dart';

/// Selects which coordinates a map or export consumes.
sealed class TrackGeometrySelection {
  const TrackGeometrySelection();

  const factory TrackGeometrySelection.raw() = RawTrackGeometry;
  const factory TrackGeometrySelection.derived(String runId) =
      DerivedTrackGeometry;
}

final class RawTrackGeometry extends TrackGeometrySelection {
  const RawTrackGeometry();
}

final class DerivedTrackGeometry extends TrackGeometrySelection {
  const DerivedTrackGeometry(this.runId)
      : assert(runId != '', 'runId must not be empty');

  final String runId;
}

enum DerivedGeometryRunStatus { processing, completed, failed }

/// Immutable provenance for one post-capture geometry derivation.
final class DerivedGeometryRun {
  DerivedGeometryRun({
    required this.id,
    required this.trackId,
    required this.name,
    required this.algorithm,
    required this.algorithmVersion,
    required Map<String, Object?> configuration,
    required this.sourceMaximumSequence,
    required this.status,
    required this.createdAt,
    this.completedAt,
    this.pointCount = 0,
    this.mapDataSource,
    this.mapDataVersion,
    this.failureCode,
  }) : configuration = UnmodifiableMapView<String, Object?>(
          Map<String, Object?>.of(configuration),
        );

  final String id;
  final String trackId;
  final String name;
  final String algorithm;
  final String algorithmVersion;
  final UnmodifiableMapView<String, Object?> configuration;
  final String? mapDataSource;
  final String? mapDataVersion;
  final int sourceMaximumSequence;
  final DerivedGeometryRunStatus status;
  final int pointCount;
  final DateTime createdAt;
  final DateTime? completedAt;
  final String? failureCode;
}

/// A derived coordinate linked to exactly one immutable raw point.
final class DerivedGeometryPoint {
  const DerivedGeometryPoint({
    required this.runId,
    required this.sourcePointId,
    required this.segmentId,
    required this.sequence,
    required this.latitude,
    required this.longitude,
  });

  final String runId;
  final String sourcePointId;
  final String segmentId;
  final int sequence;
  final double latitude;
  final double longitude;
}

/// Input to an offline derivation. The package ships an EMA implementation;
/// hosts may persist results from another offline or network algorithm through
/// [DerivedGeometryRepository].
final class DerivedGeometryRequest {
  const DerivedGeometryRequest({
    this.name = 'smoothed',
    this.algorithm = 'exponential_moving_average',
    this.algorithmVersion = '1',
    this.smoothingFactor = 0.35,
    this.mapDataSource,
    this.mapDataVersion,
  }) : assert(smoothingFactor > 0 && smoothingFactor <= 1);

  final String name;
  final String algorithm;
  final String algorithmVersion;
  final double smoothingFactor;
  final String? mapDataSource;
  final String? mapDataVersion;

  Map<String, Object?> get configuration => <String, Object?>{
        'smoothingFactor': smoothingFactor,
      };
}

/// Optional owner-scoped persistence capability for derived geometry.
abstract interface class DerivedGeometryRepository {
  Future<DerivedGeometryRun> beginDerivedGeometryRun({
    required TrackingOwner owner,
    required String trackId,
    required DerivedGeometryRequest request,
    required int sourceMaximumSequence,
  });

  Future<void> appendDerivedGeometryPoints({
    required String runId,
    required Iterable<DerivedGeometryPoint> points,
  });

  Future<DerivedGeometryRun> completeDerivedGeometryRun(String runId);
  Future<void> failDerivedGeometryRun(String runId, {required String code});

  Future<List<DerivedGeometryRun>> listDerivedGeometryRuns({
    required TrackingOwner owner,
    required String trackId,
  });

  Future<DerivedGeometryRun?> getDerivedGeometryRun({
    required TrackingOwner owner,
    required String trackId,
    required String runId,
  });

  Future<Map<String, DerivedGeometryPoint>> derivedCoordinatesForSourcePoints({
    required TrackingOwner owner,
    required String trackId,
    required String runId,
    required Iterable<String> sourcePointIds,
  });

  Future<void> deleteDerivedGeometryRun({
    required TrackingOwner owner,
    required String trackId,
    required String runId,
  });
}
