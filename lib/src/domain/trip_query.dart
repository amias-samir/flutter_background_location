import 'trip.dart';
import 'tracking_start.dart';

/// Owner-scoped bounded query for user-visible Trips.
final class TripQuery {
  const TripQuery({
    required this.owner,
    this.limit = 20,
    this.cursor,
    this.statuses = const <TripStatus>{},
  }) : assert(limit > 0 && limit <= 100);

  final TrackingOwner owner;
  final int limit;
  final String? cursor;
  final Set<TripStatus> statuses;
}

/// Stable page of Trip summaries ordered newest first.
final class TripPage {
  TripPage({required Iterable<Trip> items, this.nextCursor})
      : items = List<Trip>.unmodifiable(items);

  final List<Trip> items;
  final String? nextCursor;
}

/// Stable page of ordered Trip legs.
final class TripLegPage {
  TripLegPage({required Iterable<TripLeg> items, this.nextCursor})
      : items = List<TripLeg>.unmodifiable(items);

  final List<TripLeg> items;
  final String? nextCursor;
}
