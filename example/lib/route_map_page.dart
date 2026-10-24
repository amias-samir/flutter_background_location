import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as maplibre;

import 'route_totals.dart';

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

  final String label;
  final String description;
}

/// A route as the map page draws it: [route] in [view], one of the [views]
/// the route has, in the order the page offers them.
final class RouteMapContent {
  const RouteMapContent({
    required this.route,
    this.view = RouteView.raw,
    this.views = const <RouteView>[RouteView.raw],
  });

  final RouteGeometry route;
  final RouteView view;
  final List<RouteView> views;
}

class TrackMapPage extends StatefulWidget {
  const TrackMapPage({super.key, required this.tracking, required this.track});

  final Tracking tracking;
  final Track track;

  @override
  State<TrackMapPage> createState() => _TrackMapPageState();
}

class _TrackMapPageState extends State<TrackMapPage> {
  var _continuity = RouteGeometryContinuity.mergeAutomaticCallbackGaps;

  /// The view picked on the page; null draws the route's default view.
  RouteView? _view;

  @override
  Widget build(BuildContext context) => _RouteMapScaffold(
    title: 'Recorded route',
    continuity: _continuity,
    onContinuityChanged: (value) => setState(() => _continuity = value),
    onViewChanged: (value) => setState(() => _view = value),
    future: loadTrackMap(
      widget.tracking,
      widget.track.id,
      continuity: _continuity,
      view: _view,
    ),
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

class TripMapPage extends StatefulWidget {
  const TripMapPage({super.key, required this.tracking, required this.trip});

  final MultiDayTripController tracking;
  final Trip trip;

  @override
  State<TripMapPage> createState() => _TripMapPageState();
}

class _TripMapPageState extends State<TripMapPage> {
  late RouteGeometryContinuity _continuity;

  /// The view picked on the page; null draws the Trip's default view.
  RouteView? _view;

  @override
  void initState() {
    super.initState();
    _continuity = widget.trip.routePresentation.geometryContinuity;
  }

  @override
  Widget build(BuildContext context) => _RouteMapScaffold(
    title: widget.trip.routeId ?? 'Multi-day Trip',
    continuity: _continuity,
    onContinuityChanged: (value) => setState(() => _continuity = value),
    onViewChanged: (value) => setState(() => _view = value),
    future: loadTripMap(
      widget.tracking,
      widget.trip.id,
      continuity: _continuity,
      view: _view,
    ),
  );
}

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

class _RouteMapScaffold extends StatelessWidget {
  const _RouteMapScaffold({
    required this.title,
    required this.continuity,
    required this.onContinuityChanged,
    required this.onViewChanged,
    required this.future,
  });

  final String title;
  final RouteGeometryContinuity continuity;
  final ValueChanged<RouteGeometryContinuity> onContinuityChanged;
  final ValueChanged<RouteView> onViewChanged;
  final Future<RouteMapContent> future;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: FutureBuilder<RouteMapContent>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: SelectableText(snapshot.error.toString()));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final content = snapshot.requireData;
        final route = content.route;
        // A review that keeps no fix still offers the recorded route.
        if (route.points.isEmpty && content.view != RouteView.reviewed) {
          return const Center(child: Text('No accepted coordinates yet.'));
        }
        return Column(
          children: <Widget>[
            RouteMapHeader(
              content: content,
              continuity: continuity,
              onContinuityChanged: onContinuityChanged,
              onViewChanged: onViewChanged,
            ),
            Expanded(
              child: route.points.isEmpty
                  ? const Center(child: Text('No accepted coordinates yet.'))
                  : Stack(
                      children: <Widget>[
                        Positioned.fill(
                          child: TrackRouteMap(
                            key: ValueKey<(RouteGeometryContinuity, RouteView)>(
                              (continuity, content.view),
                            ),
                            route: route,
                          ),
                        ),
                        const Positioned(
                          left: 12,
                          bottom: 12,
                          child: _RouteEndpointLegend(),
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    ),
  );
}

/// The route details above the map: what is drawn, the route's views, and
/// the route database's totals.
class RouteMapHeader extends StatelessWidget {
  const RouteMapHeader({
    super.key,
    required this.content,
    required this.continuity,
    required this.onContinuityChanged,
    required this.onViewChanged,
  });

  final RouteMapContent content;
  final RouteGeometryContinuity continuity;
  final ValueChanged<RouteGeometryContinuity> onContinuityChanged;
  final ValueChanged<RouteView> onViewChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final lines = routeTotalsLines(
      content.route.totals,
      cleaned: content.view == RouteView.cleaned,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: Text(routeHeadline(content.route))),
              const SizedBox(width: 8),
              PopupMenuButton<RouteGeometryContinuity>(
                tooltip: 'Route continuity',
                initialValue: continuity,
                onSelected: onContinuityChanged,
                itemBuilder: (_) =>
                    const <PopupMenuEntry<RouteGeometryContinuity>>[
                      PopupMenuItem(
                        value: RouteGeometryContinuity.preserveEvidenceSegments,
                        child: Text('Keep parts separate'),
                      ),
                      PopupMenuItem(
                        value: RouteGeometryContinuity.connectDailyLegs,
                        child: Text('Connect days'),
                      ),
                      PopupMenuItem(
                        value: RouteGeometryContinuity
                            .connectAllChronologicalPoints,
                        child: Text('Connect all'),
                      ),
                    ],
                icon: const Icon(Icons.alt_route_rounded),
              ),
            ],
          ),
          if (content.views.length > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
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
                onSelectionChanged: (selection) =>
                    onViewChanged(selection.first),
              ),
            ),
          // The distance comes first: the main figure.
          for (final (index, line) in lines.indexed)
            Text(
              line,
              style: index == 0
                  ? text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)
                  : text.bodySmall,
            ),
          Text(switch (continuity) {
            RouteGeometryContinuity.preserveEvidenceSegments =>
              'Recorded daily and lifecycle parts stay separate.',
            RouteGeometryContinuity.connectDailyLegs =>
              'Only daily boundaries receive straight inferred connectors.',
            RouteGeometryContinuity.connectAllChronologicalPoints =>
              'All parts receive straight inferred connectors; inferred distance is excluded.',
            RouteGeometryContinuity.mergeAutomaticCallbackGaps =>
              'Only proven automatic callback gaps are joined.',
          }, style: text.bodySmall),
        ],
      ),
    );
  }
}

/// The map header's first line: what is drawn, and the route database's
/// counts of stops, quality events and visible gaps.
String routeHeadline(RouteGeometry route) => <String>[
  '${route.pointCount} points',
  '${route.totals?.stopCount ?? route.stopMarkers.length} stop(s)',
  '${route.geometryPartCount} drawable part(s)',
  if (route.totals case final totals?) ...<String>[
    '${totals.qualityEventCount} quality event(s)',
    '${totals.visibleGapCount} visible gap(s)',
  ],
].join(' • ');

/// The map header's distance and time lines, from the route database. The
/// distance comes first: the corrected one once the route was reviewed,
/// followed by the measured one ("recorded …") when the two differ as
/// shown. The cleaned distance shows in the [cleaned] view.
List<String> routeTotalsLines(RouteTotals? totals, {required bool cleaned}) {
  if (totals == null) return const <String>[];
  final cleanedMeters = totals.cleanedDistanceMeters;
  final corrected = totals.correctedDistanceMeters;
  final recorded = kilometres(totals.distanceMeters);
  return <String>[
    <String>[
      'Distance ${kilometres(totals.displayDistanceMeters)}',
      if (cleaned && cleanedMeters != null)
        'cleaned ≈ ${kilometres(cleanedMeters)}',
    ].join(' • '),
    if (corrected != null && kilometres(corrected) != recorded)
      'recorded $recorded',
    <String>[
      'Moving ${hoursMinutes(totals.moving)}',
      'stopped ${hoursMinutes(totals.stopped)}',
      ?totals.stepsText,
    ].join(' • '),
  ];
}

class TrackRouteMap extends StatefulWidget {
  const TrackRouteMap({super.key, required this.route});

  final RouteGeometry route;

  @override
  State<TrackRouteMap> createState() => _TrackRouteMapState();
}

class _TrackRouteMapState extends State<TrackRouteMap> {
  maplibre.MapLibreMapController? _controller;
  bool _styleLoaded = false;
  bool _routeDrawn = false;

  @override
  void dispose() {
    _controller?.onCircleTapped.remove(_onCircleTapped);
    _controller?.onSymbolTapped.remove(_onSymbolTapped);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => maplibre.MapLibreMap(
    styleString: maplibre.MapLibreStyles.openfreemapLiberty,
    initialCameraPosition: maplibre.CameraPosition(
      target: widget.route.center,
      zoom: widget.route.points.length == 1 ? 15 : 13,
    ),
    onMapCreated: (controller) {
      _controller = controller;
      controller.onCircleTapped.add(_onCircleTapped);
      controller.onSymbolTapped.add(_onSymbolTapped);
      unawaited(_drawRoute());
    },
    onStyleLoadedCallback: () {
      _styleLoaded = true;
      unawaited(_drawRoute());
    },
  );

  Future<void> _drawRoute() async {
    final controller = _controller;
    if (controller == null || !_styleLoaded || _routeDrawn) return;
    _routeDrawn = true;
    for (final segment in widget.route.segments) {
      await controller.addLine(
        maplibre.LineOptions(
          geometry: segment,
          lineColor: '#00796B',
          lineWidth: 5,
          lineOpacity: 0.9,
        ),
      );
    }
    // Stretches whose fixes zig-zag inside their own uncertainty: the route
    // went somewhere here, but the positions can't say exactly where.
    for (final stretch in widget.route.uncertainSegments) {
      await controller.addLine(
        maplibre.LineOptions(
          geometry: stretch,
          lineColor: '#F9A825',
          lineWidth: 4,
          lineOpacity: 0.9,
        ),
      );
    }
    for (final marker in widget.route.gapMarkers) {
      await _drawCircle(
        controller,
        coordinate: marker,
        color: '#F57C00',
        radius: 6,
        strokeWidth: 2,
      );
    }
    final stops = widget.route.stopMarkers;
    for (var index = 0; index < stops.length; index += 1) {
      final stop = stops[index];
      final data = <String, dynamic>{_stopKey: index};
      await _drawCircle(
        controller,
        coordinate: stop.coordinate,
        color: '#1565C0',
        radius: 7,
        strokeWidth: 2,
        data: data,
      );
      try {
        await controller.addSymbol(
          maplibre.SymbolOptions(
            geometry: stop.coordinate,
            textField: stopDurationLabel(stop.duration),
            textSize: 12,
            textOffset: const Offset(0, 1.4),
            textColor: '#0D47A1',
            textHaloColor: '#FFFFFF',
            textHaloWidth: 1.5,
          ),
          data,
        );
      } on Object {
        // A style without glyphs still shows the stop marker.
      }
    }
    await _drawCircle(
      controller,
      coordinate: widget.route.start,
      color: '#D32F2F',
      radius: widget.route.hasDistinctEndpoints ? 8 : 10,
    );
    await _drawCircle(
      controller,
      coordinate: widget.route.destination,
      color: '#2E7D32',
      radius: widget.route.hasDistinctEndpoints ? 8 : 5,
      strokeWidth: widget.route.hasDistinctEndpoints ? 3 : 1,
    );
    if (widget.route.points.length == 1) return;
    await controller.animateCamera(
      maplibre.CameraUpdate.newLatLngBounds(
        widget.route.bounds,
        left: 48,
        top: 48,
        right: 48,
        bottom: 48,
      ),
    );
  }

  static const _stopKey = 'stop';

  void _onCircleTapped(maplibre.Circle circle) => _showStop(circle.data);

  void _onSymbolTapped(maplibre.Symbol symbol) => _showStop(symbol.data);

  void _showStop(Map<dynamic, dynamic>? data) {
    final index = data?[_stopKey];
    if (!mounted || index is! int) return;
    final stops = widget.route.stopMarkers;
    if (index >= stops.length) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(describeStop(stops[index]))));
  }

  Future<void> _drawCircle(
    maplibre.MapLibreMapController controller, {
    required maplibre.LatLng coordinate,
    required String color,
    required double radius,
    double strokeWidth = 3,
    Map<String, dynamic>? data,
  }) async {
    await controller.addCircle(
      maplibre.CircleOptions(
        geometry: coordinate,
        circleColor: color,
        circleRadius: radius,
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: strokeWidth,
      ),
      data,
    );
  }
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

class _RouteEndpointLegend extends StatelessWidget {
  const _RouteEndpointLegend();

  @override
  Widget build(BuildContext context) => Card(
    elevation: 2,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: const <Widget>[
          _LegendItem(color: Color(0xFFD32F2F), label: 'Start'),
          SizedBox(width: 12),
          _LegendItem(color: Color(0xFFF57C00), label: 'Gap'),
          SizedBox(width: 12),
          _LegendItem(color: Color(0xFF1565C0), label: 'Stop'),
          SizedBox(width: 12),
          _LegendItem(color: Color(0xFFF9A825), label: 'Uncertain'),
          SizedBox(width: 12),
          _LegendItem(color: Color(0xFF2E7D32), label: 'Destination'),
        ],
      ),
    ),
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
  /// or pause is never a gap.
  factory RouteGeometry.fromReport(
    RouteGeometryReport report, {
    Iterable<TrackingContinuityGap>? gaps,
    Map<String, maplibre.LatLng>? cleaned,
    Iterable<TrackStop> stops = const <TrackStop>[],
    RouteTotals? totals,
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
      uncertain.addAll(_uncertainStretches(valid, coordinates));
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
    for (var start = 0; start + window <= points.length; start += 1) {
      final members = points.sublist(start, start + window);
      if (members.last.capturedAt.difference(members.first.capturedAt) <
          const Duration(seconds: 30)) {
        continue;
      }
      var path = 0.0;
      for (var index = 1; index < members.length; index += 1) {
        path += _meters(members[index - 1], members[index]);
      }
      final net = _meters(members.first, members.last);
      final sigmas =
          members
              .map(
                (point) =>
                    math.max(1.5, (point.horizontalAccuracy ?? 20) / 1.51),
              )
              .toList()
            ..sort();
      final sigma = sigmas[sigmas.length ~/ 2];
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
