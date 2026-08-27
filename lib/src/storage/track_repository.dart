import '../domain/activity_snapshot.dart';
import '../domain/export_models.dart';
import '../domain/location_sample.dart';
import '../domain/track.dart';
import '../domain/track_data_page.dart';
import '../domain/track_point.dart';
import '../domain/track_query.dart';
import '../domain/tracker_status.dart';
import '../domain/tracking_config.dart';
import '../domain/tracking_configuration_epoch.dart';
import '../domain/tracking_privacy.dart';
import '../domain/tracking_start.dart';

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

/// Optional accidental cross-account guard for upload discovery.
///
/// Authentication and upload credentials remain the host application's
/// responsibility. The built-in uploader uses this capability whenever an
/// owner-bound controller was opened.
abstract interface class OwnerScopedUploadOutboxRepository {
  Future<List<String>> pendingUploadTrackIdsForOwner(TrackingOwner owner);
}

/// Optional bounded route-history capability.
abstract interface class PaginatedTrackRepository {
  Future<TrackPage> listTrackPage(TrackQuery query);
}

/// Optional owner-scoped, bounded route-data capability.
///
/// Cursors are opaque and are valid only for the exact track, segment, and
/// accepted-point filter used to create them. Each first page fixes an upper
/// sequence/segment boundary, so concurrent appends are visible only to a new
/// traversal. The owner metadata is an accidental cross-account guard, not an
/// authentication boundary; host authentication remains the app's duty.
abstract interface class StreamingTrackRepository {
  Future<TrackDataSnapshot> createTrackDataSnapshot({
    required TrackingOwner owner,
    required String trackId,
  });

  Future<TrackSegmentPage> listSegmentPage({
    required TrackingOwner owner,
    required String trackId,
    required int limit,
    String? cursor,
    TrackDataSnapshot? snapshot,
  });

  Future<TrackPointPage> listPointPage({
    required TrackingOwner owner,
    required String trackId,
    String? segmentId,
    required int limit,
    String? cursor,
    bool acceptedOnly = false,
    TrackDataSnapshot? snapshot,
  });
}

/// Optional owner-scoped lookup for immutable point-policy provenance.
abstract interface class ConfigurationEpochRepository {
  Future<TrackingConfigurationEpoch?> getConfigurationEpoch({
    required TrackingOwner owner,
    required String trackId,
    required String epochId,
  });
}

/// Durable primitives for a pause-fenced runtime configuration switch.
abstract interface class MutableConfigurationEpochRepository {
  Future<TrackingConfigurationUpdateOperation> beginConfigurationUpdate({
    required TrackingOwner owner,
    required String trackId,
    required TrackingConfig config,
  });

  Future<void> markConfigurationUpdateStage({
    required String operationId,
    required TrackingConfigurationUpdateStage stage,
  });

  Future<TrackingConfigurationEpoch> activateConfigurationUpdate({
    required String operationId,
  });

  Future<void> cancelConfigurationUpdate(String operationId);

  Future<List<TrackingConfigurationUpdateOperation>>
      pendingConfigurationUpdates();
}

/// Optional repository capability for an explicit in-session route gap.
abstract interface class GapSegmentRepository {
  Future<String> beginGapSegment({
    required String trackId,
    required DateTime observedAt,
    required String reason,
  });
}

/// Owner-scoped route lookup and retention capability used by the safe facade.
///
/// Owner metadata prevents accidental cross-account access inside the package;
/// it is not an authentication boundary. Custom repositories must implement
/// this capability to participate in explicit owner-safe lifecycle APIs.
abstract interface class OwnerScopedTrackRepository {
  Stream<Track?> watchCurrentTrackForOwner(TrackingOwner owner);

  Future<Track?> getTrackForOwner(TrackingOwner owner, String trackId);

  Future<Track?> findActiveTrackForOwner(TrackingOwner owner);

  Future<Track?> findLatestPausedTrackForOwner(TrackingOwner owner);

  Future<List<Track>> listTracksForOwner(TrackingOwner owner);

  Future<void> deleteTrackForOwner(TrackingOwner owner, String trackId);

  Future<void> deleteTracksExceptForOwner(
    TrackingOwner owner,
    Set<String> retainedTrackIds,
  );
}

/// Durable owner-scoped primitives for additive abort/delete/erase workflows.
abstract interface class PrivacyTrackRepository {
  Future<TrackPrivacyOperationRecord> beginPrivacyOperation({
    required TrackingOwner owner,
    required String trackId,
    required String operationType,
    String? operationId,
  });

  Future<TrackPrivacyOperationRecord?> getPrivacyOperation(String operationId);

  Future<void> updatePrivacyOperation({
    required String operationId,
    required String stage,
    bool irreversibleCommitted = false,
    String status = 'pending',
    String? terminalReasonCode,
    bool completed = false,
    bool redactTrackIdentity = false,
  });

  Future<void> abortTrackForOwner({
    required TrackingOwner owner,
    required String trackId,
    required String reason,
    required String operationId,
  });

  Future<void> eraseTrackForOwner({
    required TrackingOwner owner,
    required String trackId,
    required String operationId,
  });

  Future<void> deleteRecordedTrackForOwner({
    required TrackingOwner owner,
    required String trackId,
    required String operationId,
  });
}

enum ManagedExportState { pending, committed, deleted }

/// Canonical inventory entry for an artifact created by the package.
final class ManagedExportRecord {
  const ManagedExportRecord({
    required this.id,
    required this.trackId,
    required this.format,
    required this.state,
    required this.createdAt,
    this.destination,
    this.committedAt,
    this.deletedAt,
  });

  final String id;
  final String trackId;
  final TrackExportFormat format;
  final ManagedExportState state;
  final TrackExportDestination? destination;
  final DateTime createdAt;
  final DateTime? committedAt;
  final DateTime? deletedAt;
}

/// Optional two-phase inventory used by V2 export and later scoped erase.
abstract interface class ManagedExportRepository {
  Future<String> beginManagedExport({
    required TrackingOwner owner,
    required String trackId,
    required TrackExportFormat format,
  });

  Future<void> commitManagedExport({
    required TrackingOwner owner,
    required String exportId,
    required TrackExportDestination destination,
  });

  Future<void> abortManagedExport({
    required TrackingOwner owner,
    required String exportId,
  });

  Future<ManagedExportRecord?> getManagedExport({
    required TrackingOwner owner,
    required String exportId,
  });

  Future<List<ManagedExportRecord>> listManagedExports({
    required TrackingOwner owner,
    required String trackId,
  });

  Future<void> markManagedExportDeleted({
    required TrackingOwner owner,
    required String exportId,
  });
}

abstract interface class TrackRepository {
  Stream<Track?> get currentTrackStream;

  Future<void> initialize();
  Future<String> createTrack({
    required String userId,
    required String organizationId,
    String? routeId,
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

  /// Permanently deletes a completed or failed track and its related data.
  ///
  /// Implementations must reject deletion of a track that can still be
  /// active, paused, or resumed.
  Future<void> deleteTrack(String trackId);
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
