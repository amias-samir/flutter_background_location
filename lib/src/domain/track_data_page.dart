import 'dart:collection';

import 'track_point.dart';
import 'track_segment.dart';

/// Stable upper bounds shared by every page traversal of one route snapshot.
///
/// This value contains no owner identifiers. The repository verifies owner
/// scope again for every page that consumes it.
final class TrackDataSnapshot {
  const TrackDataSnapshot({
    required this.trackId,
    required this.upperSegmentNumber,
    required this.upperSequence,
  });

  final String trackId;
  final int upperSegmentNumber;
  final int upperSequence;
}

/// One deterministic page of route segments.
///
/// A traversal is bounded to the segment-number snapshot captured by its first
/// page. Segments created after that first read appear only in a new traversal.
final class TrackSegmentPage {
  TrackSegmentPage({
    required Iterable<TrackSegment> items,
    required this.hasMore,
    required this.snapshotUpperSegmentNumber,
    required this.estimatedDecodedBytes,
    this.nextCursor,
  }) : items = UnmodifiableListView<TrackSegment>(
          List<TrackSegment>.of(items, growable: false),
        );

  /// Segments ordered by ascending persisted segment number.
  final List<TrackSegment> items;

  /// Opaque cursor for the next page in this snapshot traversal.
  final String? nextCursor;

  /// Whether another page exists in this snapshot traversal.
  final bool hasMore;

  /// Inclusive segment-number boundary fixed by the first page.
  final int snapshotUpperSegmentNumber;

  /// Conservative estimate of the decoded objects returned by this page.
  final int estimatedDecodedBytes;
}

/// One deterministic page of persisted route points.
///
/// A traversal is bounded to the sequence snapshot captured by its first page.
/// Concurrently appended fixes appear only in a new traversal. Accepted and
/// rejected points retain their original quality evidence.
final class TrackPointPage {
  TrackPointPage({
    required Iterable<TrackPoint> items,
    required this.hasMore,
    required this.snapshotUpperSequence,
    required this.estimatedDecodedBytes,
    this.nextCursor,
  }) : items = UnmodifiableListView<TrackPoint>(
          List<TrackPoint>.of(items, growable: false),
        );

  /// Points ordered by ascending persisted route sequence.
  final List<TrackPoint> items;

  /// Opaque cursor for the next page in this snapshot traversal.
  final String? nextCursor;

  /// Whether another page exists in this snapshot traversal.
  final bool hasMore;

  /// Inclusive sequence boundary fixed by the first page.
  final int snapshotUpperSequence;

  /// Conservative estimate of the decoded objects returned by this page.
  final int estimatedDecodedBytes;
}
