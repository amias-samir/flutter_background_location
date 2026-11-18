import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as maplibre;

import 'route_totals.dart';
import 'ui_kit.dart';

/// Which version of a route the map draws.
enum RouteView {
  /// The route as the current rules decide it: the stored review of a route
  /// recorded under older rules ([DerivedGeometryAlgorithm.routeQualityReview]).
  reviewed('Reviewed', 'The fixes the current rules keep'),

  /// The stored cleaned view, where each stop is one point.
  cleaned('Cleaned', 'Each stop drawn as one point'),

  /// The route as recorded.
  raw('Raw', 'The route as recorded');

  const RouteView(this.label, this.description);

  /// The page's view of the package's [view].
  static RouteView of(RouteGeometryView view) => switch (view) {
    RouteGeometryView.reviewed => RouteView.reviewed,
    RouteGeometryView.cleaned => RouteView.cleaned,
    RouteGeometryView.raw => RouteView.raw,
  };

  final String label;
  final String description;

  /// The package's view for this one.
  RouteGeometryView get geometryView => switch (this) {
    RouteView.reviewed => RouteGeometryView.reviewed,
    RouteView.cleaned => RouteGeometryView.cleaned,
    RouteView.raw => RouteGeometryView.raw,
  };
}

/// A route as the map page draws it: [route] in [view], one of the [views]
/// the route has, in the order the page offers them.
final class RouteMapContent {
  const RouteMapContent({
    required this.route,
    this.view = RouteView.raw,
    this.views = const <RouteView>[RouteView.raw],
    this.preparing = false,
  });

  final RouteGeometry route;
  final RouteView view;
  final List<RouteView> views;

  /// Whether the package is still preparing details of the route in the
  /// background, such as its cleaned view ([RouteMap.preparing]).
  final bool preparing;
}

class TrackMapPage extends StatelessWidget {
  const TrackMapPage({
    super.key,
    required this.tracking,
    required this.track,
    this.showDiagnostics = true,
    @visibleForTesting this.mapBuilder = _mapLibreMap,
  });

  final Tracking tracking;
  final Track track;

  /// Draws the map; tests replace the MapLibre platform view.
  final RouteMapBuilder mapBuilder;

  /// Whether the page offers the route's views and continuity and draws
  /// gaps and uncertain stretches; without it the map shows the route and
  /// its stops only.
  final bool showDiagnostics;

  @override
  Widget build(BuildContext context) => RouteMapPage(
    title: track.routeId ?? 'Recorded route',
    showDiagnostics: showDiagnostics,
    mapBuilder: mapBuilder,
    initialContinuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
    // Only the package's map capability prepares details to wait for.
    updates: tracking is TrackingMapController && tracking is TrackingController
        ? (tracking as TrackingController).trackHistoryEvents
        : null,
    loader: (request, isCancelled) => tracking is TrackingMapController
        ? loadRouteMapContent(
            tracking as TrackingMapController,
            trackId: track.id,
            request: request,
            isCancelled: isCancelled,
            showDiagnostics: showDiagnostics,
          )
        : loadTrackMap(
            tracking,
            track.id,
            continuity: request.continuity,
            view: request.view,
          ),
  );
}

class TripMapPage extends StatelessWidget {
  const TripMapPage({
    super.key,
    required this.tracking,
    required this.trip,
    this.showDiagnostics = true,
    @visibleForTesting this.mapBuilder = _mapLibreMap,
  });

  final MultiDayTripController tracking;
  final Trip trip;

  /// As [TrackMapPage.showDiagnostics].
  final bool showDiagnostics;

  /// Draws the map; tests replace the MapLibre platform view.
  final RouteMapBuilder mapBuilder;

  @override
  Widget build(BuildContext context) => RouteMapPage(
    title: trip.routeId ?? 'Multi-day Trip',
    showDiagnostics: showDiagnostics,
    mapBuilder: mapBuilder,
    initialContinuity: trip.routePresentation.geometryContinuity,
    // Only the package's map capability prepares details to wait for.
    updates: tracking is TrackingMapController && tracking is TrackingController
        ? (tracking as TrackingController).trackHistoryEvents
        : null,
    loader: (request, isCancelled) => tracking is TrackingMapController
        ? loadRouteMapContent(
            tracking as TrackingMapController,
            tripId: trip.id,
            request: request,
            isCancelled: isCancelled,
            showDiagnostics: showDiagnostics,
          )
        : loadTripMap(
            tracking,
            trip.id,
            continuity: request.continuity,
            view: request.view,
          ),
  );
}

/// What the map page asks for: a [view], or the route's default, drawn
/// with [continuity].
@immutable
final class RouteMapRequest {
  const RouteMapRequest({required this.continuity, this.view});

  final RouteView? view;
  final RouteGeometryContinuity continuity;
}

/// Loads a route for the map page; [isCancelled] turns true once the page
/// no longer needs the result.
typedef RouteMapLoader =
    Future<RouteMapContent> Function(
      RouteMapRequest request,
      bool Function() isCancelled,
    );

/// A route or Trip from the package's read-only map capability
/// ([TrackingMapController]): one bounded read, no writes. The package
/// prepares missing details in the background and says so
/// ([RouteMapContent.preparing]).
Future<RouteMapContent> loadRouteMapContent(
  TrackingMapController maps, {
  String? trackId,
  String? tripId,
  required RouteMapRequest request,
  required bool Function() isCancelled,
  bool showDiagnostics = true,
}) async {
  assert((trackId == null) != (tripId == null));
  final view = request.view?.geometryView;
  final map = trackId != null
      ? await maps.loadTrackMap(
          trackId,
          view: view,
          continuity: request.continuity,
          isCancelled: isCancelled,
        )
      : await maps.loadTripMap(
          tripId!,
          view: view,
          continuity: request.continuity,
          isCancelled: isCancelled,
        );
  final totals = switch ((map.routeSummary, map.tripSummary)) {
    (final route?, _) => RouteTotals.ofRoute(route),
    (_, final trip?) => RouteTotals.ofTrip(trip),
    _ => null,
  };
  final route = await buildRouteGeometry(
    map.geometry,
    stops: map.stops,
    totals: totals,
    includeUncertainty: showDiagnostics,
  );
  return RouteMapContent(
    route: route,
    view: RouteView.of(map.view),
    views: <RouteView>[for (final view in map.views) RouteView.of(view)],
    preparing: map.preparing,
  );
}

/// Routes with at least this many points are turned into map geometry off
/// the UI isolate.
const _isolatePointThreshold = 2000;

/// [RouteGeometry.fromReport] for [report], off the UI isolate for a long
/// route.
Future<RouteGeometry> buildRouteGeometry(
  RouteGeometryReport report, {
  Iterable<TrackStop> stops = const <TrackStop>[],
  RouteTotals? totals,
  bool includeUncertainty = true,
}) {
  final pointCount = report.parts.fold<int>(
    0,
    (count, part) => count + part.points.length,
  );
  final stopList = stops.toList(growable: false);
  RouteGeometry build() => RouteGeometry.fromReport(
    report,
    stops: stopList,
    totals: totals,
    includeUncertainty: includeUncertainty,
  );
  if (pointCount < _isolatePointThreshold) return Future.value(build());
  return Isolate.run(build);
}

/// The map page of a route or Trip. The route loads once, again only when
/// the view or continuity changes, and the previous map stays on screen
/// meanwhile. Leaving the page cancels the load.
class RouteMapPage extends StatefulWidget {
  const RouteMapPage({
    super.key,
    required this.title,
    required this.loader,
    required this.initialContinuity,
    this.showDiagnostics = true,
    this.updates,
    this.mapBuilder = _mapLibreMap,
  });

  final String title;
  final RouteMapLoader loader;
  final RouteGeometryContinuity initialContinuity;
  final bool showDiagnostics;

  /// Route changes; while a route is being prepared, an update offers to
  /// show it.
  final Stream<TrackHistoryEvent>? updates;
  final RouteMapBuilder mapBuilder;

  @override
  State<RouteMapPage> createState() => _RouteMapPageState();
}

class _RouteMapPageState extends State<RouteMapPage> {
  late RouteGeometryContinuity _continuity;

  /// The view picked on the page; null draws the route's default view.
  RouteView? _view;
  RouteMapContent? _content;
  Object? _error;
  var _loading = true;

  /// Whether the details being prepared have been stored since the load.
  var _ready = false;
  var _generation = 0;
  StreamSubscription<TrackHistoryEvent>? _updates;
  Timer? _readyDebounce;

  @override
  void initState() {
    super.initState();
    _continuity = widget.initialContinuity;
    _updates = widget.updates?.listen(_onUpdate);
    unawaited(_load());
  }

  @override
  void dispose() {
    // Cancels a load in flight; its result is dropped.
    _generation += 1;
    unawaited(_updates?.cancel());
    _readyDebounce?.cancel();
    super.dispose();
  }

  void _onUpdate(TrackHistoryEvent event) {
    if (event.kind != TrackHistoryChangeKind.updated) return;
    if (!(_content?.preparing ?? false) || _ready) return;
    _readyDebounce?.cancel();
    _readyDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _ready = true);
    });
  }

  Future<void> _load() async {
    final generation = ++_generation;
    bool cancelled() => !mounted || generation != _generation;
    if (mounted && _content != null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final content = await widget.loader(
        RouteMapRequest(view: _view, continuity: _continuity),
        cancelled,
      );
      if (cancelled()) return;
      setState(() {
        _content = content;
        _error = null;
        _loading = false;
        _ready = false;
      });
    } on Object catch (error) {
      if (cancelled()) return;
      if (error is TrackingException && error.code == 'route_map_cancelled') {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _select({RouteView? view, RouteGeometryContinuity? continuity}) {
    if ((view == null || view == (_view ?? _content?.view)) &&
        (continuity == null || continuity == _continuity)) {
      return;
    }
    setState(() {
      _view = view ?? _view;
      _continuity = continuity ?? _continuity;
    });
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) => _RouteMapScaffold(
    title: widget.title,
    showDiagnostics: widget.showDiagnostics,
    mapBuilder: widget.mapBuilder,
    continuity: _continuity,
    content: _content,
    loading: _loading,
    error: _error,
    ready: _ready,
    onContinuityChanged: (value) => _select(continuity: value),
    onViewChanged: (value) => _select(view: value),
    onRetry: () => unawaited(_load()),
    onShowRecorded: () => _select(view: RouteView.raw),
    onShowReady: () => unawaited(_load()),
  );
}

/// Loads [trackId] for the map in [view] when the route has it, else in its
/// first view: reviewed when it has a review, else cleaned when [tracking]
/// can derive that, else as recorded.
Future<RouteMapContent> loadTrackMap(
  Tracking tracking,
  String trackId, {
  required RouteGeometryContinuity continuity,
  RouteView? view,
}) async {
  // Reading a route's stops first also reviews it, when it completed under
  // older rules.
  final stops = tracking is TrackingStopController
      ? await (tracking as TrackingStopController).listTrackStops(trackId)
      : const <TrackStop>[];
  if (tracking is! TrackingGeometryController) {
    final bundle = await tracking.loadTrackBundle(trackId);
    return RouteMapContent(
      route: RouteGeometry.fromReport(
        const RouteGeometryAssembler().assemble(
          sourceParts: _sourceParts(bundle, legNumber: 1),
          continuity: continuity,
        ),
        stops: stops,
        totals: bundle.summary == null
            ? null
            : RouteTotals.ofRoute(bundle.summary!),
      ),
    );
  }
  final geometry = tracking as TrackingGeometryController;
  final summaries = tracking is TrackingSummaryController
      ? tracking as TrackingSummaryController
      : null;
  final review = await reviewRunOf(geometry, trackId);
  final views = <RouteView>[
    if (review != null) RouteView.reviewed,
    if (summaries != null) RouteView.cleaned,
    RouteView.raw,
  ];
  final shown = views.contains(view) ? view! : views.first;
  final report = await geometry.assembleTrackRouteGeometry(
    trackId,
    continuity: continuity,
  );
  // The fixes the review keeps, at their recorded coordinates, with the
  // reviewed stops. They join across segments by the stored gaps only: the
  // facade does not expose the audit of legacy callback gaps.
  final reviewed = shown == RouteView.reviewed
      ? await geometry.loadTrackGeometry(
          trackId,
          geometry: TrackGeometrySelection.derived(review!.id),
        )
      : null;
  final cleaned = shown == RouteView.cleaned
      ? await cleanedCoordinates(geometry, summaries!, report)
      : null;
  return RouteMapContent(
    view: shown,
    views: views,
    route: RouteGeometry.fromReport(
      reviewed == null
          ? report
          : const RouteGeometryAssembler().assemble(
              sourceParts: _sourceParts(reviewed, legNumber: 1),
              gaps: report.gaps,
              continuity: continuity,
            ),
      cleaned: cleaned,
      stops: reviewed?.stops ?? stops,
      // Read after cleaning, which stores the cleaned distance.
      totals: summaries == null
          ? null
          : RouteTotals.ofRoute(await summaries.routeSummary(trackId)),
    ),
  );
}

/// Whether [tracking] can show the cleaned view.
bool _canClean(Object tracking) =>
    tracking is TrackingGeometryController &&
    tracking is TrackingSummaryController;

/// [trackId]'s stored review, or null when the route has none: it was
/// recorded under the current rules, or is not reviewed yet.
Future<DerivedGeometryRun?> reviewRunOf(
  TrackingGeometryController geometry,
  String trackId,
) async => currentReviewRun(await geometry.listDerivedGeometry(trackId));

/// The newest completed run of [runs] holding a route review
/// ([DerivedGeometryAlgorithm.routeQualityReview]); null when there is none.
DerivedGeometryRun? currentReviewRun(Iterable<DerivedGeometryRun> runs) {
  DerivedGeometryRun? newest;
  for (final run in runs) {
    if (run.algorithm != DerivedGeometryAlgorithm.routeQualityReview ||
        run.status != DerivedGeometryRunStatus.completed) {
      continue;
    }
    if (newest == null || run.createdAt.isAfter(newest.createdAt)) {
      newest = run;
    }
  }
  return newest;
}

/// [bundle]'s segments as parts of day [legNumber].
Iterable<RouteGeometrySourcePart> _sourceParts(
  TrackBundle bundle, {
  required int legNumber,
}) => bundle.segments.map(
  (segment) => RouteGeometrySourcePart(
    legNumber: legNumber,
    segment: segment.segment,
    points: segment.points,
  ),
);

/// Loads [tripId] for the map in [view] when the Trip has it, else in its
/// first view: reviewed when a day has a review, else cleaned when
/// [tracking] can derive that, else as recorded. The reviewed view draws
/// days without a review as recorded.
Future<RouteMapContent> loadTripMap(
  MultiDayTripController tracking,
  String tripId, {
  required RouteGeometryContinuity continuity,
  RouteView? view,
}) async {
  final bundle = await tracking.loadTripBundle(tripId);
  // Reading the days' stops first also reviews each day that completed
  // under older rules.
  final stops = tracking is TrackingStopController
      ? await (tracking as TrackingStopController).listTripStops(tripId)
      : const <TrackStop>[];
  final geometry = tracking is TrackingGeometryController
      ? tracking as TrackingGeometryController
      : null;
  final summaries = tracking is TrackingSummaryController
      ? tracking as TrackingSummaryController
      : null;
  final reviews = <String, DerivedGeometryRun>{
    if (geometry != null)
      for (final leg in bundle.legs)
        leg.trackId: ?await reviewRunOf(geometry, leg.trackId),
  };
  final views = <RouteView>[
    if (reviews.isNotEmpty) RouteView.reviewed,
    if (_canClean(tracking)) RouteView.cleaned,
    RouteView.raw,
  ];
  final shown = views.contains(view) ? view! : views.first;
  final RouteGeometryReport report;
  var shownStops = stops;
  if (shown == RouteView.reviewed) {
    final parts = <RouteGeometrySourcePart>[];
    final reviewedStops = <TrackStop>[];
    for (final leg in bundle.legs) {
      final review = reviews[leg.trackId];
      final day = await geometry!.loadTrackGeometry(
        leg.trackId,
        geometry: review == null
            ? const TrackGeometrySelection.raw()
            : TrackGeometrySelection.derived(review.id),
      );
      parts.addAll(_sourceParts(day, legNumber: leg.legNumber));
      reviewedStops.addAll(day.stops);
    }
    // As in [loadTrackMap], parts join by the stored gaps only.
    report = const RouteGeometryAssembler().assemble(
      sourceParts: parts,
      gaps: bundle.gaps,
      continuity: continuity,
    );
    shownStops = reviewedStops;
  } else {
    report = await tracking.assembleTripRouteGeometry(
      tripId,
      continuity: continuity,
    );
  }
  final cleaned = shown == RouteView.cleaned
      ? await cleanedCoordinates(geometry!, summaries!, report)
      : null;
  return RouteMapContent(
    view: shown,
    views: views,
    route: RouteGeometry.fromReport(
      report,
      gaps: bundle.gaps,
      cleaned: cleaned,
      stops: shownStops,
      // Read after cleaning, which stores the cleaned distances.
      totals: summaries == null
          ? null
          : RouteTotals.ofTrip(await summaries.tripSummary(tripId)),
    ),
  );
}

/// Cleaned positions for every point of [report], by point ID, from each
/// track's current cleaned view ([TrackingSummaryController.currentCleanedGeometry]).
/// The recorded points never change.
Future<Map<String, maplibre.LatLng>> cleanedCoordinates(
  TrackingGeometryController geometry,
  TrackingSummaryController summaries,
  RouteGeometryReport report,
) async {
  final trackIds = <String>{
    for (final part in report.parts)
      for (final point in part.points) point.trackId,
  };
  final cleaned = <String, maplibre.LatLng>{};
  for (final trackId in trackIds) {
    final current = await summaries.currentCleanedGeometry(trackId);
    final bundle = await geometry.loadTrackGeometry(
      trackId,
      geometry: TrackGeometrySelection.derived(current.id),
    );
    for (final segment in bundle.segments) {
      for (final point in segment.points) {
        cleaned[point.id] = maplibre.LatLng(point.latitude, point.longitude);
      }
    }
  }
  return cleaned;
}

/// A muted basemap, so the route and its markers stand out.
const _basemapStyle = 'https://tiles.openfreemap.org/styles/positron';

/// Marker and line colours, shared by the map and its legend.
abstract final class _RouteColors {
  static const route = Color(0xFF00796B);
  static const start = Color(0xFF2E7D32);
  static const end = Color(0xFFC62828);
  static const stop = Color(0xFF1565C0);
  static const gap = Color(0xFFF57C00);
  static const uncertain = Color(0xFFF9A825);

  static String hex(Color color) =>
      '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
}

/// Draws a route's map; tests replace the MapLibre platform view.
typedef RouteMapBuilder =
    Widget Function(
      Key key,
      RouteGeometry route,
      bool showDiagnostics,
      EdgeInsets fitPadding,
    );

Widget _mapLibreMap(
  Key key,
  RouteGeometry route,
  bool showDiagnostics,
  EdgeInsets fitPadding,
) => TrackRouteMap(
  key: key,
  route: route,
  showDiagnostics: showDiagnostics,
  fitPadding: fitPadding,
);

class _RouteMapScaffold extends StatefulWidget {
  const _RouteMapScaffold({
    required this.title,
    required this.showDiagnostics,
    required this.continuity,
    required this.content,
    required this.loading,
    required this.error,
    required this.ready,
    required this.onContinuityChanged,
    required this.onViewChanged,
    required this.onRetry,
    required this.onShowRecorded,
    required this.onShowReady,
    this.mapBuilder = _mapLibreMap,
  });

  final String title;
  final bool showDiagnostics;
  final RouteGeometryContinuity continuity;

  /// The route drawn; while [loading], the previous one stays.
  final RouteMapContent? content;
  final bool loading;
  final Object? error;

  /// Whether details being prepared were stored since [content] loaded.
  final bool ready;
  final ValueChanged<RouteGeometryContinuity> onContinuityChanged;
  final ValueChanged<RouteView> onViewChanged;
  final VoidCallback onRetry;
  final VoidCallback onShowRecorded;
  final VoidCallback onShowReady;
  final RouteMapBuilder mapBuilder;

  @override
  State<_RouteMapScaffold> createState() => _RouteMapScaffoldState();
}

class _RouteMapScaffoldState extends State<_RouteMapScaffold> {
  final GlobalKey<TrackRouteMapState> _map = GlobalKey<TrackRouteMapState>();
  final DraggableScrollableController _sheet = DraggableScrollableController();

  /// How much of the body the expanded sheet covers.
  static const _expandedSize = 0.75;

  @override
  void dispose() {
    _sheet.dispose();
    super.dispose();
  }

  /// The collapsed sheet's height: its handle and the stats row.
  double _peekPixels(BuildContext context, RouteMapContent content) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final hasNote = routeStats(
      content.route.totals,
      cleaned: content.view == RouteView.cleaned,
    ).any((stat) => stat.note != null);
    return RouteMapHeader.handleHeight +
        scale * (hasNote ? 76 : 58) +
        20 +
        MediaQuery.paddingOf(context).bottom;
  }

  /// Moves the sheet with a drag on its header, in [bodyHeight] pixels.
  void _dragSheet(DragUpdateDetails details, double bodyHeight, double peek) {
    if (!_sheet.isAttached) return;
    _sheet.jumpTo(
      (_sheet.size - details.primaryDelta! / bodyHeight).clamp(
        peek,
        _expandedSize,
      ),
    );
  }

  /// Settles the sheet at the peek or expanded, by the fling or the
  /// nearer one.
  void _settleSheet(DragEndDetails details, double peek) {
    if (!_sheet.isAttached) return;
    final velocity = details.primaryVelocity ?? 0;
    final target = velocity < -300
        ? _expandedSize
        : velocity > 300
        ? peek
        : (_sheet.size - peek < _expandedSize - _sheet.size
              ? peek
              : _expandedSize);
    unawaited(
      _sheet.animateTo(
        target,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title, maxLines: 2, softWrap: true),
      titleTextStyle: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      toolbarHeight: 64,
    ),
    body: _body(context),
  );

  Widget _body(BuildContext context) {
    final content = widget.content;
    final error = widget.error;
    if (content == null) {
      if (error != null) {
        return _RouteMapError(
          error: error,
          showDetails: widget.showDiagnostics,
          onRetry: widget.onRetry,
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    final route = content.route;
    // A review that keeps no fix still offers the recorded route.
    if (route.points.isEmpty && content.view != RouteView.reviewed) {
      return const Center(child: Text('No accepted coordinates yet.'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final bodyHeight = constraints.maxHeight;
        final peekPixels = math.min(
          _peekPixels(context, content),
          bodyHeight * 0.4,
        );
        final peek = peekPixels / bodyHeight;
        final banner = _banner(context, content, error);
        return Stack(
          children: <Widget>[
            Positioned.fill(
              child: route.points.isEmpty
                  ? const Center(child: Text('No accepted coordinates yet.'))
                  : widget.mapBuilder(
                      _map,
                      route,
                      widget.showDiagnostics,
                      // The fitted route stays clear of the stats.
                      EdgeInsets.fromLTRB(48, 48, 48, peekPixels + 32),
                    ),
            ),
            if (widget.loading)
              const Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: LinearProgressIndicator(minHeight: 3),
              ),
            if (banner != null)
              Positioned(left: 12, right: 12, top: 12, child: banner),
            if (route.points.isNotEmpty)
              // The buttons ride just above the sheet.
              AnimatedBuilder(
                animation: _sheet,
                builder: (context, child) => Positioned(
                  right: 16,
                  bottom: (_sheet.isAttached ? _sheet.pixels : peekPixels) + 16,
                  child: child!,
                ),
                child: _MapButtons(
                  showDiagnostics: widget.showDiagnostics,
                  continuity: widget.continuity,
                  onContinuityChanged: widget.onContinuityChanged,
                  onFitRoute: () => _map.currentState?.fitRoute(),
                ),
              ),
            DraggableScrollableSheet(
              controller: _sheet,
              initialChildSize: peek,
              minChildSize: peek,
              maxChildSize: _expandedSize,
              snap: true,
              builder: (context, scrollController) => Material(
                elevation: 8,
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                clipBehavior: Clip.antiAlias,
                child: RouteMapHeader(
                  content: content,
                  showDiagnostics: widget.showDiagnostics,
                  continuity: widget.continuity,
                  onContinuityChanged: widget.onContinuityChanged,
                  onViewChanged: widget.onViewChanged,
                  onStopSelected: (stop) =>
                      _map.currentState?.focus(stop.coordinate),
                  sheet: RouteMapSheetLayout(
                    scrollController: scrollController,
                    expandedHeight: bodyHeight * _expandedSize,
                    onDragUpdate: (details) =>
                        _dragSheet(details, bodyHeight, peek),
                    onDragEnd: (details) => _settleSheet(details, peek),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// A note over the map: a failed reload, details being prepared, or
  /// details ready to show.
  Widget? _banner(
    BuildContext context,
    RouteMapContent content,
    Object? error,
  ) {
    if (error != null) {
      return _MapBanner(
        icon: Icons.error_outline,
        text: routeMapErrorMessage(error),
        actions: <Widget>[
          TextButton(onPressed: widget.onRetry, child: const Text('Retry')),
          if (content.view != RouteView.raw)
            TextButton(
              onPressed: widget.onShowRecorded,
              child: const Text('Show recorded'),
            ),
        ],
      );
    }
    if (!content.preparing) return null;
    if (widget.ready) {
      return _MapBanner(
        icon: Icons.check_circle_outline,
        text: 'Route details are ready.',
        actions: <Widget>[
          TextButton(onPressed: widget.onShowReady, child: const Text('Show')),
        ],
      );
    }
    return _MapBanner(
      icon: Icons.hourglass_top_rounded,
      text: content.view == RouteView.cleaned
          ? 'Preparing the cleaned view; showing the route as recorded.'
          : 'Preparing route details.',
    );
  }
}

/// A short note floating over the map.
class _MapBanner extends StatelessWidget {
  const _MapBanner({
    required this.icon,
    required this.text,
    this.actions = const <Widget>[],
  });

  final IconData icon;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Material(
    elevation: 3,
    borderRadius: BorderRadius.circular(14),
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
          ...actions,
        ],
      ),
    ),
  );
}

/// What went wrong opening a route, in a sentence: from the package's
/// stable error codes, never the raw exception text.
String routeMapErrorMessage(Object error) => switch (error) {
  TrackingOwnershipException() =>
    "This route isn't available for the current account.",
  TrackingStorageException() =>
    "The route database couldn't be read. Try again.",
  TrackingException() => "The route couldn't be opened. Try again.",
  _ => "The route couldn't be opened. Try again.",
};

/// The page when a route could not be opened at all.
class _RouteMapError extends StatelessWidget {
  const _RouteMapError({
    required this.error,
    required this.showDetails,
    required this.onRetry,
  });

  final Object error;

  /// Whether to show the error's stable code, for diagnostics.
  final bool showDetails;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = error is TrackingException
        ? (error as TrackingException).code
        : error.runtimeType.toString();
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.map_outlined, size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(
              "Couldn't open this route",
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              routeMapErrorMessage(error),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (showDetails) ...<Widget>[
              const SizedBox(height: 6),
              Text(code, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// The map's floating buttons, above the panel: continuity, with
/// diagnostics, and fitting the route again.
class _MapButtons extends StatelessWidget {
  const _MapButtons({
    required this.showDiagnostics,
    required this.continuity,
    required this.onContinuityChanged,
    required this.onFitRoute,
  });

  final bool showDiagnostics;
  final RouteGeometryContinuity continuity;
  final ValueChanged<RouteGeometryContinuity> onContinuityChanged;
  final VoidCallback onFitRoute;

  /// Opens the continuity choices beside the button in [context].
  Future<void> _pickContinuity(BuildContext context) async {
    final button = context.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final picked = await showMenu<RouteGeometryContinuity>(
      context: context,
      initialValue: continuity,
      position: RelativeRect.fromRect(
        Rect.fromPoints(
          button.localToGlobal(Offset.zero, ancestor: overlay),
          button.localToGlobal(
            button.size.bottomRight(Offset.zero),
            ancestor: overlay,
          ),
        ),
        Offset.zero & overlay.size,
      ),
      items: const <PopupMenuEntry<RouteGeometryContinuity>>[
        PopupMenuItem(
          value: RouteGeometryContinuity.preserveEvidenceSegments,
          child: Text('Keep parts separate'),
        ),
        PopupMenuItem(
          value: RouteGeometryContinuity.connectDailyLegs,
          child: Text('Connect days'),
        ),
        PopupMenuItem(
          value: RouteGeometryContinuity.connectAllChronologicalPoints,
          child: Text('Connect all'),
        ),
      ],
    );
    if (picked != null && picked != continuity) onContinuityChanged(picked);
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      if (showDiagnostics) ...<Widget>[
        Builder(
          builder: (context) => FloatingActionButton.small(
            heroTag: null,
            tooltip: 'Route continuity',
            onPressed: () => _pickContinuity(context),
            child: const Icon(Icons.layers_outlined),
          ),
        ),
        const SizedBox(height: 12),
      ],
      FloatingActionButton.small(
        heroTag: null,
        tooltip: 'Fit route',
        onPressed: onFitRoute,
        child: const Icon(Icons.fit_screen_outlined),
      ),
    ],
  );
}

/// How [RouteMapHeader] sits in a draggable sheet: the sheet's
/// [scrollController], which only the stop list uses, the sheet's
/// [expandedHeight], and the drags on the header that move the sheet.
final class RouteMapSheetLayout {
  const RouteMapSheetLayout({
    required this.scrollController,
    required this.expandedHeight,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final ScrollController scrollController;
  final double expandedHeight;
  final GestureDragUpdateCallback onDragUpdate;
  final GestureDragEndCallback onDragEnd;
}

/// The route details in the map's bottom sheet: the route database's
/// totals first, then the route's views, the legend and the route's stops.
/// Only the stop list scrolls.
class RouteMapHeader extends StatelessWidget {
  const RouteMapHeader({
    super.key,
    required this.content,
    required this.continuity,
    required this.onContinuityChanged,
    required this.onViewChanged,
    this.showDiagnostics = true,
    this.onStopSelected,
    this.sheet,
  });

  /// The drag handle's height above the stats.
  static const handleHeight = 24.0;

  final RouteMapContent content;

  /// Whether the sheet offers views and shows the route's point, part,
  /// quality event and visible gap counts and its continuity.
  final bool showDiagnostics;
  final RouteGeometryContinuity continuity;

  /// Kept for callers; the map's floating button offers continuity.
  final ValueChanged<RouteGeometryContinuity> onContinuityChanged;
  final ValueChanged<RouteView> onViewChanged;

  /// Shows a stop of the list on the map.
  final ValueChanged<RouteStopMarker>? onStopSelected;

  /// The draggable sheet holding the header; null lays it out on its own.
  final RouteMapSheetLayout? sheet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final route = content.route;
    final stats = routeStats(
      route.totals,
      cleaned: content.view == RouteView.cleaned,
    );
    final stops = route.stopMarkers;
    final details = <Widget>[
      if (stats.isNotEmpty)
        StatGrid(
          columns: math.max(3, stats.length),
          children: <Widget>[
            // The distance comes first: the main figure.
            for (final (index, stat) in stats.indexed)
              StatTile(
                value: stat.value,
                label: stat.label,
                note: stat.note,
                large: index == 0,
              ),
          ],
        ),
      if (showDiagnostics && content.views.length > 1)
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: SegmentedButton<RouteView>(
            showSelectedIcon: false,
            segments: <ButtonSegment<RouteView>>[
              for (final view in content.views)
                ButtonSegment(
                  value: view,
                  label: Text(view.label),
                  tooltip: view.description,
                ),
            ],
            selected: <RouteView>{content.view},
            onSelectionChanged: (selection) => onViewChanged(selection.first),
          ),
        ),
      const SizedBox(height: 16),
      _RouteLegend(showDiagnostics: showDiagnostics),
      const SizedBox(height: 10),
      Text(
        routeHeadline(route, showDiagnostics: showDiagnostics),
        style: muted,
      ),
      if (showDiagnostics)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(switch (continuity) {
            RouteGeometryContinuity.preserveEvidenceSegments =>
              'Recorded daily and lifecycle parts stay separate.',
            RouteGeometryContinuity.connectDailyLegs =>
              'Only daily boundaries receive straight inferred connectors.',
            RouteGeometryContinuity.connectAllChronologicalPoints =>
              'All parts receive straight inferred connectors; inferred distance is excluded.',
            RouteGeometryContinuity.mergeAutomaticCallbackGaps =>
              'Only proven automatic callback gaps are joined.',
          }, style: muted),
        ),
      if (stops.isNotEmpty) ...const <Widget>[
        SizedBox(height: 20),
        SectionLabel('Stops'),
      ],
    ];
    Widget stopList({ScrollController? controller, bool shrinkWrap = false}) =>
        ListView.builder(
          controller: controller,
          shrinkWrap: shrinkWrap,
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            12 + MediaQuery.paddingOf(context).bottom,
          ),
          itemCount: stops.length,
          itemBuilder: (context, index) =>
              _stopTile(context, index, stops[index]),
        );
    final layout = sheet;
    if (layout == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: details,
            ),
          ),
          if (stops.isNotEmpty)
            // The one part that scrolls.
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.4,
              ),
              child: stopList(shrinkWrap: true),
            ),
        ],
      );
    }
    // The sheet reveals this expanded layout from the top as it opens: the
    // stats first. Dragging the header moves the sheet; the stop list
    // takes the sheet's scrolling, so it opens the sheet before it scrolls.
    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.topCenter,
        minHeight: layout.expandedHeight,
        maxHeight: layout.expandedHeight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: layout.onDragUpdate,
              onVerticalDragEnd: layout.onDragEnd,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(
                      height: handleHeight,
                      child: Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: colors.outlineVariant,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ),
                    ...details,
                  ],
                ),
              ),
            ),
            Expanded(child: stopList(controller: layout.scrollController)),
          ],
        ),
      ),
    );
  }

  Widget _stopTile(BuildContext context, int index, RouteStopMarker stop) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        leading: CircleAvatar(
          radius: 14,
          backgroundColor: _RouteColors.stop,
          foregroundColor: Colors.white,
          child: Text('${index + 1}', style: const TextStyle(fontSize: 12)),
        ),
        title: Text(
          stopDurationLabel(stop.duration),
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              stop.current
                  ? 'since ${clockTime(stop.startedAt)}'
                  : '${clockTime(stop.startedAt)}–${clockTime(stop.endedAt)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (onStopSelected != null) ...<Widget>[
              const SizedBox(width: 8),
              Icon(
                Icons.my_location_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
            ],
          ],
        ),
        onTap: onStopSelected == null ? null : () => onStopSelected!(stop),
      );
}

/// The map panel's counts line: the route database's count of stops and,
/// with [showDiagnostics], what is drawn and its counts of quality events
/// and visible gaps.
String routeHeadline(RouteGeometry route, {bool showDiagnostics = true}) =>
    <String>[
      if (showDiagnostics) '${route.pointCount} points',
      '${route.totals?.stopCount ?? route.stopMarkers.length} stop(s)',
      if (showDiagnostics) '${route.geometryPartCount} drawable part(s)',
      if (route.totals case final totals? when showDiagnostics) ...<String>[
        '${totals.qualityEventCount} quality event(s)',
        '${totals.visibleGapCount} visible gap(s)',
      ],
    ].join(' • ');

/// One figure of the map panel: [value] over [label], with a [note].
@immutable
final class RouteStat {
  const RouteStat(this.value, this.label, {this.note});

  final String value;
  final String label;
  final String? note;

  @override
  bool operator ==(Object other) =>
      other is RouteStat &&
      other.value == value &&
      other.label == label &&
      other.note == note;

  @override
  int get hashCode => Object.hash(value, label, note);

  @override
  String toString() =>
      'RouteStat($value, $label${note == null ? '' : ', $note'})';
}

/// The map panel's figures, from the route database. The distance comes
/// first: the corrected one once the route was reviewed, noting the
/// measured one ("recorded …") when the two differ as shown, and the
/// cleaned one in the [cleaned] view. Steps are a lower bound ("≥ …") once
/// the counter stopped.
List<RouteStat> routeStats(RouteTotals? totals, {required bool cleaned}) {
  if (totals == null) return const <RouteStat>[];
  final cleanedMeters = totals.cleanedDistanceMeters;
  final corrected = totals.correctedDistanceMeters;
  final recorded = kilometres(totals.distanceMeters);
  final notes = <String>[
    if (corrected != null && kilometres(corrected) != recorded)
      'recorded $recorded',
    if (cleaned && cleanedMeters != null)
      'cleaned ≈ ${kilometres(cleanedMeters)}',
  ];
  return <RouteStat>[
    RouteStat(
      kilometres(totals.displayDistanceMeters),
      'Distance',
      note: notes.isEmpty ? null : notes.join(' · '),
    ),
    RouteStat(hoursMinutes(totals.moving), 'Moving'),
    RouteStat(hoursMinutes(totals.stopped), 'Stopped'),
    if (totals.stepCount case final steps?)
      totals.stepCountStoppedAt == null
          ? RouteStat('$steps', 'Steps')
          : RouteStat(
              '≥ $steps',
              'Steps',
              note:
                  'counter stopped at ${clockTime(totals.stepCountStoppedAt!)}',
            ),
  ];
}

class TrackRouteMap extends StatefulWidget {
  const TrackRouteMap({
    super.key,
    required this.route,
    this.showDiagnostics = true,
    this.fitPadding = const EdgeInsets.all(48),
  });

  final RouteGeometry route;

  /// Whether gaps and uncertain stretches are drawn.
  final bool showDiagnostics;

  /// Space the fitted route keeps from each edge, for UI over the map.
  final EdgeInsets fitPadding;

  @override
  State<TrackRouteMap> createState() => TrackRouteMapState();
}

/// Draws the route with three GeoJSON sources and five style layers: a
/// handful of platform calls however long the route or many its stops, and
/// one update of the sources when the route changes.
class TrackRouteMapState extends State<TrackRouteMap> {
  maplibre.MapLibreMapController? _controller;
  bool _styleLoaded = false;

  /// Whether this style has the route's sources and layers.
  bool _layersAdded = false;

  /// Bumped per draw; a draw that finds it moved on stops.
  int _drawGeneration = 0;

  static const _routeSource = 'route';
  static const _uncertainSource = 'route-uncertain';
  static const _markerSource = 'route-markers';

  /// Stop labels in a source of their own: a label the style can't draw
  /// (a missing font fails its source's tiles) never hides a marker.
  static const _labelSource = 'route-stop-labels';

  /// The one font the basemap style serves glyphs for.
  static const _labelFont = 'Noto Sans Regular';

  @override
  void dispose() {
    _drawGeneration += 1;
    _controller?.onFeatureTapped.remove(_onFeatureTapped);
    super.dispose();
  }

  @override
  void didUpdateWidget(TrackRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.route, widget.route) ||
        oldWidget.showDiagnostics != widget.showDiagnostics) {
      unawaited(_drawRoute(fit: !identical(oldWidget.route, widget.route)));
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => maplibre.MapLibreMap(
      styleString: _basemapStyle,
      compassViewPosition: maplibre.CompassViewPosition.bottomRight,
      // The route's own sources and layers: no annotation managers.
      annotationOrder: const <maplibre.AnnotationType>[],
      initialCameraPosition: initialRouteCamera(
        widget.route,
        constraints.biggest,
        widget.fitPadding,
      ),
      onMapCreated: (controller) {
        _controller = controller;
        controller.onFeatureTapped.add(_onFeatureTapped);
      },
      onStyleLoadedCallback: () {
        _styleLoaded = true;
        // A new style starts without the route's layers.
        _layersAdded = false;
        unawaited(_drawRoute(fit: true));
      },
    ),
  );

  /// Moves the camera so the whole route shows.
  Future<void> fitRoute() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.animateCamera(_routeCameraUpdate());
  }

  /// Moves the camera close to [coordinate], such as a stop.
  Future<void> focus(maplibre.LatLng coordinate) async {
    await _controller?.animateCamera(
      maplibre.CameraUpdate.newLatLngZoom(coordinate, 17),
    );
  }

  maplibre.CameraUpdate _routeCameraUpdate() {
    if (widget.route.points.length == 1) {
      return maplibre.CameraUpdate.newLatLngZoom(widget.route.start, 16);
    }
    final padding = widget.fitPadding;
    return maplibre.CameraUpdate.newLatLngBounds(
      widget.route.bounds,
      left: padding.left,
      top: padding.top,
      right: padding.right,
      bottom: padding.bottom,
    );
  }

  Future<void> _drawRoute({required bool fit}) async {
    final controller = _controller;
    if (controller == null || !_styleLoaded) return;
    final generation = ++_drawGeneration;
    bool stale() =>
        !mounted || controller.isDisposed || generation != _drawGeneration;
    final route = widget.route;
    final lines = routeFeatureCollection(route.segments);
    final uncertain = routeFeatureCollection(
      widget.showDiagnostics
          ? route.uncertainSegments
          : const <List<maplibre.LatLng>>[],
    );
    final markers = markerFeatureCollection(
      route,
      showDiagnostics: widget.showDiagnostics,
    );
    final labels = stopLabelFeatureCollection(route);
    if (!_layersAdded) {
      _layersAdded = true;
      await controller.addGeoJsonSource(_routeSource, lines);
      if (stale()) return;
      await controller.addGeoJsonSource(_uncertainSource, uncertain);
      if (stale()) return;
      await controller.addGeoJsonSource(_markerSource, markers);
      if (stale()) return;
      await controller.addGeoJsonSource(_labelSource, labels);
      if (stale()) return;
      // A white casing under the route keeps it legible on any basemap.
      await controller.addLineLayer(
        _routeSource,
        'route-casing',
        const maplibre.LineLayerProperties(
          lineColor: '#FFFFFF',
          lineWidth: 9,
          lineOpacity: 0.95,
          lineJoin: 'round',
          lineCap: 'round',
        ),
        enableInteraction: false,
      );
      if (stale()) return;
      await controller.addLineLayer(
        _routeSource,
        'route-line',
        maplibre.LineLayerProperties(
          lineColor: _RouteColors.hex(_RouteColors.route),
          lineWidth: 5,
          lineOpacity: 0.95,
          lineJoin: 'round',
          lineCap: 'round',
        ),
        enableInteraction: false,
      );
      if (stale()) return;
      // Stretches whose fixes zig-zag inside their own uncertainty: the
      // route went somewhere here, but the positions can't say exactly
      // where.
      await controller.addLineLayer(
        _uncertainSource,
        'route-uncertain-line',
        maplibre.LineLayerProperties(
          lineColor: _RouteColors.hex(_RouteColors.uncertain),
          lineWidth: 4,
          lineOpacity: 0.9,
          lineJoin: 'round',
          lineCap: 'round',
        ),
        enableInteraction: false,
      );
      if (stale()) return;
      // Gaps and stops, then the start and end above them.
      await controller.addCircleLayer(
        _markerSource,
        'route-markers',
        _markerCircles,
        filter: const <Object>[
          'in',
          <Object>['get', 'kind'],
          <Object>[
            'literal',
            <String>['gap', 'stop'],
          ],
        ],
      );
      if (stale()) return;
      await controller.addCircleLayer(
        _markerSource,
        'route-endpoints',
        _markerCircles,
        filter: const <Object>[
          'in',
          <Object>['get', 'kind'],
          <Object>[
            'literal',
            <String>['start', 'end'],
          ],
        ],
        enableInteraction: false,
      );
      if (stale()) return;
      try {
        await controller.addSymbolLayer(
          _labelSource,
          'route-stop-labels',
          const maplibre.SymbolLayerProperties(
            textField: <Object>['get', 'label'],
            textFont: <Object>[
              'literal',
              <String>[_labelFont],
            ],
            textSize: 12,
            textOffset: <Object>[
              'literal',
              <double>[0, 1.4],
            ],
            textColor: '#0D47A1',
            textHaloColor: '#FFFFFF',
            textHaloWidth: 1.5,
            textAllowOverlap: false,
          ),
          enableInteraction: false,
        );
      } on Object {
        // A style without glyphs still shows the stop markers.
      }
    } else {
      await controller.setGeoJsonSource(_routeSource, lines);
      if (stale()) return;
      await controller.setGeoJsonSource(_uncertainSource, uncertain);
      if (stale()) return;
      await controller.setGeoJsonSource(_markerSource, markers);
      if (stale()) return;
      await controller.setGeoJsonSource(_labelSource, labels);
    }
    if (stale() || !fit) return;
    // Jump, not fly: the first camera was already close to this.
    await controller.moveCamera(_routeCameraUpdate());
  }

  /// A marker circle styled from its feature: green start, red end, blue
  /// stops, orange gaps.
  static const _markerCircles = maplibre.CircleLayerProperties(
    circleColor: <Object>['get', 'color'],
    circleRadius: <Object>['get', 'radius'],
    circleStrokeColor: '#FFFFFF',
    circleStrokeWidth: <Object>['get', 'stroke'],
  );

  void _onFeatureTapped(
    math.Point<double> point,
    maplibre.LatLng coordinates,
    String id,
    String layerId,
    maplibre.Annotation? annotation,
  ) {
    if (!mounted || !id.startsWith(_stopIdPrefix)) return;
    final index = int.tryParse(id.substring(_stopIdPrefix.length));
    final stops = widget.route.stopMarkers;
    if (index == null || index < 0 || index >= stops.length) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(describeStop(stops[index]))));
  }
}

/// Feature IDs of stop markers: this prefix and the stop's index.
const _stopIdPrefix = 'stop-';

/// [lines] as a GeoJSON FeatureCollection of LineStrings, `[lng, lat]`.
Map<String, dynamic> routeFeatureCollection(
  Iterable<List<maplibre.LatLng>> lines,
) => <String, dynamic>{
  'type': 'FeatureCollection',
  'features': <Map<String, dynamic>>[
    for (final line in lines)
      if (line.length >= 2)
        <String, dynamic>{
          'type': 'Feature',
          'properties': const <String, dynamic>{},
          'geometry': <String, dynamic>{
            'type': 'LineString',
            'coordinates': <List<double>>[
              for (final point in line)
                <double>[point.longitude, point.latitude],
            ],
          },
        },
  ],
};

/// [route]'s markers as GeoJSON points: gaps with [showDiagnostics], each
/// stop with its duration label, then the start and the end on top.
Map<String, dynamic> markerFeatureCollection(
  RouteGeometry route, {
  required bool showDiagnostics,
}) {
  Map<String, dynamic> marker(
    String id,
    String kind,
    maplibre.LatLng at, {
    required Color color,
    required double radius,
    double stroke = 3,
    String? label,
  }) => <String, dynamic>{
    'type': 'Feature',
    'id': id,
    'properties': <String, dynamic>{
      'kind': kind,
      'color': _RouteColors.hex(color),
      'radius': radius,
      'stroke': stroke,
      'label': ?label,
    },
    'geometry': <String, dynamic>{
      'type': 'Point',
      'coordinates': <double>[at.longitude, at.latitude],
    },
  };
  final distinct = route.hasDistinctEndpoints;
  return <String, dynamic>{
    'type': 'FeatureCollection',
    'features': <Map<String, dynamic>>[
      if (showDiagnostics)
        for (final (index, gap) in route.gapMarkers.indexed)
          marker(
            'gap-$index',
            'gap',
            gap,
            color: _RouteColors.gap,
            radius: 6,
            stroke: 2,
          ),
      for (final (index, stop) in route.stopMarkers.indexed)
        marker(
          '$_stopIdPrefix$index',
          'stop',
          stop.coordinate,
          color: _RouteColors.stop,
          radius: 7,
          stroke: 2,
          label: stopDurationLabel(stop.duration),
        ),
      if (route.points.isNotEmpty) ...<Map<String, dynamic>>[
        marker(
          'start',
          'start',
          route.start,
          color: _RouteColors.start,
          radius: distinct ? 8 : 10,
        ),
        // A single-point route draws its end inside its start.
        marker(
          'end',
          'end',
          route.destination,
          color: _RouteColors.end,
          radius: distinct ? 8 : 5,
          stroke: distinct ? 3 : 1,
        ),
      ],
    ],
  };
}

/// [route]'s stop labels as GeoJSON points: each stop's duration, drawn
/// below its marker.
Map<String, dynamic> stopLabelFeatureCollection(RouteGeometry route) =>
    <String, dynamic>{
      'type': 'FeatureCollection',
      'features': <Map<String, dynamic>>[
        for (final (index, stop) in route.stopMarkers.indexed)
          <String, dynamic>{
            'type': 'Feature',
            'id': 'label-$index',
            'properties': <String, dynamic>{
              'label': stopDurationLabel(stop.duration),
            },
            'geometry': <String, dynamic>{
              'type': 'Point',
              'coordinates': <double>[
                stop.coordinate.longitude,
                stop.coordinate.latitude,
              ],
            },
          },
      ],
    };

/// A first camera close to the fitted route, so the map opens on it
/// without a fit animation: the route's [RouteGeometry.bounds] in [size]
/// less [padding], in MapLibre's 512-point tiles.
maplibre.CameraPosition initialRouteCamera(
  RouteGeometry route,
  Size size,
  EdgeInsets padding,
) {
  if (route.points.length <= 1 || !size.isFinite) {
    return maplibre.CameraPosition(
      target: route.center,
      zoom: route.points.length <= 1 ? 15 : 13,
    );
  }
  final bounds = route.bounds;
  final width = math.max(1.0, size.width - padding.horizontal);
  final height = math.max(1.0, size.height - padding.vertical);
  double mercator(double latitude) {
    final radians = latitude * math.pi / 180;
    return math.log(math.tan(math.pi / 4 + radians / 2));
  }

  final spanLongitude =
      (bounds.northeast.longitude - bounds.southwest.longitude).abs();
  final spanMercator =
      (mercator(bounds.northeast.latitude) -
              mercator(bounds.southwest.latitude))
          .abs();
  double log2(double value) => math.log(value) / math.ln2;
  final zoomX = log2(width * 360 / (512 * math.max(spanLongitude, 1e-9)));
  final zoomY = log2(
    height * 2 * math.pi / (512 * math.max(spanMercator, 1e-12)),
  );
  return maplibre.CameraPosition(
    target: route.center,
    zoom: math.min(zoomX, zoomY).clamp(2.0, 17.0),
  );
}

/// How long a stop lasted, as drawn beside its marker.
String stopDurationLabel(Duration duration) => duration.inMinutes >= 60
    ? '${duration.inHours} h ${duration.inMinutes % 60} min'
    : '${math.max(1, duration.inMinutes)} min';

/// What a tap on a stop shows: how long it lasted and when, in local time.
String describeStop(RouteStopMarker stop) {
  final length = stopDurationLabel(stop.duration);
  return stop.current
      ? 'Stopped $length so far, since ${clockTime(stop.startedAt)}'
      : 'Stopped $length, '
            '${clockTime(stop.startedAt)}–${clockTime(stop.endedAt)}';
}

/// What the map's markers and lines mean.
class _RouteLegend extends StatelessWidget {
  const _RouteLegend({required this.showDiagnostics});

  final bool showDiagnostics;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 14,
    runSpacing: 6,
    children: <Widget>[
      const _LegendItem(color: _RouteColors.start, label: 'Start'),
      const _LegendItem(color: _RouteColors.stop, label: 'Stop'),
      const _LegendItem(color: _RouteColors.end, label: 'End'),
      if (showDiagnostics) ...const <Widget>[
        _LegendItem(color: _RouteColors.gap, label: 'Gap'),
        _LegendItem(color: _RouteColors.uncertain, label: 'Uncertain'),
      ],
    ],
  );
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 1.5),
          boxShadow: const <BoxShadow>[
            BoxShadow(color: Colors.black26, blurRadius: 2),
          ],
        ),
      ),
      const SizedBox(width: 5),
      Text(label, style: Theme.of(context).textTheme.labelMedium),
    ],
  );
}

/// A stop drawn as one marker: where it was and how long it lasted.
class RouteStopMarker {
  const RouteStopMarker({
    required this.coordinate,
    required this.startedAt,
    required this.endedAt,
    this.current = false,
  });

  /// A stop as the route database stores it.
  RouteStopMarker.fromStop(TrackStop stop)
    : this(
        coordinate: maplibre.LatLng(stop.latitude, stop.longitude),
        startedAt: stop.startedAt,
        endedAt: stop.endedAt ?? stop.lastSeenAt,
        current: stop.isOpen,
      );

  final maplibre.LatLng coordinate;
  final DateTime startedAt;

  /// When the stay ended, or its newest fix while it is [current].
  final DateTime endedAt;

  /// Whether the stop is still in progress.
  final bool current;

  Duration get duration => endedAt.difference(startedAt);
}

class RouteGeometry {
  const RouteGeometry({
    required this.segments,
    required this.points,
    required this.gapMarkers,
    required this.bounds,
    required this.center,
    required this.pointCount,
    required this.geometryPartCount,
    required this.gapCount,
    required this.inferredConnectorCount,
    this.stopMarkers = const <RouteStopMarker>[],
    this.uncertainSegments = const <List<maplibre.LatLng>>[],
    this.totals,
  });

  final List<List<maplibre.LatLng>> segments;
  final List<maplibre.LatLng> points;

  /// Gaps the route database marks visible, and inferred connectors.
  final List<maplibre.LatLng> gapMarkers;

  /// The route's stops as the route database stores them, one per visit.
  final List<RouteStopMarker> stopMarkers;

  /// Low-confidence stretches drawn over [segments].
  final List<List<maplibre.LatLng>> uncertainSegments;

  /// The route database's totals; null when the facade keeps none.
  final RouteTotals? totals;
  final maplibre.LatLngBounds bounds;
  final maplibre.LatLng center;
  final int pointCount;
  final int geometryPartCount;
  final int gapCount;
  final int inferredConnectorCount;

  maplibre.LatLng get start => points.first;
  maplibre.LatLng get destination => points.last;

  bool get hasDistinctEndpoints =>
      start.latitude != destination.latitude ||
      start.longitude != destination.longitude;

  /// Builds map geometry from [report], drawn at [cleaned] positions when
  /// given. Stops are the stored [stops]; a gap is marked when the route
  /// database marks it visible ([TrackingContinuityGap.isVisible]), so a stop
  /// or pause is never a gap. Uncertain stretches are found only with
  /// [includeUncertainty]: a map without diagnostics doesn't draw them.
  factory RouteGeometry.fromReport(
    RouteGeometryReport report, {
    Iterable<TrackingContinuityGap>? gaps,
    Map<String, maplibre.LatLng>? cleaned,
    Iterable<TrackStop> stops = const <TrackStop>[],
    RouteTotals? totals,
    bool includeUncertainty = true,
  }) {
    final all = <maplibre.LatLng>[];
    final pointCoordinates = <String, maplibre.LatLng>{};
    final segments = <List<maplibre.LatLng>>[];
    final uncertain = <List<maplibre.LatLng>>[];
    for (final part in report.parts) {
      final valid = part.points.where(_valid).toList();
      final coordinates = <maplibre.LatLng>[
        for (final point in valid)
          cleaned?[point.id] ??
              maplibre.LatLng(point.latitude, point.longitude),
      ];
      for (var index = 0; index < valid.length; index += 1) {
        all.add(coordinates[index]);
        pointCoordinates[valid[index].id] = coordinates[index];
      }
      if (coordinates.length >= 2) segments.add(coordinates);
      if (includeUncertainty) {
        uncertain.addAll(_uncertainStretches(valid, coordinates));
      }
    }
    final markers = <maplibre.LatLng>[];
    final representedBoundaries = <String>{};
    for (final gap in gaps ?? report.gaps) {
      if (!gap.isVisible) continue;
      final beforeId = gap.beforePointId;
      final before = beforeId == null ? null : pointCoordinates[beforeId];
      final after = pointCoordinates[gap.afterPointId];
      if (before == null || after == null) continue;
      markers.add(_midpoint(before, after));
      representedBoundaries.add('$beforeId\u0000${gap.afterPointId}');
    }
    for (final connector in report.inferredConnectors) {
      final key = '${connector.beforePointId}\u0000${connector.afterPointId}';
      if (representedBoundaries.contains(key)) continue;
      final before = pointCoordinates[connector.beforePointId];
      final after = pointCoordinates[connector.afterPointId];
      if (before != null && after != null) {
        markers.add(_midpoint(before, after));
      }
    }
    return _create(
      segments: segments,
      points: all,
      gapMarkers: markers,
      geometryPartCount: report.geometryPartCount,
      gapCount: report.gapCount,
      inferredConnectorCount: report.inferredConnectorCount,
      stopMarkers: <RouteStopMarker>[
        for (final stop in stops) RouteStopMarker.fromStop(stop),
      ]..sort((a, b) => a.startedAt.compareTo(b.startedAt)),
      uncertainSegments: uncertain,
      totals: totals,
    );
  }

  /// Stretches of five or more fixes, at least 30 s long, that zig-zag
  /// inside their own uncertainty: little net progress for the path drawn.
  static List<List<maplibre.LatLng>> _uncertainStretches(
    List<TrackPoint> points,
    List<maplibre.LatLng> coordinates,
  ) {
    const window = 5;
    final flagged = List<bool>.filled(points.length, false);
    final sigmas = List<double>.filled(window, 0);
    for (var start = 0; start + window <= points.length; start += 1) {
      final first = points[start];
      final last = points[start + window - 1];
      if (last.capturedAt.difference(first.capturedAt) <
          const Duration(seconds: 30)) {
        continue;
      }
      var path = 0.0;
      for (var index = start + 1; index < start + window; index += 1) {
        path += _meters(points[index - 1], points[index]);
      }
      final net = _meters(first, last);
      for (var offset = 0; offset < window; offset += 1) {
        sigmas[offset] = math.max(
          1.5,
          (points[start + offset].horizontalAccuracy ?? 20) / 1.51,
        );
      }
      sigmas.sort();
      final sigma = sigmas[window ~/ 2];
      if (net <= 2 * math.sqrt2 * sigma + 5 && path >= 2 * net + 10) {
        flagged.fillRange(start, start + window, true);
      }
    }
    final stretches = <List<maplibre.LatLng>>[];
    var current = <maplibre.LatLng>[];
    for (var index = 0; index < points.length; index += 1) {
      if (flagged[index]) {
        current.add(coordinates[index]);
      } else if (current.isNotEmpty) {
        if (current.length >= 2) stretches.add(current);
        current = <maplibre.LatLng>[];
      }
    }
    if (current.length >= 2) stretches.add(current);
    return stretches;
  }

  static double _meters(TrackPoint from, TrackPoint to) => _distanceMeters(
    maplibre.LatLng(from.latitude, from.longitude),
    maplibre.LatLng(to.latitude, to.longitude),
  );

  static double _distanceMeters(maplibre.LatLng from, maplibre.LatLng to) {
    const earthRadiusMeters = 6371008.8;
    final phi1 = from.latitude * math.pi / 180;
    final phi2 = to.latitude * math.pi / 180;
    final deltaPhi = phi2 - phi1;
    final deltaLambda = (to.longitude - from.longitude) * math.pi / 180;
    final h =
        math.pow(math.sin(deltaPhi / 2), 2) +
        math.cos(phi1) *
            math.cos(phi2) *
            math.pow(math.sin(deltaLambda / 2), 2);
    return 2 * earthRadiusMeters * math.asin(math.min(1, math.sqrt(h)));
  }

  factory RouteGeometry.fromBundle(TrackBundle bundle) =>
      RouteGeometry.fromReport(
        const RouteGeometryAssembler().assemble(
          sourceParts: _sourceParts(bundle, legNumber: 1),
        ),
      );

  static RouteGeometry _create({
    required List<List<maplibre.LatLng>> segments,
    required List<maplibre.LatLng> points,
    required List<maplibre.LatLng> gapMarkers,
    required int geometryPartCount,
    required int gapCount,
    required int inferredConnectorCount,
    List<RouteStopMarker> stopMarkers = const <RouteStopMarker>[],
    List<List<maplibre.LatLng>> uncertainSegments =
        const <List<maplibre.LatLng>>[],
    RouteTotals? totals,
  }) {
    final bounds = _bounds(points);
    return RouteGeometry(
      segments: segments,
      points: points,
      gapMarkers: gapMarkers,
      bounds: bounds,
      center: maplibre.LatLng(
        (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
        (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
      ),
      pointCount: points.length,
      geometryPartCount: geometryPartCount,
      gapCount: gapCount,
      inferredConnectorCount: inferredConnectorCount,
      stopMarkers: stopMarkers,
      uncertainSegments: uncertainSegments,
      totals: totals,
    );
  }

  static maplibre.LatLng _midpoint(
    maplibre.LatLng before,
    maplibre.LatLng after,
  ) => maplibre.LatLng(
    (before.latitude + after.latitude) / 2,
    (before.longitude + after.longitude) / 2,
  );

  static bool _valid(TrackPoint point) =>
      point.accepted &&
      point.latitude.isFinite &&
      point.longitude.isFinite &&
      point.latitude >= -90 &&
      point.latitude <= 90 &&
      point.longitude >= -180 &&
      point.longitude <= 180;

  static maplibre.LatLngBounds _bounds(List<maplibre.LatLng> points) {
    if (points.isEmpty) {
      const origin = maplibre.LatLng(0, 0);
      return maplibre.LatLngBounds(southwest: origin, northeast: origin);
    }
    var south = points.first.latitude;
    var north = south;
    var west = points.first.longitude;
    var east = west;
    for (final point in points.skip(1)) {
      south = math.min(south, point.latitude);
      north = math.max(north, point.latitude);
      west = math.min(west, point.longitude);
      east = math.max(east, point.longitude);
    }
    if (south == north) {
      south -= 0.0005;
      north += 0.0005;
    }
    if (west == east) {
      west -= 0.0005;
      east += 0.0005;
    }
    return maplibre.LatLngBounds(
      southwest: maplibre.LatLng(south, west),
      northeast: maplibre.LatLng(north, east),
    );
  }
}
