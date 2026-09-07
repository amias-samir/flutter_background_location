import 'package:uuid/uuid.dart';

import '../domain/trip.dart';
import '../domain/tracking_start.dart';
import '../storage/track_repository.dart';
import '../storage/trip_repository.dart';

/// Host transport for one immutable, revisioned Trip-completion summary.
abstract interface class TripCompletionUploader {
  Future<void> uploadTripCompletion({
    required Trip trip,
    required int lifecycleRevision,
    required String idempotencyKey,
  });
}

/// Explicit drain service for the optional combined-Trip completion outbox.
///
/// Daily Track uploads remain unchanged. Apps that need one server-side Trip
/// completion create this service with the same repository, owner scope, and
/// their transport implementation, then call [tryDrain] from their normal
/// connectivity/background-work scheduler.
final class TripCompletionUploadService {
  TripCompletionUploadService({
    required TrackRepository repository,
    required this.owner,
    required this.uploader,
    this.leaseDuration = const Duration(minutes: 2),
    this.retryDelay = const Duration(minutes: 1),
    DateTime Function()? clock,
    String? leaseOwner,
  })  : _outbox = repository is TripUploadOutboxRepository
            ? repository as TripUploadOutboxRepository
            : throw ArgumentError.value(
                repository,
                'repository',
                'Trip completion upload requires a TripUploadOutboxRepository.',
              ),
        _clock = clock ?? _utcNow,
        _leaseOwner = leaseOwner ?? const Uuid().v4() {
    if (leaseDuration <= Duration.zero || retryDelay <= Duration.zero) {
      throw ArgumentError(
          'Trip upload lease and retry delays must be positive.');
    }
  }

  final TrackingOwner owner;
  final TripCompletionUploader uploader;
  final Duration leaseDuration;
  final Duration retryDelay;
  final TripUploadOutboxRepository _outbox;
  final DateTime Function() _clock;
  final String _leaseOwner;

  static DateTime _utcNow() => DateTime.now().toUtc();

  /// Adds the current completed revision idempotently.
  Future<void> enqueue(String tripId) => _outbox.enqueueTripCompletion(
        owner: owner,
        tripId: tripId,
      );

  /// Drains every completion currently due for this owner.
  Future<int> tryDrain() async {
    var uploaded = 0;
    while (true) {
      final lease = await _outbox.leaseNextTripCompletion(
        owner: owner,
        leaseOwner: _leaseOwner,
        leaseDuration: leaseDuration,
      );
      if (lease == null) return uploaded;
      try {
        await uploader.uploadTripCompletion(
          trip: lease.trip,
          lifecycleRevision: lease.entry.lifecycleRevision,
          idempotencyKey: lease.entry.idempotencyKey,
        );
        await _outbox.acknowledgeTripCompletionUpload(
          outboxId: lease.entry.id,
          leaseOwner: lease.leaseOwner,
        );
        uploaded += 1;
      } on Object catch (error, stackTrace) {
        try {
          await _outbox.failTripCompletionUpload(
            outboxId: lease.entry.id,
            leaseOwner: lease.leaseOwner,
            error: error.toString(),
            nextAttemptAt: _clock().toUtc().add(retryDelay),
          );
        } on Object {
          // Preserve the transport failure when another worker reclaimed the
          // expired lease before the failure could be recorded.
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }
}
