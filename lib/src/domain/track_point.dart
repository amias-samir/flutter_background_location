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
  static const int nativeTrackMismatch = 1 << 6;
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
    this.configurationEpochId,
    this.nativeReceivedAt,
    this.providerTimeDeltaMsAtReceipt,
    this.monotonicFixNanos,
    this.monotonicReceivedNanos,
    this.monotonicDomainId,
    this.captureGenerationId,
    this.nativeSessionStartedAt,
    this.nativeLifecycle,
    this.samplingProfile,
    this.qualityPolicyVersion,
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

  /// Immutable policy epoch used to evaluate this point, when known.
  ///
  /// Legacy evidence remains null when its stored route configuration cannot
  /// prove which policy was active.
  final String? configurationEpochId;
  final DateTime? nativeReceivedAt;
  final int? providerTimeDeltaMsAtReceipt;
  final int? monotonicFixNanos;
  final int? monotonicReceivedNanos;
  final String? monotonicDomainId;
  final String? captureGenerationId;
  final DateTime? nativeSessionStartedAt;
  final TrackerLifecycle? nativeLifecycle;
  final SamplingProfile? samplingProfile;
  final int? qualityPolicyVersion;
  final bool accepted;
  final int qualityFlags;
  final String? rejectionReason;

  MockLocationAssessment get mockAssessment {
    if (isMocked) return MockLocationAssessment.detected;
    if (!mockDetectionAvailable) return MockLocationAssessment.unavailable;
    return MockLocationAssessment.notDetected;
  }

  /// Returns an export/map view with replacement coordinates while retaining
  /// every raw point identifier and evidence field.
  ///
  /// This does not mutate or persist the canonical raw point.
  TrackPoint withCoordinates({
    required double latitude,
    required double longitude,
  }) =>
      TrackPoint(
        id: id,
        trackId: trackId,
        segmentId: segmentId,
        sequence: sequence,
        latitude: latitude,
        longitude: longitude,
        altitude: altitude,
        horizontalAccuracy: horizontalAccuracy,
        verticalAccuracy: verticalAccuracy,
        speed: speed,
        speedAccuracy: speedAccuracy,
        heading: heading,
        headingAccuracy: headingAccuracy,
        capturedAt: capturedAt,
        persistedAt: persistedAt,
        activityType: activityType,
        activityConfidence: activityConfidence,
        motionState: motionState,
        provider: provider,
        isMocked: isMocked,
        mockDetectionAvailable: mockDetectionAvailable,
        mockEvidence: mockEvidence,
        nativeEventId: nativeEventId,
        configurationEpochId: configurationEpochId,
        nativeReceivedAt: nativeReceivedAt,
        providerTimeDeltaMsAtReceipt: providerTimeDeltaMsAtReceipt,
        monotonicFixNanos: monotonicFixNanos,
        monotonicReceivedNanos: monotonicReceivedNanos,
        monotonicDomainId: monotonicDomainId,
        captureGenerationId: captureGenerationId,
        nativeSessionStartedAt: nativeSessionStartedAt,
        nativeLifecycle: nativeLifecycle,
        samplingProfile: samplingProfile,
        qualityPolicyVersion: qualityPolicyVersion,
        accepted: accepted,
        qualityFlags: qualityFlags,
        rejectionReason: rejectionReason,
      );

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
        configurationEpochId: row['configuration_epoch_id'] as String?,
        nativeReceivedAt: row['native_received_at'] == null
            ? null
            : DateTime.parse(row['native_received_at']! as String).toUtc(),
        providerTimeDeltaMsAtReceipt:
            (row['provider_time_delta_ms_at_receipt'] as num?)?.toInt(),
        monotonicFixNanos: (row['monotonic_fix_nanos'] as num?)?.toInt(),
        monotonicReceivedNanos:
            (row['monotonic_received_nanos'] as num?)?.toInt(),
        monotonicDomainId: row['monotonic_domain_id'] as String?,
        captureGenerationId: row['capture_generation_id'] as String?,
        nativeSessionStartedAt: row['native_session_started_at'] == null
            ? null
            : DateTime.parse(row['native_session_started_at']! as String)
                .toUtc(),
        nativeLifecycle:
            TrackerLifecycle.values.cast<TrackerLifecycle?>().firstWhere(
                  (candidate) => candidate?.name == row['native_lifecycle'],
                  orElse: () => null,
                ),
        samplingProfile:
            SamplingProfile.values.cast<SamplingProfile?>().firstWhere(
                  (candidate) => candidate?.name == row['sampling_profile'],
                  orElse: () => null,
                ),
        qualityPolicyVersion: (row['quality_policy_version'] as num?)?.toInt(),
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
