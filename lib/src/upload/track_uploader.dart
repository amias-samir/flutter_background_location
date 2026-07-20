import 'dart:convert';

import '../domain/activity_snapshot.dart';
import '../domain/track.dart';
import '../domain/track_point.dart';

final class TrackUploadBatch {
  const TrackUploadBatch({
    required this.trackId,
    required this.firstSequence,
    required this.lastSequence,
    required this.idempotencyKey,
    required this.points,
  });

  final String trackId;
  final int firstSequence;
  final int lastSequence;
  final String idempotencyKey;
  final List<TrackPoint> points;

  /// Canonical transport-shaped representation used for encoded byte limits.
  Map<String, Object?> toMap() => <String, Object?>{
        'trackId': trackId,
        'firstSequence': firstSequence,
        'lastSequence': lastSequence,
        'idempotencyKey': idempotencyKey,
        'points': points.map(_pointToMap).toList(growable: false),
      };

  int get encodedByteLength => utf8.encode(jsonEncode(toMap())).length;
}

final class TrackUploadAcknowledgement {
  const TrackUploadAcknowledgement({
    required this.acceptedThroughSequence,
    this.rejectedSequences = const <int>[],
  });

  final int acceptedThroughSequence;
  final List<int> rejectedSequences;
}

abstract interface class TrackUploader {
  Future<TrackUploadAcknowledgement> uploadPoints(TrackUploadBatch batch);
  Future<void> completeTrack(Track track);
}

/// Optional extension that gives completion requests a stable outbox key.
///
/// Existing [TrackUploader] implementations remain source compatible. For
/// them, completion retries use the track identifier as their stable identity.
abstract interface class IdempotentTrackCompletionUploader
    implements TrackUploader {
  Future<void> completeTrackIdempotently({
    required Track track,
    required String idempotencyKey,
  });
}

Map<String, Object?> _pointToMap(TrackPoint point) => <String, Object?>{
      'id': point.id,
      'trackId': point.trackId,
      'segmentId': point.segmentId,
      'sequence': point.sequence,
      'latitude': point.latitude,
      'longitude': point.longitude,
      'altitude': point.altitude,
      'horizontalAccuracy': point.horizontalAccuracy,
      'verticalAccuracy': point.verticalAccuracy,
      'speed': point.speed,
      'speedAccuracy': point.speedAccuracy,
      'heading': point.heading,
      'headingAccuracy': point.headingAccuracy,
      'capturedAt': point.capturedAt.toUtc().toIso8601String(),
      'persistedAt': point.persistedAt.toUtc().toIso8601String(),
      'activityType': point.activityType.value,
      'activityConfidence': point.activityConfidence,
      'motionState': point.motionState.name,
      'provider': point.provider,
      'isMocked': point.isMocked,
      'mockDetectionAvailable': point.mockDetectionAvailable,
      'mockAssessment': point.mockAssessment.name,
      'mockEvidence': point.mockEvidence,
      'nativeEventId': point.nativeEventId,
      'qualityFlags': point.qualityFlags,
    };
