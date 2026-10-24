import '../domain/route_summary.dart';
import '../domain/track_geodesy.dart';
import '../domain/track_point.dart';
import '../storage/track_repository.dart';

/// Export fields of a route's stored summary, shared by every export writer
/// so the materialized, streamed and Trip exports stay identical. Keys are
/// stable: GeoJSON route properties, GPX `fbl:` metadata extensions and KML
/// `ExtendedData`.
Map<String, Object?> routeSummaryFields(RouteSummary? summary) {
  if (summary == null) return const <String, Object?>{};
  return <String, Object?>{
    'recordingSeconds': summary.recording.inSeconds,
    'movingSeconds': summary.moving.inSeconds,
    'stoppedSeconds': summary.stopped.inSeconds,
    'pausedSeconds': summary.paused.inSeconds,
    'stopCount': summary.stopCount,
    if (summary.maxSpeedMetersPerSecond case final speed?)
      'maxSpeedMetersPerSecond': speed,
    if (summary.averageMovingSpeedMetersPerSecond case final speed?)
      'averageMovingSpeedMetersPerSecond': speed,
    if (summary.stepCount case final steps?) 'stepCount': steps,
    'qualityEventCount': summary.qualityEventCount,
    'visibleGapCount': summary.visibleGapCount,
    if (summary.cleanedDistanceMeters case final cleaned?)
      'cleanedDistanceMeters': cleaned,
  };
}

/// Length of [bundle]'s accepted points, segment by segment: the distance of
/// a derived-geometry export, whose coordinates are the derived ones.
double acceptedPathMeters(TrackBundle bundle) {
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
