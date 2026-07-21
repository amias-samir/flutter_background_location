import '../domain/activity_snapshot.dart';
import '../domain/location_sample.dart';
import '../domain/track.dart';
import '../domain/track_point.dart';
import '../domain/tracker_status.dart';
import '../domain/tracking_config.dart';

final class TrackBundle {
  const TrackBundle({required this.track, required this.segments});

  final Track track;
  final List<TrackSegmentWithPoints> segments;
}

final class PointWriteRequest {
  const PointWriteRequest({
    required this.trackId,
    required this.sample,
    required this.activity,
    required this.motionState,
    required this.accepted,
    required this.qualityFlags,
    this.rejectionReason,
  });

  final String trackId;
  final LocationSample sample;
  final ActivitySnapshot activity;
  final MotionState motionState;
  final bool accepted;
  final int qualityFlags;
  final String? rejectionReason;
}

enum TrackOperationType { pause, complete }

enum TrackCommandType { pause, complete }

final class PendingTrackCommand {
  const PendingTrackCommand({
    required this.id,
    required this.trackId,
    required this.type,
    required this.reason,
    required this.createdAt,
    this.operationId,
  });

  final String id;
  final String trackId;
  final TrackCommandType type;
  final String reason;
  final DateTime createdAt;
  final String? operationId;
}

enum UploadOutboxKind { points, completion }

enum UploadOutboxState { pending, leased }

/// A durable upload task stored alongside its track.
final class UploadOutboxEntry {
  const UploadOutboxEntry({
    required this.id,
    required this.trackId,
    required this.kind,
    required this.idempotencyKey,
    required this.state,
    required this.attemptCount,
    required this.nextAttemptAt,
    required this.createdAt,
    required this.updatedAt,
    this.firstSequence,
    this.lastSequence,
    this.lastError,
    this.leaseOwner,
    this.leaseExpiresAt,
  });

  final String id;
  final String trackId;
  final UploadOutboxKind kind;
  final int? firstSequence;
  final int? lastSequence;
  final String idempotencyKey;
  final UploadOutboxState state;
  final int attemptCount;
  final String? lastError;
  final DateTime nextAttemptAt;
  final String? leaseOwner;
  final DateTime? leaseExpiresAt;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// A claimed outbox task. Only [leaseOwner] may acknowledge or fail it.
final class UploadOutboxLease {
  const UploadOutboxLease({
    required this.entry,
    required this.leaseOwner,
    this.points = const <TrackPoint>[],
  });

  final UploadOutboxEntry entry;
  final String leaseOwner;
  final List<TrackPoint> points;
}

typedef UploadBatchEncodedSize = int Function(List<TrackPoint> points);

/// Optional durable-upload capability implemented by the SQLite repository.
///
/// Keeping this separate from [TrackRepository] preserves compatibility for
/// hosts with custom repositories that do not opt into the built-in uploader.
abstract interface class UploadOutboxRepository {
  Future<UploadOutboxLease?> leaseNextUpload({
    required String trackId,
    required String leaseOwner,
    required Duration leaseDuration,
    required int maximumPointCount,
    required int maximumEncodedBytes,
    required UploadBatchEncodedSize encodedSize,
  });

  Future<void> acknowledgePointUpload({
    required String outboxId,
    required String leaseOwner,
    required int acceptedThroughSequence,
    Iterable<int> rejectedSequences = const <int>[],
  });

  Future<void> acknowledgeCompletionUpload({
    required String outboxId,
    required String leaseOwner,
  });

  Future<void> failUpload({
    required String outboxId,
    required String leaseOwner,
    required String error,
    required DateTime nextAttemptAt,
  });

  Future<void> enqueueTrackCompletion(String trackId);
  Future<List<String>> pendingUploadTrackIds();
  Future<UploadOutboxEntry?> getUploadOutboxEntry(
    String trackId,
    UploadOutboxKind kind,
  );
}

abstract interface class TrackRepository {
  Stream<Track?> get currentTrackStream;

  Future<void> initialize();
  Future<String> createTrack({
    required String userId,
    required String organizationId,
    String? patrolId,
    required TrackingConfig config,
    String? requestedTrackId,
  });
  Future<void> markTrackActive(String trackId);
  Future<void> pauseTrack(
    String trackId, {
    required String reason,
    String? operationId,
  });
  Future<Track> prepareResume(
    String trackId,
  );
  Future<void> completeTrack(
    String trackId, {
    required String reason,
    String? operationId,
  });
  Future<void> interruptTrack(String trackId, {required String reason});
  Future<TrackPoint> appendPoint(PointWriteRequest request);
  Future<Track?> getTrack(String trackId);
  Future<List<Track>> listTracks();
  Future<void> deleteTracksExcept(Set<String> retainedTrackIds);
  Future<Track?> findActiveTrack();
  Future<Track?> findLatestPausedTrack();
  Future<TrackPoint?> findLastAcceptedPoint(
    String trackId, {
    String? segmentId,
  });
  Future<TrackBundle> loadTrackBundle(String trackId);
  Future<List<TrackPoint>> pendingAcceptedPoints(
    String trackId, {
    required int limit,
  });
  Future<void> markPointsSynced(String trackId, Iterable<int> sequences);
  Future<PendingTrackCommand> beginLifecycleCommand({
    required String trackId,
    required TrackCommandType type,
    required String reason,
    String? operationId,
  });
  Future<PendingTrackCommand?> findPendingLifecycleCommand();
  Future<void> clearPendingLifecycleCommand(String commandId);
  Future<bool> wasOperationApplied(
    String trackId, {
    required String operationId,
    required TrackOperationType type,
  });
  Future<void> recordHealthEvent({
    String? trackId,
    required String type,
    Map<String, Object?>? details,
  });
  Future<void> close();
}
