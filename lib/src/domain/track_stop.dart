/// How a recorded stop was recognised.
///
/// String values rather than an enum, so later kinds don't break hosts that
/// switch over them.
abstract final class TrackStopKind {
  /// Activity evidence showed the device was still.
  static const still = 'still';

  /// Fixes stayed within the hold radius for two minutes without net
  /// progress, as a phone in a pocket reports at a place.
  static const dwell = 'dwell';
}

/// A stay at one place during a route: where it was and how long it lasted.
///
/// Quality policy 3 records a stop once a stay has lasted two minutes. The
/// fixes held during it are kept on the device as rejected evidence and never
/// enter the route, its distance or default exports; the stop record is what
/// remains of the stay. Coordinates are the robust centre of the held fixes,
/// never a synthesized route point.
final class TrackStop {
  const TrackStop({
    required this.id,
    required this.trackId,
    required this.segmentId,
    required this.kind,
    required this.latitude,
    required this.longitude,
    required this.centreSigmaMeters,
    required this.radiusMeters,
    required this.startedAt,
    required this.lastSeenAt,
    required this.evidenceCount,
    required this.qualityPolicyVersion,
    this.endedAt,
    this.firstSequence,
    this.lastSequence,
    this.arrivalPointId,
    this.departurePointId,
  });

  final String id;
  final String trackId;
  final String segmentId;

  /// One of [TrackStopKind].
  final String kind;

  /// Centre of the stop.
  final double latitude;
  final double longitude;

  /// Per-axis standard deviation of the centre, in metres.
  final double centreSigmaMeters;

  /// Hold radius around the centre, in metres: fixes inside it were part of
  /// the stop.
  final double radiusMeters;

  /// When the stay began: the last moving evidence before it.
  final DateTime startedAt;

  /// Capture time of the newest fix held at the stop.
  final DateTime lastSeenAt;

  /// When the stop ended: the departure fix, or the end of the recorded
  /// segment. Null while the stop is current.
  final DateTime? endedAt;

  /// Number of fixes held at the stop.
  final int evidenceCount;

  /// Quality policy that recorded the stop.
  final int qualityPolicyVersion;

  /// Sequence range of the fixes held at the stop.
  final int? firstSequence;
  final int? lastSequence;

  /// The last route point before the stay, and the first after it.
  final String? arrivalPointId;
  final String? departurePointId;

  /// Whether the stop is still current.
  bool get isOpen => endedAt == null;

  /// How long the stay lasted, or has lasted so far.
  Duration get duration => (endedAt ?? lastSeenAt).difference(startedAt);
}

/// A change to the current stop, applied in the same transaction as the fix it
/// accompanies.
sealed class TrackStopChange {
  const TrackStopChange();
}

/// Opens a stop record; the accompanying fix is held at the stop.
final class TrackStopOpen extends TrackStopChange {
  const TrackStopOpen({
    required this.kind,
    required this.latitude,
    required this.longitude,
    required this.centreSigmaMeters,
    required this.radiusMeters,
    required this.startedAt,
    required this.qualityPolicyVersion,
    this.firstSequence,
    this.arrivalPointId,
    this.priorEvidenceCount = 0,
  });

  final String kind;
  final double latitude;
  final double longitude;
  final double centreSigmaMeters;
  final double radiusMeters;
  final DateTime startedAt;
  final int qualityPolicyVersion;

  /// Sequence of the first fix held during the stay, before this one.
  final int? firstSequence;
  final String? arrivalPointId;

  /// Fixes held during the stay before this one.
  final int priorEvidenceCount;
}

/// The accompanying fix was held at the current stop.
final class TrackStopExtend extends TrackStopChange {
  const TrackStopExtend();
}

/// Closes the current stop. With [departure], the accompanying fix is the
/// accepted departure and its time ends the stop; otherwise the stop ends at
/// its last held fix.
final class TrackStopClose extends TrackStopChange {
  const TrackStopClose({required this.departure});

  final bool departure;
}

/// Records a whole stop that ended at the accompanying accepted fix, the
/// departure: a stay whose length was known only once it ended, as when the
/// provider sent no fixes during it.
final class TrackStopRecord extends TrackStopChange {
  const TrackStopRecord({
    required this.kind,
    required this.latitude,
    required this.longitude,
    required this.centreSigmaMeters,
    required this.radiusMeters,
    required this.startedAt,
    required this.lastSeenAt,
    required this.evidenceCount,
    required this.qualityPolicyVersion,
    this.firstSequence,
    this.lastSequence,
    this.arrivalPointId,
  });

  final String kind;
  final double latitude;
  final double longitude;
  final double centreSigmaMeters;
  final double radiusMeters;
  final DateTime startedAt;

  /// Capture time of the newest fix held during the stay.
  final DateTime lastSeenAt;

  /// Fixes held during the stay.
  final int evidenceCount;
  final int qualityPolicyVersion;
  final int? firstSequence;
  final int? lastSequence;
  final String? arrivalPointId;
}

/// Optional capability: stops recorded for a route.
abstract interface class TrackingStopController {
  /// Stops of [trackId], oldest first, including a current one.
  Future<List<TrackStop>> listTrackStops(String trackId);

  /// Stops of every leg of [tripId], oldest first.
  Future<List<TrackStop>> listTripStops(String tripId);
}
