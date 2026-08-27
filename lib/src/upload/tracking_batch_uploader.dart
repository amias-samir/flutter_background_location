import 'dart:async';
import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../domain/track.dart';
import '../domain/track_point.dart';
import '../domain/tracking_start.dart';
import '../storage/track_repository.dart';
import 'track_uploader.dart';

typedef UploadJitterSource = double Function();
typedef UploadRetryTimerFactory = Timer Function(
  Duration delay,
  void Function() callback,
);

/// Drains a SQLite-backed, leased upload outbox one track at a time.
final class TrackingBatchUploader {
  TrackingBatchUploader({
    required this.repository,
    required this.uploader,
    required this.maximumPointCount,
    this.maximumEncodedBytes = 256 * 1024,
    this.leaseDuration = const Duration(minutes: 2),
    this.initialBackoff = const Duration(seconds: 5),
    this.maximumBackoff = const Duration(minutes: 15),
    DateTime Function()? clock,
    UploadJitterSource? jitter,
    UploadRetryTimerFactory? retryTimerFactory,
    String? leaseOwner,
    this.owner,
  })  : _outbox = repository is UploadOutboxRepository
            ? repository as UploadOutboxRepository
            : throw ArgumentError.value(
                repository,
                'repository',
                'Durable upload requires an UploadOutboxRepository.',
              ),
        _clock = clock ?? _utcNow,
        _jitter = jitter ?? _randomJitter,
        _retryTimerFactory = retryTimerFactory ?? _timer,
        _leaseOwner = leaseOwner ?? const Uuid().v4() {
    if (maximumPointCount <= 0 || maximumEncodedBytes <= 0) {
      throw ArgumentError('Upload batch limits must be positive.');
    }
    if (leaseDuration <= Duration.zero ||
        initialBackoff <= Duration.zero ||
        maximumBackoff < initialBackoff) {
      throw ArgumentError('Upload lease and retry durations are invalid.');
    }
  }

  final TrackRepository repository;
  final TrackUploader uploader;
  final int maximumPointCount;
  final int maximumEncodedBytes;
  final Duration leaseDuration;
  final Duration initialBackoff;
  final Duration maximumBackoff;
  final UploadOutboxRepository _outbox;
  final DateTime Function() _clock;
  final UploadJitterSource _jitter;
  final UploadRetryTimerFactory _retryTimerFactory;
  final String _leaseOwner;
  final TrackingOwner? owner;
  final Map<String, Future<void>> _drains = <String, Future<void>>{};
  final Map<String, Timer> _retryTimers = <String, Timer>{};
  bool _disposed = false;

  static final math.Random _random = math.Random.secure();

  static DateTime _utcNow() => DateTime.now().toUtc();
  static double _randomJitter() => _random.nextDouble();
  static Timer _timer(Duration delay, void Function() callback) =>
      Timer(delay, callback);

  /// Makes completion durable before attempting its network handshake.
  Future<void> enqueueCompletion(String trackId) =>
      _outbox.enqueueTrackCompletion(trackId);

  /// Discovers unfinished point and completion work, including after restart.
  Future<void> tryDrainAll() async {
    final scope = owner;
    final trackIds = scope == null
        ? await _outbox.pendingUploadTrackIds()
        : _outbox is OwnerScopedUploadOutboxRepository
            ? await (_outbox as OwnerScopedUploadOutboxRepository)
                .pendingUploadTrackIdsForOwner(scope)
            : throw StateError(
                'Owner-bound upload requires an owner-scoped outbox.',
              );
    Object? firstError;
    StackTrace? firstStackTrace;
    await Future.wait(
      trackIds.map((trackId) async {
        try {
          await tryDrain(trackId);
        } catch (error, stackTrace) {
          firstError ??= error;
          firstStackTrace ??= stackTrace;
        }
      }),
    );
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  Future<void> tryDrain(String trackId) async {
    if (_disposed) return;
    final existing = _drains[trackId];
    if (existing != null) {
      await existing;
      return;
    }
    final drain = _drain(trackId);
    _retryTimers.remove(trackId)?.cancel();
    _drains[trackId] = drain;
    try {
      await drain;
    } finally {
      if (identical(_drains[trackId], drain)) _drains.remove(trackId);
    }
  }

  Future<void> _drain(String trackId) async {
    while (true) {
      final track = await repository.getTrack(trackId);
      if (track == null) return;
      final scope = owner;
      if (scope != null && !scope.owns(track)) {
        throw StateError('Upload work is outside the bound owner scope.');
      }
      final configuredPointCount = track.config.batchPointCount;
      final pointLimit = math.min(maximumPointCount, configuredPointCount);
      final lease = await _outbox.leaseNextUpload(
        trackId: trackId,
        leaseOwner: _leaseOwner,
        leaseDuration: leaseDuration,
        maximumPointCount: pointLimit,
        maximumEncodedBytes: maximumEncodedBytes,
        encodedSize: (points) => _batchFor(trackId, points).encodedByteLength,
      );
      if (lease == null) {
        await _schedulePersistedWakeup(trackId);
        return;
      }

      try {
        if (lease.entry.kind == UploadOutboxKind.points) {
          await _uploadPoints(lease);
        } else {
          await _uploadCompletion(lease, track);
        }
      } catch (error, stackTrace) {
        final nextAttemptAt = _clock().toUtc().add(
              _retryDelay(lease.entry.attemptCount + 1),
            );
        try {
          await _outbox.failUpload(
            outboxId: lease.entry.id,
            leaseOwner: lease.leaseOwner,
            error: error.toString(),
            nextAttemptAt: nextAttemptAt,
          );
          _scheduleRetry(trackId, nextAttemptAt);
        } on Object {
          // A newer process may already have reclaimed the expired lease. The
          // original transport/storage error remains the useful failure.
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    }
  }

  Future<void> _uploadPoints(UploadOutboxLease lease) async {
    final batch = _batchFor(lease.entry.trackId, lease.points);
    if (batch.idempotencyKey != lease.entry.idempotencyKey) {
      throw StateError('The durable upload batch identity changed.');
    }
    if (batch.encodedByteLength > maximumEncodedBytes) {
      throw StateError('The durable upload batch exceeds its byte limit.');
    }
    final acknowledgement = await uploader.uploadPoints(batch);
    await _outbox.acknowledgePointUpload(
      outboxId: lease.entry.id,
      leaseOwner: lease.leaseOwner,
      acceptedThroughSequence: acknowledgement.acceptedThroughSequence,
      rejectedSequences: acknowledgement.rejectedSequences,
    );
  }

  Future<void> _uploadCompletion(
    UploadOutboxLease lease,
    Track track,
  ) async {
    if (track.status != TrackStatus.completed) {
      throw StateError('Only a completed track may upload its completion.');
    }
    final implementation = uploader;
    if (implementation is IdempotentTrackCompletionUploader) {
      await implementation.completeTrackIdempotently(
        track: track,
        idempotencyKey: lease.entry.idempotencyKey,
      );
    } else {
      // Backward-compatible uploaders use track.id as the stable completion
      // identity and should make that endpoint idempotent.
      await implementation.completeTrack(track);
    }
    await _outbox.acknowledgeCompletionUpload(
      outboxId: lease.entry.id,
      leaseOwner: lease.leaseOwner,
    );
  }

  TrackUploadBatch _batchFor(String trackId, List<TrackPoint> points) {
    if (points.isEmpty) {
      throw StateError('A point upload batch must not be empty.');
    }
    final first = points.first.sequence;
    final last = points.last.sequence;
    return TrackUploadBatch(
      trackId: trackId,
      firstSequence: first,
      lastSequence: last,
      idempotencyKey: '$trackId:$first:$last',
      points: List<TrackPoint>.unmodifiable(points),
    );
  }

  Duration _retryDelay(int attemptNumber) {
    final exponent = math.min(math.max(attemptNumber - 1, 0), 30);
    final exponentialMilliseconds =
        initialBackoff.inMilliseconds * math.pow(2, exponent);
    final cappedMilliseconds = math.min(
      exponentialMilliseconds.round(),
      maximumBackoff.inMilliseconds,
    );
    final jitterValue = _jitter().clamp(0.0, 1.0);
    final jittered = (cappedMilliseconds * (0.5 + jitterValue)).round();
    final bounded = math.min(jittered, maximumBackoff.inMilliseconds);
    return Duration(milliseconds: math.max(1, bounded));
  }

  Future<void> _schedulePersistedWakeup(String trackId) async {
    final pointEntry =
        await _outbox.getUploadOutboxEntry(trackId, UploadOutboxKind.points);
    final entry = pointEntry ??
        await _outbox.getUploadOutboxEntry(
          trackId,
          UploadOutboxKind.completion,
        );
    if (entry == null) return;
    final wakeAt = entry.state == UploadOutboxState.leased
        ? entry.leaseExpiresAt
        : entry.nextAttemptAt;
    if (wakeAt != null) _scheduleRetry(trackId, wakeAt);
  }

  void _scheduleRetry(String trackId, DateTime wakeAt) {
    if (_disposed) return;
    final delay = wakeAt.difference(_clock().toUtc());
    _retryTimers.remove(trackId)?.cancel();
    late final Timer timer;
    timer = _retryTimerFactory(
      delay.isNegative ? Duration.zero : delay,
      () {
        if (identical(_retryTimers[trackId], timer)) {
          _retryTimers.remove(trackId);
        }
        unawaited(tryDrain(trackId).catchError((Object _) {}));
      },
    );
    _retryTimers[trackId] = timer;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    await Future.wait(
        _drains.values.map((future) => future.catchError((_) {})));
  }
}
