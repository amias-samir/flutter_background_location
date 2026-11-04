/// Where a route's stop records came from.
///
/// String values rather than an enum, so later sources don't break hosts that
/// switch over them.
abstract final class TrackStopSource {
  /// Recorded while the route recorded: adaptive capture under quality
  /// policy 3 or later.
  static const recorded = 'recorded';

  /// Derived once from the stored points after the route completed, for
  /// routes recorded without live stop records.
  static const derived = 'derived';

  /// Not determined yet: the route is recording without live stop records,
  /// or completed and waiting for its stops to be derived.
  static const pending = 'pending';
}

/// What a route recorded, kept in the route database and updated as it
/// records, so hosts show and upload route details without computing them.
///
/// Durations exclude nothing but what their names say: [recording] covers
/// the route's segments (pauses excluded), [stopped] its stops, and [moving]
/// the rest of the recording time. [elapsed] runs from start to end,
/// pauses included.
final class RouteSummary {
  const RouteSummary({
    required this.trackId,
    required this.startedAt,
    required this.distanceMeters,
    required this.acceptedPointCount,
    required this.rejectedPointCount,
    required this.segmentCount,
    required this.recording,
    required this.moving,
    required this.stopped,
    required this.stopCount,
    required this.qualityEventCount,
    required this.visibleGapCount,
    required this.stopEvidenceRunCount,
    required this.stopsSource,
    required this.updatedAt,
    this.endedAt,
    this.firstFixAt,
    this.lastFixAt,
    this.maxSpeedMetersPerSecond,
    this.stepCount,
    this.cleanedDistanceMeters,
    this.cleanedRunId,
    this.correctedDistanceMeters,
    this.stepCountStoppedAt,
  });

  final String trackId;
  final DateTime startedAt;

  /// When the route completed, failed or was interrupted; null while it can
  /// still record.
  final DateTime? endedAt;

  /// Capture times of the first and newest accepted fixes.
  final DateTime? firstFixAt;
  final DateTime? lastFixAt;

  /// Measured distance of the accepted route, within segments.
  final double distanceMeters;

  /// Distance of the route's current cleaned view, when one was derived.
  final double? cleanedDistanceMeters;
  final String? cleanedRunId;

  /// Measured length of the fixes the current rules keep, for a route
  /// recorded under older rules and reviewed since (route database schema
  /// 18); null when [distanceMeters] already is that length, as for routes
  /// recorded under quality policy 5.
  final double? correctedDistanceMeters;

  /// The distance to show for the route: [correctedDistanceMeters] when the
  /// route was reviewed, else [distanceMeters]. Comparable across phones.
  double get displayDistanceMeters => correctedDistanceMeters ?? distanceMeters;

  /// When the phone's step counter stopped counting although the device was
  /// still walking: [stepCount] is then a lower bound ("at least"). Null when
  /// the count is complete or unmeasured. Steps are never estimated.
  final DateTime? stepCountStoppedAt;

  final int acceptedPointCount;
  final int rejectedPointCount;
  final int segmentCount;

  /// Time inside the route's segments, pauses excluded; while recording, up
  /// to the newest fix.
  final Duration recording;

  /// [recording] less [stopped].
  final Duration moving;

  /// Time at the route's stops; a current stop counts up to its newest fix.
  final Duration stopped;
  final int stopCount;

  /// Fastest measured Doppler speed of an accepted fix whose speed accuracy
  /// was 2 m/s or better, or not reported.
  final double? maxSpeedMetersPerSecond;

  /// Steps counted while the route recorded; null when the phone has no step
  /// counter or the activity permission was not granted.
  final int? stepCount;

  /// Rejected-fix runs that left a visible hole in the route. Informational
  /// runs, such as one dropped fix, are left out, and runs made only of stop
  /// evidence are counted in [stopEvidenceRunCount].
  final int qualityEventCount;
  final int stopEvidenceRunCount;

  /// Holes in the route a map should mark: lifecycle breaks, or gaps of at
  /// least 60 s or 150 m between accepted fixes. Gaps across a stop or pause
  /// are not holes.
  final int visibleGapCount;

  /// One of [TrackStopSource].
  final String stopsSource;
  final DateTime updatedAt;

  /// From start to end (or the newest fix while recording), pauses included.
  Duration get elapsed {
    final end = endedAt ?? lastFixAt ?? startedAt;
    final value = end.difference(startedAt);
    return value.isNegative ? Duration.zero : value;
  }

  /// [elapsed] less [recording]: time the route was paused.
  Duration get paused {
    final value = elapsed - recording;
    return value.isNegative ? Duration.zero : value;
  }

  /// [displayDistanceMeters] over [moving]; null before the route has moved.
  double? get averageMovingSpeedMetersPerSecond => moving.inMilliseconds <= 0
      ? null
      : displayDistanceMeters / (moving.inMilliseconds / 1000);
}

/// [RouteSummary] totals over a multi-day Trip's legs, kept in the route
/// database.
final class TripSummary {
  const TripSummary({
    required this.tripId,
    required this.startedAt,
    required this.legCount,
    required this.distanceMeters,
    required this.acceptedPointCount,
    required this.rejectedPointCount,
    required this.segmentCount,
    required this.recording,
    required this.moving,
    required this.stopped,
    required this.stopCount,
    required this.qualityEventCount,
    required this.visibleGapCount,
    required this.stopEvidenceRunCount,
    required this.updatedAt,
    this.endedAt,
    this.firstFixAt,
    this.lastFixAt,
    this.maxSpeedMetersPerSecond,
    this.stepCount,
    this.cleanedDistanceMeters,
    this.correctedDistanceMeters,
    this.stepCountStoppedAt,
  });

  final String tripId;
  final DateTime startedAt;
  final DateTime? endedAt;
  final DateTime? firstFixAt;
  final DateTime? lastFixAt;
  final int legCount;
  final double distanceMeters;

  /// Sum of the legs' cleaned distances; null unless every leg with fixes
  /// has one.
  final double? cleanedDistanceMeters;

  /// Sum of the legs' [RouteSummary.displayDistanceMeters] when any leg was
  /// reviewed; null when [distanceMeters] already is that length.
  final double? correctedDistanceMeters;

  /// The distance to show for the Trip: [correctedDistanceMeters], else
  /// [distanceMeters].
  double get displayDistanceMeters => correctedDistanceMeters ?? distanceMeters;

  /// The earliest time a leg's step counter stopped counting while the device
  /// was still walking; [stepCount] is then a lower bound.
  final DateTime? stepCountStoppedAt;
  final int acceptedPointCount;
  final int rejectedPointCount;
  final int segmentCount;
  final Duration recording;
  final Duration moving;
  final Duration stopped;
  final int stopCount;
  final double? maxSpeedMetersPerSecond;

  /// Sum of the legs' steps; null when no leg counted any.
  final int? stepCount;
  final int qualityEventCount;
  final int stopEvidenceRunCount;
  final int visibleGapCount;
  final DateTime updatedAt;

  /// From the Trip's start to its end (or newest fix), overnight breaks and
  /// pauses included.
  Duration get elapsed {
    final end = endedAt ?? lastFixAt ?? startedAt;
    final value = end.difference(startedAt);
    return value.isNegative ? Duration.zero : value;
  }

  /// [displayDistanceMeters] over [moving]; null before the Trip has moved.
  double? get averageMovingSpeedMetersPerSecond => moving.inMilliseconds <= 0
      ? null
      : displayDistanceMeters / (moving.inMilliseconds / 1000);
}
