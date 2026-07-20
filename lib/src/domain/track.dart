import 'tracking_config.dart';

enum TrackStatus {
  starting,
  active,
  paused,
  stopping,
  completed,
  interrupted,
  failed,
}

final class Track {
  const Track({
    required this.id,
    required this.userId,
    required this.organizationId,
    required this.status,
    required this.startedAt,
    required this.totalDistanceMeters,
    required this.acceptedPointCount,
    required this.rejectedPointCount,
    required this.segmentCount,
    required this.nextSequence,
    required this.config,
    this.patrolId,
    this.pausedAt,
    this.resumedAt,
    this.endedAt,
    this.currentSegmentId,
    this.lastPointAt,
    this.startLatitude,
    this.startLongitude,
    this.endLatitude,
    this.endLongitude,
    this.completionReason,
  });

  final String id;
  final String userId;
  final String organizationId;
  final String? patrolId;
  final TrackStatus status;
  final DateTime startedAt;
  final DateTime? pausedAt;
  final DateTime? resumedAt;
  final DateTime? endedAt;
  final double totalDistanceMeters;
  final int acceptedPointCount;
  final int rejectedPointCount;
  final int segmentCount;
  final int nextSequence;
  final String? currentSegmentId;
  final DateTime? lastPointAt;
  final double? startLatitude;
  final double? startLongitude;
  final double? endLatitude;
  final double? endLongitude;
  final String? completionReason;
  final TrackingConfig config;

  bool get isResumable =>
      status == TrackStatus.paused || status == TrackStatus.interrupted;

  bool get isTerminal =>
      status == TrackStatus.completed || status == TrackStatus.failed;

  factory Track.fromDatabase(Map<String, Object?> row) {
    DateTime? date(String key) {
      final value = row[key] as String?;
      return value == null ? null : DateTime.parse(value).toUtc();
    }

    return Track(
      id: row['id']! as String,
      userId: row['user_id']! as String,
      organizationId: row['organization_id']! as String,
      patrolId: row['patrol_id'] as String?,
      status: TrackStatus.values.byName(row['status']! as String),
      startedAt: date('started_at')!,
      pausedAt: date('paused_at'),
      resumedAt: date('resumed_at'),
      endedAt: date('ended_at'),
      totalDistanceMeters: (row['total_distance_m'] as num?)?.toDouble() ?? 0,
      acceptedPointCount: (row['accepted_point_count'] as num?)?.toInt() ?? 0,
      rejectedPointCount: (row['rejected_point_count'] as num?)?.toInt() ?? 0,
      segmentCount: (row['segment_count'] as num?)?.toInt() ?? 0,
      nextSequence: (row['next_sequence'] as num?)?.toInt() ?? 1,
      currentSegmentId: row['current_segment_id'] as String?,
      lastPointAt: date('last_point_at'),
      startLatitude: (row['start_lat'] as num?)?.toDouble(),
      startLongitude: (row['start_lon'] as num?)?.toDouble(),
      endLatitude: (row['end_lat'] as num?)?.toDouble(),
      endLongitude: (row['end_lon'] as num?)?.toDouble(),
      completionReason: row['completion_reason'] as String?,
      config: TrackingConfig.fromJson(row['configuration_json']! as String),
    );
  }
}

typedef TrackSummary = Track;
