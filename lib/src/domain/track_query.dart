import 'dart:collection';

import 'track.dart';

/// Bounded query for route-history summaries.
final class TrackQuery {
  TrackQuery({
    Iterable<TrackStatus> statuses = const <TrackStatus>[],
    this.startedAfter,
    this.startedBefore,
    this.routeId,
    this.userId,
    this.organizationId,
    this.limit = 50,
    this.cursor,
  }) : statuses =
            UnmodifiableSetView<TrackStatus>(Set<TrackStatus>.of(statuses));

  /// Optional status filter. Empty means all statuses.
  final Set<TrackStatus> statuses;

  /// Optional inclusive lower bound for route start time.
  final DateTime? startedAfter;

  /// Optional exclusive upper bound for route start time.
  final DateTime? startedBefore;

  /// Exact stored route ID match.
  final String? routeId;

  /// Optional owner user ID filter.
  final String? userId;

  /// Optional owner organization ID filter.
  final String? organizationId;

  /// Maximum number of summaries to return. Valid range: 1..200.
  final int limit;

  /// Opaque cursor returned by a previous page.
  final String? cursor;
}

/// One page of route-history summaries.
final class TrackPage {
  const TrackPage({
    required this.items,
    required this.hasMore,
    this.nextCursor,
  });

  /// Summary routes in newest-first order.
  final List<Track> items;

  /// Opaque cursor for the next page, when available.
  final String? nextCursor;

  /// Whether another page is available.
  final bool hasMore;
}
