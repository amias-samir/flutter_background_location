import 'derived_geometry.dart';

enum TrackExportFormat { geoJson, kml, gpx }

final class TrackExportOptions {
  const TrackExportOptions({
    this.includePointProperties = true,
    this.includeRejectedPoints = false,
    this.includeActivityMetadata = true,
    this.useUtcTimestamps = true,
    this.allowIncompleteTrackSnapshot = false,
    this.includeGeoJsonPointFeatures = false,
    this.geometry = const TrackGeometrySelection.raw(),
  });

  final bool includePointProperties;
  final bool includeRejectedPoints;
  final bool includeActivityMetadata;
  final bool useUtcTimestamps;
  final bool allowIncompleteTrackSnapshot;
  final bool includeGeoJsonPointFeatures;

  /// Coordinates to export. Raw evidence is the default; derived geometry is
  /// selected only by its immutable run identifier.
  final TrackGeometrySelection geometry;
}

final class TrackExportResult {
  const TrackExportResult({
    required this.trackId,
    required this.format,
    required this.fileName,
    required this.mimeType,
    required this.path,
    required this.pointCount,
    required this.segmentCount,
  });

  final String trackId;
  final TrackExportFormat format;
  final String fileName;
  final String mimeType;
  final String path;
  final int pointCount;
  final int segmentCount;
}

final class TrackExportArtifact {
  const TrackExportArtifact({
    required this.trackId,
    required this.format,
    required this.fileName,
    required this.mimeType,
    required this.contents,
    required this.pointCount,
    required this.segmentCount,
  });

  final String trackId;
  final TrackExportFormat format;
  final String fileName;
  final String mimeType;
  final String contents;
  final int pointCount;
  final int segmentCount;

  TrackExportResult toResult(String path) => TrackExportResult(
        trackId: trackId,
        format: format,
        fileName: fileName,
        mimeType: mimeType,
        path: path,
        pointCount: pointCount,
        segmentCount: segmentCount,
      );
}

/// Request for a bounded V2 export operation.
final class TrackExportRequest {
  const TrackExportRequest({
    required this.trackId,
    required this.format,
    this.fileName,
    this.options = const TrackExportOptions(),
  });

  final String trackId;
  final TrackExportFormat format;
  final String? fileName;
  final TrackExportOptions options;
}

/// A committed V2 destination with one durable access handle.
final class TrackExportDestination {
  factory TrackExportDestination({
    required String displayName,
    required String mimeType,
    Uri? contentUri,
    String? localFilePath,
    String? displayPath,
    required bool userVisible,
  }) {
    if (displayName.trim().isEmpty || mimeType.trim().isEmpty) {
      throw ArgumentError('Export destination metadata cannot be empty.');
    }
    if ((contentUri == null) == (localFilePath == null)) {
      throw ArgumentError(
        'Exactly one durable content URI or local path is required.',
      );
    }
    if (localFilePath?.trim().isEmpty ?? false) {
      throw ArgumentError.value(localFilePath, 'localFilePath');
    }
    if (contentUri != null && !contentUri.hasScheme) {
      throw ArgumentError.value(contentUri, 'contentUri');
    }
    return TrackExportDestination._(
      displayName: displayName,
      mimeType: mimeType,
      contentUri: contentUri,
      localFilePath: localFilePath,
      displayPath: displayPath,
      userVisible: userVisible,
    );
  }

  const TrackExportDestination._({
    required this.displayName,
    required this.mimeType,
    required this.contentUri,
    required this.localFilePath,
    required this.displayPath,
    required this.userVisible,
  });

  final String displayName;
  final String mimeType;
  final Uri? contentUri;
  final String? localFilePath;

  /// Informational user-facing location. Never open this value as a file.
  final String? displayPath;
  final bool userVisible;

  factory TrackExportDestination.fromMap(Map<Object?, Object?> map) {
    final displayName = map['displayName'] as String?;
    final mimeType = map['mimeType'] as String?;
    final rawContentUri = map['contentUri'] as String?;
    final rawLocalFilePath = map['localFilePath'] as String?;
    final localFilePath = rawLocalFilePath == null || rawLocalFilePath.isEmpty
        ? null
        : rawLocalFilePath;
    final contentUri = rawContentUri == null || rawContentUri.isEmpty
        ? null
        : Uri.tryParse(rawContentUri);
    if (displayName == null ||
        displayName.isEmpty ||
        mimeType == null ||
        mimeType.isEmpty ||
        (contentUri == null) == (localFilePath == null)) {
      throw const FormatException(
        'Export destination requires metadata and exactly one access handle.',
      );
    }
    return TrackExportDestination(
      displayName: displayName,
      mimeType: mimeType,
      contentUri: contentUri,
      localFilePath: localFilePath,
      displayPath: map['displayPath'] as String?,
      userVisible: map['userVisible'] as bool? ?? false,
    );
  }
}

/// Progress emitted between bounded export chunks.
final class TrackExportProgress {
  const TrackExportProgress({
    required this.pointsWritten,
    required this.bytesWritten,
  });

  final int pointsWritten;
  final int bytesWritten;
}

/// Result of a V2 export with a share-safe destination abstraction.
final class TrackExportResultV2 {
  const TrackExportResultV2({
    required this.managedExportId,
    required this.trackId,
    required this.format,
    required this.destination,
    required this.byteLength,
    required this.pointCount,
    required this.segmentCount,
  });

  /// Owner-scoped canonical inventory identifier for this artifact.
  final String managedExportId;
  final String trackId;
  final TrackExportFormat format;
  final TrackExportDestination destination;
  final int byteLength;
  final int pointCount;
  final int segmentCount;
}

/// Cancellable V2 export handle.
abstract interface class TrackExportOperation {
  Stream<TrackExportProgress> get progress;
  Future<TrackExportResultV2> get result;
  Future<void> cancel();
}

/// A local cache copy prepared for a host sharing package.
abstract interface class PreparedTrackShareFile {
  String get path;
  String get mimeType;
  String get displayName;
  Future<void> delete();
}

/// Optional facade capability for V2 export and share preparation.
abstract interface class TrackingExportController {
  Future<TrackExportOperation> exportTrackV2(TrackExportRequest request);

  Future<PreparedTrackShareFile> prepareExportForSharing(
    TrackExportResultV2 result,
  );
}

/// Owner-scoped package-managed export visible to cleanup/privacy workflows.
final class ManagedTrackExport {
  const ManagedTrackExport({
    required this.id,
    required this.trackId,
    required this.format,
    required this.state,
    required this.destination,
    required this.createdAt,
    this.deletedAt,
  });

  final String id;
  final String trackId;
  final TrackExportFormat format;
  final String state;
  final TrackExportDestination? destination;
  final DateTime createdAt;
  final DateTime? deletedAt;
}

final class ManagedExportDeletionReport {
  const ManagedExportDeletionReport({
    required this.exportId,
    required this.status,
    required this.artifactRemoved,
  });

  final String exportId;
  final String status;
  final bool artifactRemoved;
}

abstract interface class TrackingManagedExportController {
  Future<List<ManagedTrackExport>> listManagedExports(String trackId);

  Future<ManagedExportDeletionReport> deleteManagedExport(String exportId);
}
