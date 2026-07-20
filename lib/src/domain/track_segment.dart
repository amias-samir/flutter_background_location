enum TrackSegmentStatus { starting, active, paused, completed, interrupted }

final class TrackSegment {
  const TrackSegment({
    required this.id,
    required this.trackId,
    required this.segmentNumber,
    required this.status,
    required this.startedAt,
    required this.distanceMeters,
    required this.acceptedPointCount,
    this.endedAt,
    this.startSequence,
    this.endSequence,
    this.startPointId,
    this.endPointId,
    this.resumedFromPointId,
    this.pauseReason,
  });

  final String id;
  final String trackId;
  final int segmentNumber;
  final TrackSegmentStatus status;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int? startSequence;
  final int? endSequence;
  final String? startPointId;
  final String? endPointId;
  final String? resumedFromPointId;
  final String? pauseReason;
  final double distanceMeters;
  final int acceptedPointCount;

  factory TrackSegment.fromDatabase(Map<String, Object?> row) {
    DateTime? date(String key) {
      final value = row[key] as String?;
      return value == null ? null : DateTime.parse(value).toUtc();
    }

    return TrackSegment(
      id: row['id']! as String,
      trackId: row['track_id']! as String,
      segmentNumber: (row['segment_number']! as num).toInt(),
      status: TrackSegmentStatus.values.byName(row['status']! as String),
      startedAt: date('started_at')!,
      endedAt: date('ended_at'),
      startSequence: (row['start_sequence'] as num?)?.toInt(),
      endSequence: (row['end_sequence'] as num?)?.toInt(),
      startPointId: row['start_point_id'] as String?,
      endPointId: row['end_point_id'] as String?,
      resumedFromPointId: row['resumed_from_point_id'] as String?,
      pauseReason: row['pause_reason'] as String?,
      distanceMeters: (row['distance_m'] as num?)?.toDouble() ?? 0,
      acceptedPointCount: (row['accepted_point_count'] as num?)?.toInt() ?? 0,
    );
  }
}
