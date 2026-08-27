import 'tracking_config.dart';

/// Durable lifecycle state of one recorded route.
enum TrackStatus {
  /// Route metadata exists while native capture is being prepared.
  starting,

  /// Route location capture is active.
  active,

  /// Route is retained and can be resumed without collecting points.
  paused,

  /// Route is completing native and database cleanup.
  stopping,

  /// Route was completed normally.
  completed,

  /// Route capture stopped unexpectedly and can be resumed.
  interrupted,

  /// Route ended with a terminal failure.
  failed,
}

/// Persisted summary and configuration for one tracked route.
final class Track {
  /// Creates an immutable route snapshot.
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
    this.routeId,
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
    this.terminalReasonCode,
    this.sessionControlToken,
  });

  /// Internal collision-safe route identifier used by package operations.
  final String id;

  /// Host user scope that owns this route.
  final String userId;

  /// Host organization scope that owns this route.
  final String organizationId;

  /// Human-readable, normalized route identifier with a timestamp suffix.
  final String? routeId;

  /// Current durable route lifecycle.
  final TrackStatus status;

  /// UTC time at which the route was created.
  final DateTime startedAt;

  /// UTC time of the latest pause transition.
  final DateTime? pausedAt;

  /// UTC time of the latest resume transition.
  final DateTime? resumedAt;

  /// UTC time at which the route became terminal.
  final DateTime? endedAt;

  /// Sum of accepted within-segment distances, in metres.
  final double totalDistanceMeters;

  /// Number of location points accepted into route geometry.
  final int acceptedPointCount;

  /// Number of retained audit points rejected from geometry.
  final int rejectedPointCount;

  /// Number of pause-safe route segments.
  final int segmentCount;

  /// Next monotonically increasing route-wide point sequence.
  final int nextSequence;

  /// Segment currently receiving accepted points, when active.
  final String? currentSegmentId;

  /// UTC capture time of the most recent persisted point.
  final DateTime? lastPointAt;

  /// Latitude of the first accepted point, when available.
  final double? startLatitude;

  /// Longitude of the first accepted point, when available.
  final double? startLongitude;

  /// Latitude of the last accepted point, when available.
  final double? endLatitude;

  /// Longitude of the last accepted point, when available.
  final double? endLongitude;

  /// Host-supplied reason associated with normal completion.
  final String? completionReason;

  /// Additive terminal classification such as `cancelled_by_host`.
  final String? terminalReasonCode;

  /// Opaque durable identity used to fence native lifecycle commands.
  ///
  /// This coordinates package engines; it is not an authentication token.
  final String? sessionControlToken;

  /// Fully resolved sampling and quality configuration stored with the route.
  final TrackingConfig config;

  /// Whether this route can be continued by a Resume operation.
  bool get isResumable =>
      status == TrackStatus.paused || status == TrackStatus.interrupted;

  /// Whether this route can no longer collect or resume points.
  bool get isTerminal =>
      status == TrackStatus.completed || status == TrackStatus.failed;

  /// Decodes a canonical SQLite track row.
  factory Track.fromDatabase(Map<String, Object?> row) {
    DateTime? date(String key) {
      final value = row[key] as String?;
      return value == null ? null : DateTime.parse(value).toUtc();
    }

    return Track(
      id: row['id']! as String,
      userId: row['user_id']! as String,
      organizationId: row['organization_id']! as String,
      routeId: row['route_id'] as String?,
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
      terminalReasonCode: row['terminal_reason_code'] as String?,
      sessionControlToken: row['session_control_token'] as String?,
      config: TrackingConfig.fromJson(row['configuration_json']! as String),
    );
  }
}

/// Backward-compatible name for the route summary model.
typedef TrackSummary = Track;

/// Creates a readable route ID with whitespace normalized and a UTC suffix.
String createRouteId(String identifier, DateTime startedAt) {
  final normalized = identifier.trim().replaceAll(RegExp(r'\s+'), '_');
  if (normalized.isEmpty) {
    throw ArgumentError.value(
      identifier,
      'identifier',
      'Route identifier must not be empty.',
    );
  }
  final utc = startedAt.toUtc();
  String digits(int value, int width) => value.toString().padLeft(width, '0');
  final suffix = '${digits(utc.year, 4)}${digits(utc.month, 2)}'
      '${digits(utc.day, 2)}_${digits(utc.hour, 2)}'
      '${digits(utc.minute, 2)}${digits(utc.second, 2)}_'
      '${digits(utc.millisecond, 3)}${digits(utc.microsecond, 3)}';
  return '${normalized}_$suffix';
}
