import 'dart:async';

import 'package:flutter_background_location_tracker/src/domain/track.dart';
import 'package:flutter_background_location_tracker/src/domain/track_point.dart';
import 'package:flutter_background_location_tracker/src/storage/track_repository.dart';
import 'package:flutter_background_location_tracker/src/upload/track_uploader.dart';
import 'package:flutter_background_location_tracker/src/upload/tracking_batch_uploader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_support.dart';

final class _ControlledUploader implements TrackUploader {
  final Map<String, Completer<void>> gates = <String, Completer<void>>{};
  final List<TrackUploadBatch> batches = <TrackUploadBatch>[];

  @override
  Future<void> completeTrack(Track track) async {}

  @override
  Future<TrackUploadAcknowledgement> uploadPoints(
    TrackUploadBatch batch,
  ) async {
    batches.add(batch);
    final gate = gates[batch.trackId];
    if (gate != null) await gate.future;
    return TrackUploadAcknowledgement(
      acceptedThroughSequence: batch.lastSequence,
    );
  }
}

final class _FailingUploader implements IdempotentTrackCompletionUploader {
  _FailingUploader({this.pointFailures = 0, this.completionFailures = 0});

  int pointFailures;
  int completionFailures;
  final List<TrackUploadBatch> batches = <TrackUploadBatch>[];
  final List<String> completionKeys = <String>[];

  @override
  Future<void> completeTrack(Track track) async {
    await completeTrackIdempotently(
      track: track,
      idempotencyKey: track.id,
    );
  }

  @override
  Future<void> completeTrackIdempotently({
    required Track track,
    required String idempotencyKey,
  }) async {
    completionKeys.add(idempotencyKey);
    if (completionFailures > 0) {
      completionFailures -= 1;
      throw StateError('completion transport failed');
    }
  }

  @override
  Future<TrackUploadAcknowledgement> uploadPoints(
    TrackUploadBatch batch,
  ) async {
    batches.add(batch);
    if (pointFailures > 0) {
      pointFailures -= 1;
      throw StateError('point transport failed');
    }
    return TrackUploadAcknowledgement(
      acceptedThroughSequence: batch.lastSequence,
    );
  }
}

final class _ManualTimer implements Timer {
  _ManualTimer(this.delay, this.callback);

  final Duration delay;
  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() => _active = false;

  void fire() {
    if (!_active) return;
    _active = false;
    _tick += 1;
    callback();
  }
}

Future<void> _waitForBatch(
  _ControlledUploader uploader,
  String trackId,
) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (uploader.batches.any((batch) => batch.trackId == trackId)) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('No upload batch was started for $trackId.');
}

void main() {
  late RepositoryHarness harness;

  setUp(() async {
    harness = RepositoryHarness();
    await harness.initialize();
  });

  tearDown(() => harness.repository.close());

  test('drains different tracks independently and joins same-track callers',
      () async {
    final firstTrack = await harness.createActiveTrack(trackId: 'upload-a');
    await harness.append(
      trackId: firstTrack,
      latitude: 27.7,
      longitude: 85.3,
    );
    await harness.repository.completeTrack(firstTrack, reason: 'finished');
    final secondTrack = await harness.createActiveTrack(trackId: 'upload-b');
    await harness.append(
      trackId: secondTrack,
      latitude: 27.8,
      longitude: 85.4,
    );
    await harness.repository.completeTrack(secondTrack, reason: 'finished');

    final uploader = _ControlledUploader()
      ..gates[firstTrack] = Completer<void>()
      ..gates[secondTrack] = Completer<void>();
    final batchUploader = TrackingBatchUploader(
      repository: harness.repository,
      uploader: uploader,
      maximumPointCount: 25,
    );

    final firstDrain = batchUploader.tryDrain(firstTrack);
    final duplicateFirstDrain = batchUploader.tryDrain(firstTrack);
    await _waitForBatch(uploader, firstTrack);
    final secondDrain = batchUploader.tryDrain(secondTrack);
    await _waitForBatch(uploader, secondTrack);

    expect(
      uploader.batches.where((batch) => batch.trackId == firstTrack),
      hasLength(1),
    );
    expect(
      uploader.batches.where((batch) => batch.trackId == secondTrack),
      hasLength(1),
    );

    uploader.gates[firstTrack]!.complete();
    uploader.gates[secondTrack]!.complete();
    await Future.wait(<Future<void>>[
      firstDrain,
      duplicateFirstDrain,
      secondDrain,
    ]);
    expect(
      await harness.repository.pendingAcceptedPoints(firstTrack, limit: 10),
      isEmpty,
    );
    expect(
      await harness.repository.pendingAcceptedPoints(secondTrack, limit: 10),
      isEmpty,
    );
    await batchUploader.dispose();
  });

  test('bounds batches by both point count and canonical encoded bytes',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'byte-bounds');
    for (var index = 0; index < 3; index += 1) {
      await harness.append(
        trackId: trackId,
        latitude: 27.7 + index / 10000,
        longitude: 85.3 + index / 10000,
      );
    }
    final points = await harness.repository.pendingAcceptedPoints(
      trackId,
      limit: 10,
    );
    final singlePointLimit = points
        .map(
          (point) => TrackUploadBatch(
            trackId: trackId,
            firstSequence: point.sequence,
            lastSequence: point.sequence,
            idempotencyKey: '$trackId:${point.sequence}:${point.sequence}',
            points: <TrackPoint>[point],
          ).encodedByteLength,
        )
        .reduce((left, right) => left > right ? left : right);
    final uploader = _ControlledUploader();
    final batchUploader = TrackingBatchUploader(
      repository: harness.repository,
      uploader: uploader,
      maximumPointCount: 10,
      maximumEncodedBytes: singlePointLimit,
    );

    await batchUploader.tryDrain(trackId);

    expect(uploader.batches, hasLength(3));
    expect(
      uploader.batches.expand((batch) => batch.points),
      hasLength(3),
    );
    expect(
      uploader.batches.every(
        (batch) =>
            batch.points.length == 1 &&
            batch.encodedByteLength <= singlePointLimit,
      ),
      isTrue,
    );
    await batchUploader.dispose();
  });

  test('persists failure attempts and respects durable next-attempt time',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'retry-points');
    await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
    );
    final uploader = _FailingUploader(pointFailures: 1);
    final batchUploader = TrackingBatchUploader(
      repository: harness.repository,
      uploader: uploader,
      maximumPointCount: 25,
      clock: () => harness.now,
      initialBackoff: const Duration(seconds: 10),
      maximumBackoff: const Duration(minutes: 1),
      jitter: () => 0.5,
    );

    await expectLater(batchUploader.tryDrain(trackId), throwsStateError);
    final failed = await harness.repository.getUploadOutboxEntry(
      trackId,
      UploadOutboxKind.points,
    );
    expect(failed, isNotNull);
    expect(failed!.state, UploadOutboxState.pending);
    expect(failed.attemptCount, 1);
    expect(failed.lastError, contains('point transport failed'));
    expect(
      failed.nextAttemptAt,
      harness.now.add(const Duration(seconds: 10)),
    );

    await batchUploader.tryDrain(trackId);
    expect(uploader.batches, hasLength(1));
    harness.now = harness.now.add(const Duration(seconds: 10));
    await batchUploader.tryDrain(trackId);
    expect(uploader.batches, hasLength(2));
    expect(
      await harness.repository.getUploadOutboxEntry(
        trackId,
        UploadOutboxKind.points,
      ),
      isNull,
    );
    await batchUploader.dispose();
  });

  test('reclaims an expired lease with the same idempotency key', () async {
    final trackId = await harness.createActiveTrack(trackId: 'expired-lease');
    await harness.append(
      trackId: trackId,
      latitude: 27.7,
      longitude: 85.3,
    );
    final abandoned = await harness.repository.leaseNextUpload(
      trackId: trackId,
      leaseOwner: 'old-process',
      leaseDuration: const Duration(minutes: 1),
      maximumPointCount: 25,
      maximumEncodedBytes: 256 * 1024,
      encodedSize: (points) => TrackUploadBatch(
        trackId: trackId,
        firstSequence: points.first.sequence,
        lastSequence: points.last.sequence,
        idempotencyKey:
            '$trackId:${points.first.sequence}:${points.last.sequence}',
        points: points,
      ).encodedByteLength,
    );
    final uploader = _ControlledUploader();
    final batchUploader = TrackingBatchUploader(
      repository: harness.repository,
      uploader: uploader,
      maximumPointCount: 25,
      clock: () => harness.now,
      leaseOwner: 'new-process',
    );

    await batchUploader.tryDrain(trackId);
    expect(uploader.batches, isEmpty);
    harness.now = harness.now.add(const Duration(minutes: 1));
    await batchUploader.tryDrain(trackId);

    expect(uploader.batches, hasLength(1));
    expect(uploader.batches.single.idempotencyKey,
        abandoned!.entry.idempotencyKey);
    await batchUploader.dispose();
  });

  test('scheduled completion retry preserves its durable idempotency row',
      () async {
    final trackId = await harness.createActiveTrack(trackId: 'completion');
    await harness.repository.completeTrack(trackId, reason: 'finished');
    final timers = <_ManualTimer>[];
    final uploader = _FailingUploader(completionFailures: 1);
    final batchUploader = TrackingBatchUploader(
      repository: harness.repository,
      uploader: uploader,
      maximumPointCount: 25,
      clock: () => harness.now,
      initialBackoff: const Duration(seconds: 10),
      maximumBackoff: const Duration(minutes: 1),
      jitter: () => 0.5,
      retryTimerFactory: (delay, callback) {
        final timer = _ManualTimer(delay, callback);
        timers.add(timer);
        return timer;
      },
    );
    await batchUploader.enqueueCompletion(trackId);

    await expectLater(batchUploader.tryDrain(trackId), throwsStateError);
    final failed = await harness.repository.getUploadOutboxEntry(
      trackId,
      UploadOutboxKind.completion,
    );
    expect(failed, isNotNull);
    expect(failed!.attemptCount, 1);
    expect(failed.idempotencyKey, '$trackId:completion');
    expect(timers.single.delay, const Duration(seconds: 10));

    harness.now = harness.now.add(timers.single.delay);
    timers.single.fire();
    await _waitForCompletion(uploader, expectedCalls: 2);

    expect(uploader.completionKeys, <String>[
      '$trackId:completion',
      '$trackId:completion',
    ]);
    expect(
      await harness.repository.getUploadOutboxEntry(
        trackId,
        UploadOutboxKind.completion,
      ),
      isNull,
    );
    await batchUploader.dispose();
  });
}

Future<void> _waitForCompletion(
  _FailingUploader uploader, {
  required int expectedCalls,
}) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (uploader.completionKeys.length >= expectedCalls) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Completion retry did not run.');
}
