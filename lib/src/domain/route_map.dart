import 'route_geometry.dart';
import 'route_summary.dart';
import 'track_stop.dart';

/// The stored layers a route map can draw, in the order a map offers them.
///
/// Host map-matched runs stay host-selected through
/// `TrackingGeometryController.loadTrackGeometry`.
enum RouteGeometryView {
  /// The fixes the route's review keeps, at their recorded coordinates:
  /// routes recorded under older quality rules and reviewed since.
  reviewed,

  /// The stop-aware cleaned view, prepared in the background. Points it does
  /// not cover yet, such as a recording route's newest ones, are drawn as
  /// recorded.
  cleaned,

  /// The accepted points as recorded.
  raw,
}

/// A route or Trip ready to draw, read without writing to the route
/// database (`TrackingMapController`).
final class RouteMap {
  RouteMap({
    required this.geometry,
    required this.view,
    required Iterable<RouteGeometryView> views,
    Iterable<TrackStop> stops = const <TrackStop>[],
    this.routeSummary,
    this.tripSummary,
    this.preparing = false,
  })  : views = List<RouteGeometryView>.unmodifiable(views),
        stops = List<TrackStop>.unmodifiable(stops);

  /// The route assembled by `RouteGeometryAssembler` from the recorded
  /// accepted points (or, in [RouteGeometryView.reviewed], the kept fixes),
  /// with each point at its [view] coordinates. Inferred connectors are
  /// measured between recorded coordinates and are presentation only.
  ///
  /// Points carry the fields a map draws: position, time, accuracy, speed,
  /// heading, activity and acceptance. Journaled activity readings and
  /// activity probabilities are not loaded; `loadTrackBundle` or the point
  /// pages return the full evidence.
  final RouteGeometryReport geometry;

  /// The view [geometry] is drawn in.
  final RouteGeometryView view;

  /// The views this route offers, in [RouteGeometryView] order.
  final List<RouteGeometryView> views;

  /// The stored stops, oldest first: the review's when a route has one.
  final List<TrackStop> stops;

  /// The route's stored totals, for a single route.
  final RouteSummary? routeSummary;

  /// The Trip's totals, for a Trip.
  final TripSummary? tripSummary;

  /// Whether route details are still being prepared in the background: a
  /// review or stops of a route recorded under older rules, or the cleaned
  /// view of a completed route. A `TrackHistoryEvent` with
  /// `TrackHistoryChangeKind.updated` follows when they are stored; load the
  /// map again then.
  final bool preparing;
}
