import 'dart:math' as math;

import 'track_geodesy.dart';
import 'track_stop.dart';

/// Stays at one place are one stop.
///
/// A precise phone holds a stop within the 25 m minimum radius, so walking
/// between the buildings of one place, such as a temple's shrines, leaves the
/// radius and splits the visit into several stays. A phone with poorer fixes
/// has a wider radius and keeps one. A stay of one segment that starts at
/// most [maximumGap] after the place's last stay ended, centred at most
/// [maximumCentreDistanceMeters] from the place's centre so far, continues
/// the place. From quality policy 5, a stay anchored on the fix that left the
/// place continues it at any distance: the device never travelled between
/// them, as when a visit drifts slowly across its radius and stops again.
/// The route database stores one row per place: the repository applies this
/// rule when it writes a stop, and the schema 17 upgrade consolidated older
/// rows with [group].
abstract final class TrackStopPlaces {
  static const maximumGap = Duration(minutes: 3);
  static const maximumCentreDistanceMeters = 75.0;

  /// First quality policy whose stays continue a place they never left.
  static const int anchoredContinuationPolicy = 5;

  /// [stops] as stays at places, oldest first.
  static List<TrackStop> merge(Iterable<TrackStop> stops) =>
      <TrackStop>[for (final place in group(stops)) combine(place)];

  /// [stops], oldest first, grouped into the stays of each place.
  static List<List<TrackStop>> group(Iterable<TrackStop> stops) {
    final sorted = stops.toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    final places = <List<TrackStop>>[];
    for (final stop in sorted) {
      final place = places.isEmpty ? null : places.last;
      if (place != null && continues(combine(place), stop)) {
        place.add(stop);
      } else {
        places.add(<TrackStop>[stop]);
      }
    }
    return places;
  }

  /// Whether [stop] continues [place], the place's stays so far combined.
  static bool continues(TrackStop place, TrackStop stop) {
    if (stop.segmentId != place.segmentId || place.isOpen) return false;
    final placeEnd = place.endedAt ?? place.lastSeenAt;
    if (stop.startedAt.difference(placeEnd) > maximumGap) return false;
    final departure = place.departurePointId;
    if (departure != null &&
        stop.arrivalPointId == departure &&
        place.qualityPolicyVersion >= anchoredContinuationPolicy &&
        stop.qualityPolicyVersion >= anchoredContinuationPolicy) {
      return true;
    }
    return TrackGeodesy.sphericalHaversineMeters(
          place.latitude,
          place.longitude,
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

  /// The stays of one [place], oldest first, as one stop: the first stay's
  /// identity, start and arrival, the last one's end and departure, summed
  /// evidence, an evidence-weighted centre and a radius covering every stay.
  static TrackStop combine(List<TrackStop> place) {
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
