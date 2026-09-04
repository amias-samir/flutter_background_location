import '../domain/track.dart';
import '../domain/trip.dart';
import '../domain/trip_query.dart';
import '../domain/tracking_config.dart';
import '../domain/tracking_start.dart';

enum TripOperationType { start, endDay, continueTrip, complete }

enum TripOperationStage {
  prepared,
  nativeStopped,
  legCommitted,
  nativeStarted,
  completed,
  failed,
}

enum TripUploadOutboxState { pending, leased, acknowledged }

/// Durable final-Trip completion task and acknowledgement receipt.
final class TripUploadOutboxEntry {
  const TripUploadOutboxEntry({
    required this.id,
    required this.tripId,
    required this.lifecycleRevision,
    required this.idempotencyKey,
    required this.state,
    required this.attemptCount,
    required this.nextAttemptAt,
    required this.createdAt,
    required this.updatedAt,
    this.lastError,
    this.leaseOwner,
    this.leaseExpiresAt,
    this.acknowledgedAt,
  });

  final String id;
  final String tripId;
  final int lifecycleRevision;
  final String idempotencyKey;
  final TripUploadOutboxState state;
  final int attemptCount;
  final String? lastError;
  final DateTime nextAttemptAt;
  final String? leaseOwner;
  final DateTime? leaseExpiresAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? acknowledgedAt;

  factory TripUploadOutboxEntry.fromDatabase(Map<String, Object?> row) {
    DateTime? optionalDate(String key) {
      final value = row[key] as String?;
      return value == null ? null : DateTime.parse(value).toUtc();
    }

    return TripUploadOutboxEntry(
      id: row['id']! as String,
      tripId: row['trip_id']! as String,
      lifecycleRevision: (row['lifecycle_revision']! as num).toInt(),
      idempotencyKey: row['idempotency_key']! as String,
      state: TripUploadOutboxState.values.byName(row['state']! as String),
      attemptCount: (row['attempt_count']! as num).toInt(),
      lastError: row['last_error'] as String?,
      nextAttemptAt: DateTime.parse(row['next_attempt_at']! as String).toUtc(),
      leaseOwner: row['lease_owner'] as String?,
      leaseExpiresAt: optionalDate('lease_expires_at'),
      createdAt: DateTime.parse(row['created_at']! as String).toUtc(),
      updatedAt: DateTime.parse(row['updated_at']! as String).toUtc(),
      acknowledgedAt: optionalDate('acknowledged_at'),
    );
  }
}

final class TripUploadOutboxLease {
  const TripUploadOutboxLease({
    required this.entry,
    required this.trip,
    required this.leaseOwner,
  });

  final TripUploadOutboxEntry entry;
  final Trip trip;
  final String leaseOwner;
}

final class TripOperationRecord {
  const TripOperationRecord({
    required this.id,
    required this.tripId,
    required this.type,
    required this.operationId,
    required this.stage,
    required this.createdAt,
    required this.updatedAt,
    this.reason,
    this.legTrackId,
    this.completedAt,
  });

  final String id;
  final String tripId;
  final TripOperationType type;
  final String operationId;
  final TripOperationStage stage;
  final String? reason;
  final String? legTrackId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;

  factory TripOperationRecord.fromDatabase(Map<String, Object?> row) =>
      TripOperationRecord(
        id: row['id']! as String,
        tripId: row['trip_id']! as String,
        type: TripOperationType.values.byName(row['operation_type']! as String),
        operationId: row['operation_id']! as String,
        stage: TripOperationStage.values.byName(row['stage']! as String),
        reason: row['reason'] as String?,
        legTrackId: row['leg_track_id'] as String?,
        createdAt: DateTime.parse(row['created_at']! as String).toUtc(),
        updatedAt: DateTime.parse(row['updated_at']! as String).toUtc(),
        completedAt: row['completed_at'] == null
            ? null
            : DateTime.parse(row['completed_at']! as String).toUtc(),
      );
}

final class PreparedTripLeg {
  const PreparedTripLeg({
    required this.trip,
    required this.leg,
    required this.track,
    required this.operation,
    required this.created,
  });

  final Trip trip;
  final TripLeg leg;
  final Track track;
  final TripOperationRecord operation;
  final bool created;
}

/// Optional owner-safe persistence capability for multi-day journeys.
abstract interface class TripRepository {
  Future<Trip?> getTripForOwner(TrackingOwner owner, String tripId);

  Future<TripPage> listTripPage(TripQuery query);

  Future<TripLegPage> listTripLegPage({
    required TrackingOwner owner,
    required String tripId,
    required int limit,
    String? cursor,
  });

  Future<TripBundle> loadTripBundleForOwner(
    TrackingOwner owner,
    String tripId,
  );

  Future<PreparedTripLeg> registerImplicitTripStart({
    required TrackingOwner owner,
    required String tripId,
    required String operationId,
    MultiDayRoutePresentation routePresentation =
        MultiDayRoutePresentation.separateRecordedParts,
    RouteCaptureIntent captureIntent = RouteCaptureIntent.adaptive,
    String? reason,
  });

  Future<PreparedTripLeg> prepareNextTripLeg({
    required TrackingOwner owner,
    required String tripId,
    required TrackingConfig config,
    required String operationId,
    bool confirmCompletedTripContinuation = false,
    bool allowRevisionAfterAcknowledgedCompletion = false,
    String? dayLabel,
  });

  Future<TripOperationRecord> beginTripOperation({
    required TrackingOwner owner,
    required String tripId,
    required String trackId,
    required TripOperationType type,
    required String operationId,
    String? reason,
  });

  Future<void> markTripOperationStage({
    required String operationRecordId,
    required TripOperationStage stage,
  });

  Future<void> suspendTripAfterLegCompletion({
    required TrackingOwner owner,
    required String tripId,
    required String trackId,
    required String reason,
    required String operationId,
  });

  Future<void> completeTripAfterLegCompletion({
    required TrackingOwner owner,
    required String tripId,
    required String trackId,
    required String reason,
    required String operationId,
  });

  Future<List<TripOperationRecord>> pendingTripOperations();

  Future<TripOperationRecord?> findTripOperationForOwner({
    required TrackingOwner owner,
    required String operationId,
    TripOperationType? type,
  });

  Future<Trip> verifyAndRepairTripAggregates({
    required TrackingOwner owner,
    required String tripId,
  });

  Future<void> deleteTripForOwner(TrackingOwner owner, String tripId);
}

/// Optional durable capability for a revisioned combined-Trip completion.
abstract interface class TripUploadOutboxRepository {
  Future<void> enqueueTripCompletion({
    required TrackingOwner owner,
    required String tripId,
  });

  Future<TripUploadOutboxLease?> leaseNextTripCompletion({
    required TrackingOwner owner,
    required String leaseOwner,
    required Duration leaseDuration,
  });

  Future<void> acknowledgeTripCompletionUpload({
    required String outboxId,
    required String leaseOwner,
  });

  Future<void> failTripCompletionUpload({
    required String outboxId,
    required String leaseOwner,
    required String error,
    required DateTime nextAttemptAt,
  });

  Future<bool> hasAcknowledgedTripCompletion({
    required String tripId,
  });

  Future<List<TripUploadOutboxEntry>> listTripUploadEntriesForOwner(
    TrackingOwner owner,
  );
}

/// Optional destructive capability used by confirmed whole-Trip erasure.
abstract interface class TripPrivacyRepository {
  Future<void> eraseTripForOwner(TrackingOwner owner, String tripId);
}
