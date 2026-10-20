import 'dart:math' as math;

import 'track_geodesy.dart';
import 'track_stop.dart';

/// Stays at one place are one stop.
///
/// A precise phone holds a stop within the 25 m minimum radius, so walking
/// between the buildings of one place, such as a temple's shrines, leaves the
/// radius and splits the visit into several stop records. A phone with poorer
/// fixes has a wider radius and keeps one record. Consecutive records of one
/// segment that start at most [maximumGap] after the previous one ended, with
/// a centre at most [maximumCentreDistanceMeters] from the place's centre so
/// far, are one stop. Stored records never change.
abstract final class TrackStopPlaces {
  static const maximumGap = Duration(minutes: 3);
  static const maximumCentreDistanceMeters = 75.0;

  /// [stops] as stays at places, oldest first.
  static List<TrackStop> merge(Iterable<TrackStop> stops) {
    final sorted = stops.toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final places = <List<TrackStop>>[];
    for (final stop in sorted) {
      final place = places.isEmpty ? null : places.last;
      if (place != null && _continues(place, stop)) {
        place.add(stop);
      } else {
        places.add(<TrackStop>[stop]);
      }
    }
    return <TrackStop>[for (final place in places) _combine(place)];
  }

  static bool _continues(List<TrackStop> place, TrackStop stop) {
    final previous = place.last;
    if (stop.segmentId != previous.segmentId || previous.isOpen) return false;
    final previousEnd = previous.endedAt ?? previous.lastSeenAt;
    if (stop.startedAt.difference(previousEnd) > maximumGap) return false;
    final (latitude, longitude) = _centre(place);
    return TrackGeodesy.sphericalHaversineMeters(
          latitude,
          longitude,
          stop.latitude,
          stop.longitude,
        ) <=
        maximumCentreDistanceMeters;
  }

  /// Evidence-weighted centre of [place]; longitudes are averaged relative
  /// to the first record so a place never straddles the antimeridian.
  static (double, double) _centre(List<TrackStop> place) {
    final origin = place.first.longitude;
    var weight = 0.0;
    var latitude = 0.0;
    var longitudeOffset = 0.0;
    for (final stop in place) {
      final w = math.max(1, stop.evidenceCount).toDouble();
      weight += w;
      latitude += stop.latitude * w;
      longitudeOffset += (((stop.longitude - origin) + 540) % 360 - 180) * w;
    }
    final longitude = origin + longitudeOffset / weight;
    return (latitude / weight, ((longitude + 540) % 360) - 180);
  }

  static TrackStop _combine(List<TrackStop> place) {
    if (place.length == 1) return place.single;
    final first = place.first;
    final last = place.last;
    final (latitude, longitude) = _centre(place);
    return TrackStop(
      id: first.id,
      trackId: first.trackId,
      segmentId: first.segmentId,
      kind: place.any((stop) => stop.kind == TrackStopKind.still)
          ? TrackStopKind.still
          : TrackStopKind.dwell,
      latitude: latitude,
      longitude: longitude,
      centreSigmaMeters: place.map((stop) => stop.centreSigmaMeters).reduce(
            math.max,
          ),
      // Every record's hold disc lies inside the place's.
      radiusMeters: place
          .map(
            (stop) =>
                TrackGeodesy.sphericalHaversineMeters(
                  latitude,
                  longitude,
                  stop.latitude,
                  stop.longitude,
                ) +
                stop.radiusMeters,
          )
          .reduce(math.max),
      startedAt: first.startedAt,
      lastSeenAt: last.lastSeenAt,
      endedAt: last.endedAt,
      evidenceCount: place.fold(0, (total, stop) => total + stop.evidenceCount),
      qualityPolicyVersion: first.qualityPolicyVersion,
      firstSequence: first.firstSequence,
      lastSequence: last.lastSequence,
      arrivalPointId: first.arrivalPointId,
      departurePointId: last.departurePointId,
    );
  }
}
