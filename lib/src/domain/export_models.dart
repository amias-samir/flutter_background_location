enum TrackExportFormat { geoJson, kml, gpx }

final class TrackExportOptions {
  const TrackExportOptions({
    this.includePointProperties = true,
    this.includeRejectedPoints = false,
    this.includeActivityMetadata = true,
    this.useUtcTimestamps = true,
    this.allowIncompleteTrackSnapshot = false,
  });

  final bool includePointProperties;
  final bool includeRejectedPoints;
  final bool includeActivityMetadata;
  final bool useUtcTimestamps;
  final bool allowIncompleteTrackSnapshot;
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
