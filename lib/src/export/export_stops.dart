import '../domain/track_stop.dart';

/// Export fields of a recorded stop, shared by every export writer so the
/// legacy and incremental encoders stay identical.
///
/// [formatTime] is the writer's timestamp format. Keys are stable: GeoJSON
/// feature properties, GPX `fbl:` waypoint extensions and KML `ExtendedData`.
Map<String, Object?> stopExportFields(
  TrackStop stop,
  String Function(DateTime value) formatTime,
) =>
    <String, Object?>{
      'featureType': 'stop',
      'stopId': stop.id,
      'kind': stop.kind,
      'startedAt': formatTime(stop.startedAt),
      if (stop.endedAt case final endedAt?) 'endedAt': formatTime(endedAt),
      'durationSeconds': stop.duration.inSeconds,
      'evidenceCount': stop.evidenceCount,
      'radiusMeters': stop.radiusMeters,
    };

/// A GeoJSON Point feature for [stop].
Map<String, Object?> stopGeoJsonFeature(
  TrackStop stop,
  String Function(DateTime value) formatTime,
) =>
    <String, Object?>{
      'type': 'Feature',
      'properties': stopExportFields(stop, formatTime),
      'geometry': <String, Object?>{
        'type': 'Point',
        'coordinates': <double>[stop.longitude, stop.latitude],
      },
    };

/// Human-readable stay length, such as `Stayed 1 h 5 min`.
String stopDescription(TrackStop stop) {
  final minutes = stop.duration.inMinutes;
  if (minutes < 1) return 'Stayed ${stop.duration.inSeconds} s';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  if (hours == 0) return 'Stayed $minutes min';
  return rest == 0 ? 'Stayed $hours h' : 'Stayed $hours h $rest min';
}
