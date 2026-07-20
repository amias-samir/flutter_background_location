import 'activity_snapshot.dart';
import 'location_sample.dart';
import 'track_segment.dart';
import 'tracker_status.dart';

abstract final class TrackPointQualityFlag {
  static const int none = 0;
  static const int poorAccuracy = 1 << 0;
  static const int implausibleSpeed = 1 << 1;
  static const int mockLocation = 1 << 2;
  static const int staleTimestamp = 1 << 3;
  static const int invalidCoordinate = 1 << 4;
  static const int largeGap = 1 << 5;
}

final class TrackPoint {
  const TrackPoint({
    required this.id,
    required this.trackId,
    required this.segmentId,
    required this.sequence,
    required this.latitude,
    required this.longitude,
    required this.capturedAt,
    required this.persistedAt,
    required this.activityType,
    required this.activityConfidence,
    required this.motionState,
    required this.isMocked,
    required this.mockDetectionAvailable,
    required this.accepted,
    required this.qualityFlags,
    this.altitude,
    this.horizontalAccuracy,
    this.verticalAccuracy,
    this.speed,
    this.speedAccuracy,
    this.heading,
    this.headingAccuracy,
    this.provider,
    this.rejectionReason,
    this.mockEvidence,
    this.nativeEventId,
  });

  final String id;
  final String trackId;
  final String segmentId;
  final int sequence;
  final double latitude;
  final double longitude;
  final double? altitude;
  final double? horizontalAccuracy;
  final double? verticalAccuracy;
  final double? speed;
  final double? speedAccuracy;
  final double? heading;
  final double? headingAccuracy;
  final DateTime capturedAt;
  final DateTime persistedAt;
  final TrackingActivityType activityType;
  final int activityConfidence;
  final MotionState motionState;
  final String? provider;
  final bool isMocked;
  final bool mockDetectionAvailable;
  final String? mockEvidence;
  final String? nativeEventId;
  final bool accepted;
  final int qualityFlags;
  final String? rejectionReason;

  MockLocationAssessment get mockAssessment {
    if (isMocked) return MockLocationAssessment.detected;
    if (!mockDetectionAvailable) return MockLocationAssessment.unavailable;
    return MockLocationAssessment.notDetected;
  }

  factory TrackPoint.fromDatabase(Map<String, Object?> row) => TrackPoint(
        id: row['id']! as String,
        trackId: row['track_id']! as String,
        segmentId: row['segment_id']! as String,
        sequence: (row['sequence']! as num).toInt(),
        latitude: (row['latitude']! as num).toDouble(),
        longitude: (row['longitude']! as num).toDouble(),
        altitude: (row['altitude'] as num?)?.toDouble(),
        horizontalAccuracy: (row['horizontal_accuracy'] as num?)?.toDouble(),
        verticalAccuracy: (row['vertical_accuracy'] as num?)?.toDouble(),
        speed: (row['speed'] as num?)?.toDouble(),
        speedAccuracy: (row['speed_accuracy'] as num?)?.toDouble(),
        heading: (row['heading'] as num?)?.toDouble(),
        headingAccuracy: (row['heading_accuracy'] as num?)?.toDouble(),
        capturedAt: DateTime.parse(row['captured_at']! as String).toUtc(),
        persistedAt: DateTime.parse(row['persisted_at']! as String).toUtc(),
        activityType: trackingActivityTypeFromValue(row['activity_type']),
        activityConfidence: (row['activity_confidence'] as num?)?.toInt() ?? 0,
        motionState: MotionState.values.firstWhere(
          (state) => state.name == row['motion_state'],
          orElse: () => MotionState.unknown,
        ),
        provider: row['provider'] as String?,
        isMocked: row['is_mocked'] == 1,
        mockDetectionAvailable: row['mock_detection_available'] == 1,
        mockEvidence: row['mock_evidence'] as String?,
        nativeEventId: row['native_event_id'] as String?,
        accepted: row['accepted'] == 1,
        qualityFlags: (row['quality_flags'] as num?)?.toInt() ?? 0,
        rejectionReason: row['rejection_reason'] as String?,
      );
}

final class TrackSegmentWithPoints {
  const TrackSegmentWithPoints({required this.segment, required this.points});

  final TrackSegment segment;
  final List<TrackPoint> points;
}
