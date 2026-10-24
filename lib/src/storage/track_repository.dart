import '../domain/activity_snapshot.dart';
import '../domain/export_models.dart';
import '../domain/location_sample.dart';
import '../domain/route_review.dart';
import '../domain/route_summary.dart';
import '../domain/step_coverage.dart';
import '../domain/track.dart';
import '../domain/track_data_page.dart';
import '../domain/track_point.dart';
import '../domain/track_query.dart';
import '../domain/track_stop.dart';
import '../domain/tracker_status.dart';
import '../domain/tracking_config.dart';
import '../domain/tracking_configuration_epoch.dart';
import '../domain/tracking_continuity.dart';
import '../domain/tracking_privacy.dart';
import '../domain/tracking_quality.dart';
import '../domain/tracking_start.dart';

final class TrackBundle {
  const TrackBundle({
    required this.track,
    required this.segments,
    this.stops = const <TrackStop>[],
    this.summary,
  });

  final Track track;
  final List<TrackSegmentWithPoints> segments;

  /// Stops of the track, one per place, oldest first, read in the same
  /// snapshot. Empty for repositories without [TrackStopRepository].
  final List<TrackStop> stops;

  /// The track's stored summary, read in the same snapshot; null for
  /// repositories without [RouteSummaryRepository].
  final RouteSummary? summary;
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
    this.qualityPolicyVersion,
  });

  final String trackId;
  final LocationSample sample;
  final ActivitySnapshot activity;
  final MotionState motionState;
  final bool accepted;
  final int qualityFlags;
  final String? rejectionReason;

  /// Quality policy version that produced [accepted], [qualityFlags] and
  /// [rejectionReason]. Repositories persist it as point provenance; when it
  /// is null they record the version of the epoch that covers the point.
  final int? qualityPolicyVersion;
}

/// Result of one atomic point/topology/gap transaction.
final class PointAppendResult {
  const PointAppendResult({
    required this.point,
    required this.segmentId,
    required this.duplicate,
    this.gap,
    this.stop,
  });

  final TrackPoint point;
  final String segmentId;
  final TrackingContinuityGap? gap;
  final bool duplicate;

  /// The stop the transaction opened, extended or closed, if any.
  final TrackStop? stop;
}

/// Optional atomic continuity capability for repositories that support the
/// schema-12 evidence model.
abstract interface class ContinuityTrackRepository {
  Future<TrackPoint?> findLastRawPoint(String trackId);

  Future<PointAppendResult> appendPointWithContinuity(
    PointWriteRequest request,
    TrackingContinuityDecision? continuity,
  );

  Future<List<TrackingContinuityGap>> listContinuityGaps(String trackId);
}

/// Optional capability: stop records written atomically with the fixes that
/// open, extend and close them (route database schema 16).
abstract interface class TrackStopRepository {
  /// Appends [request] like [ContinuityTrackRepository.appendPointWithContinuity]
  /// and applies [stop] in the same transaction. A duplicate native event
  /// applies no stop change.
  Future<PointAppendResult> appendPointWithStop(
    PointWriteRequest request,
    TrackingContinuityDecision? continuity,
    TrackStopChange? stop,
  );

  /// The current stop of [trackId], if one is open.
  Future<TrackStop?> findOpenTrackStop(String trackId);

  /// Stops of [trackId], oldest first.
  Future<List<TrackStop>> listTrackStops(String trackId);
}

/// Optional capability: the stored points quality policy 5's decision engine
/// re-reads to rebuild its state for a route after a restart.
abstract interface class DecisionTailRepository {
  /// The newest points of [segmentId] of [trackId] in sequence order, from
  /// the [contextAcceptedPoints]th last accepted point (or the segment's
  /// first point) on, at most [maximumPoints] of them; null for an unknown
  /// segment.
  Future<DecisionTail?> decisionTail(
    String trackId, {
    required String segmentId,
    int contextAcceptedPoints = 30,
    int maximumPoints = 5000,
  });
}

/// Points returned by [DecisionTailRepository.decisionTail].
final class DecisionTail {
  const DecisionTail({required this.segmentStartedAt, required this.points});

  /// When the segment began recording.
  final DateTime segmentStartedAt;

  /// Points in sequence order.
  final List<TrackPoint> points;
}

/// Optional capability: route details kept in the database as a route
/// records ([RouteSummary], [TripSummary]).
abstract interface class RouteSummaryRepository {
  /// [trackId]'s stored summary, computed first if it has none yet; null for
  /// an unknown track.
  Future<RouteSummary?> routeSummary(String trackId);

  /// [tripId]'s totals over its legs, stored and returned; null for an
  /// unknown Trip.
  Future<TripSummary?> tripSummary(String tripId);

  /// Recomputes [trackId]'s summary from its stored rows.
  Future<void> refreshRouteSummary(String trackId);

  /// Completed tracks whose stops are still [TrackStopSource.pending],
  /// oldest first; with [owner], only that owner's.
  Future<List<String>> tracksAwaitingStops({
    int limit = 20,
    TrackingOwner? owner,
  });

  /// Stores [stops], derived from [trackId]'s stored points, as its stop rows,
  /// one per place, and marks its stops [TrackStopSource.derived]. Does
  /// nothing unless its stops are still pending.
  Future<void> storeDerivedStops(String trackId, List<TrackStop> stops);

  /// Records [stepCount], the native step count of capture generation
  /// [captureGenerationId] read from status as capture stops, so the steps
  /// after the route's newest fix count too, and the counter's [coverage].
  /// A generation counts once, at its highest count: a count no higher than
  /// one already recorded for it adds nothing.
  Future<void> recordStepCount(
    String trackId, {
    required String? captureGenerationId,
    required int stepCount,
    StepCoverage? coverage,
  });

  /// Records [runId] as [trackId]'s current cleaned view, [distanceMeters]
  /// long.
  Future<void> recordCleanedGeometry(
    String trackId, {
    required String runId,
    required double distanceMeters,
  });
}

/// Optional capability: routes recorded under older rules, decided again
/// under the current ones ([RouteReview]) and stored beside what they
/// recorded (route database schema 18).
abstract interface class RouteReviewRepository {
  /// Completed routes, oldest first, recorded entirely under quality
  /// policies older than [RouteReview.qualityPolicyVersion] and without a
  /// current review of [RouteReview.version]; with [owner], only that
  /// owner's.
  Future<List<String>> tracksAwaitingReview({
    int limit = 20,
    TrackingOwner? owner,
  });

  /// Whether [trackId] is one of [tracksAwaitingReview].
  Future<bool> awaitsReview(String trackId);

  /// [trackId]'s configuration epochs, oldest first.
  Future<List<TrackingConfigurationEpoch>> configurationEpochsOf(
    String trackId,
  );

  /// Ids of the fixes review run [runId] keeps.
  Future<Set<String>> keptPointIdsOf(String runId);

  /// Stores [review] as its route's current review in one transaction,
  /// replacing an older one, and returns the id of its derived-geometry run
  /// (the fixes the review keeps). The route's points, their acceptance, its
  /// measured distance and its uploads stay as recorded. Returns null without
  /// storing when the route is not completed or the review does not cover
  /// its newest point.
  Future<String?> storeRouteReview(RouteReview review);

  /// Removes [trackId]'s review; the rows it recorded count again.
  Future<void> deleteRouteReview(String trackId);
}

/// Optional capability: health events recorded once per key, so events
/// rebuilt from journal payloads replayed after a restart never repeat.
abstract interface class KeyedHealthEventRepository {
  /// Records a health event under [key] unless one is already recorded.
  Future<void> recordKeyedHealthEvent({
    required String key,
    String? trackId,
    required String type,
    required DateTime occurredAt,
    Map<String, Object?>? details,
  });
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

/// Optional privacy-safe quality diagnostics supported by schema 13 stores.
abstract interface class QualityDiagnosticsRepository {
  Future<TrackingQualitySummary> trackQualitySummary({
    required TrackingOwner owner,
    required String trackId,
  });

  Future<TrackingQualitySummary> tripQualitySummary({
    required TrackingOwner owner,
    required String tripId,
  });
}

/// Optional lookup of the immutable epoch that covers an active track's next
/// point.
///
/// The tracking client evaluates each fix under the policy versions this epoch
/// recorded, so upgrading the package never reinterprets a route that is
/// already recording. Repositories without this capability are evaluated under
/// the current policy versions.
abstract interface class ActiveConfigurationEpochRepository {
  Future<TrackingConfigurationEpoch?> activeConfigurationEpoch(String trackId);
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

/// Optional audit used to coalesce only proven-safe legacy callback gaps.
abstract interface class LegacyGapEvidenceRepository {
  Future<Set<String>> safeLegacyAutomaticAfterSegmentIds(String trackId);
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
