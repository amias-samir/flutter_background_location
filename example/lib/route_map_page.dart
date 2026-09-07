import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as maplibre;

class TrackMapPage extends StatefulWidget {
  const TrackMapPage({super.key, required this.tracking, required this.track});

  final Tracking tracking;
  final Track track;

  @override
  State<TrackMapPage> createState() => _TrackMapPageState();
}

class _TrackMapPageState extends State<TrackMapPage> {
  var _continuity = RouteGeometryContinuity.mergeAutomaticCallbackGaps;

  Future<RouteGeometry> _load() async {
    final tracking = widget.tracking;
    if (tracking is TrackingGeometryController) {
      return RouteGeometry.fromReport(
        await (tracking as TrackingGeometryController)
            .assembleTrackRouteGeometry(
              widget.track.id,
              continuity: _continuity,
            ),
      );
    }
    final bundle = await tracking.loadTrackBundle(widget.track.id);
    return RouteGeometry.fromReport(
      const RouteGeometryAssembler().assemble(
        sourceParts: bundle.segments.map(
          (segment) => RouteGeometrySourcePart(
            legNumber: 1,
            segment: segment.segment,
            points: segment.points,
          ),
        ),
        continuity: _continuity,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _RouteMapScaffold(
    title: 'Recorded route',
    continuity: _continuity,
    onContinuityChanged: (value) => setState(() => _continuity = value),
    future: _load(),
  );
}

class TripMapPage extends StatefulWidget {
  const TripMapPage({super.key, required this.tracking, required this.trip});

  final MultiDayTripController tracking;
  final Trip trip;

  @override
  State<TripMapPage> createState() => _TripMapPageState();
}

class _TripMapPageState extends State<TripMapPage> {
  late RouteGeometryContinuity _continuity;

  @override
  void initState() {
    super.initState();
    _continuity = widget.trip.routePresentation.geometryContinuity;
  }

  Future<RouteGeometry> _load() async {
    final results = await Future.wait<Object>(<Future<Object>>[
      widget.tracking.assembleTripRouteGeometry(
        widget.trip.id,
        continuity: _continuity,
      ),
      widget.tracking.loadTripBundle(widget.trip.id),
    ]);
    return RouteGeometry.fromReport(
      results[0] as RouteGeometryReport,
      gaps: (results[1] as TripBundle).gaps,
    );
  }

  @override
  Widget build(BuildContext context) => _RouteMapScaffold(
    title: widget.trip.routeId ?? 'Multi-day Trip',
    continuity: _continuity,
    onContinuityChanged: (value) => setState(() => _continuity = value),
    future: _load(),
  );
}

class _RouteMapScaffold extends StatelessWidget {
  const _RouteMapScaffold({
    required this.title,
    required this.continuity,
    required this.onContinuityChanged,
    required this.future,
  });

  final String title;
  final RouteGeometryContinuity continuity;
  final ValueChanged<RouteGeometryContinuity> onContinuityChanged;
  final Future<RouteGeometry> future;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: FutureBuilder<RouteGeometry>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: SelectableText(snapshot.error.toString()));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final route = snapshot.requireData;
        if (route.points.isEmpty) {
          return const Center(child: Text('No accepted coordinates yet.'));
        }
        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: Column(
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '${route.pointCount} points • '
                          '${route.geometryPartCount} drawable part(s) • '
                          '${route.gapCount} quality event(s) • '
                          '${route.visibleGapCount} visible gap(s)',
                        ),
                      ),
                      const SizedBox(width: 8),
                      PopupMenuButton<RouteGeometryContinuity>(
                        tooltip: 'Route continuity',
                        initialValue: continuity,
                        onSelected: onContinuityChanged,
                        itemBuilder: (_) =>
                            const <PopupMenuEntry<RouteGeometryContinuity>>[
                              PopupMenuItem(
                                value: RouteGeometryContinuity
                                    .preserveEvidenceSegments,
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
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(switch (continuity) {
                      RouteGeometryContinuity.preserveEvidenceSegments =>
                        'Recorded daily and lifecycle parts stay separate.',
                      RouteGeometryContinuity.connectDailyLegs =>
                        'Only daily boundaries receive straight inferred connectors.',
                      RouteGeometryContinuity.connectAllChronologicalPoints =>
                        'All parts receive straight inferred connectors; inferred distance is excluded.',
                      RouteGeometryContinuity.mergeAutomaticCallbackGaps =>
                        'Only proven automatic callback gaps are joined.',
                    }, style: Theme.of(context).textTheme.bodySmall),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: <Widget>[
                  Positioned.fill(
                    child: TrackRouteMap(
                      key: ValueKey<RouteGeometryContinuity>(continuity),
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
  Widget build(BuildContext context) => maplibre.MapLibreMap(
    styleString: maplibre.MapLibreStyles.openfreemapLiberty,
    initialCameraPosition: maplibre.CameraPosition(
      target: widget.route.center,
      zoom: widget.route.points.length == 1 ? 15 : 13,
    ),
    onMapCreated: (controller) {
      _controller = controller;
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
    for (final marker in widget.route.gapMarkers) {
      await _drawCircle(
        controller,
        coordinate: marker,
        color: '#F57C00',
        radius: 6,
        strokeWidth: 2,
      );
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

  Future<void> _drawCircle(
    maplibre.MapLibreMapController controller, {
    required maplibre.LatLng coordinate,
    required String color,
    required double radius,
    double strokeWidth = 3,
  }) async {
    await controller.addCircle(
      maplibre.CircleOptions(
        geometry: coordinate,
        circleColor: color,
        circleRadius: radius,
        circleStrokeColor: '#FFFFFF',
        circleStrokeWidth: strokeWidth,
      ),
    );
  }
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
  });

  final List<List<maplibre.LatLng>> segments;
  final List<maplibre.LatLng> points;
  final List<maplibre.LatLng> gapMarkers;
  final maplibre.LatLngBounds bounds;
  final maplibre.LatLng center;
  final int pointCount;
  final int geometryPartCount;
  final int gapCount;
  final int inferredConnectorCount;

  int get visibleGapCount => gapMarkers.length;

  maplibre.LatLng get start => points.first;
  maplibre.LatLng get destination => points.last;

  bool get hasDistinctEndpoints =>
      start.latitude != destination.latitude ||
      start.longitude != destination.longitude;

  factory RouteGeometry.fromReport(
    RouteGeometryReport report, {
    Iterable<TrackingContinuityGap>? gaps,
  }) {
    final all = <maplibre.LatLng>[];
    final pointCoordinates = <String, maplibre.LatLng>{};
    final segments = <List<maplibre.LatLng>>[];
    for (final part in report.parts) {
      final coordinates = <maplibre.LatLng>[];
      for (final point in part.points.where(_valid)) {
        final coordinate = maplibre.LatLng(point.latitude, point.longitude);
        coordinates.add(coordinate);
        all.add(coordinate);
        pointCoordinates[point.id] = coordinate;
      }
      if (coordinates.length >= 2) segments.add(coordinates);
    }
    final markers = <maplibre.LatLng>[];
    final representedBoundaries = <String>{};
    for (final gap in gaps ?? report.gaps) {
      if (!_isVisibleGap(gap)) continue;
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
    );
  }

  factory RouteGeometry.fromBundle(TrackBundle bundle) {
    final report = const RouteGeometryAssembler().assemble(
      sourceParts: bundle.segments.map(
        (segment) => RouteGeometrySourcePart(
          legNumber: 1,
          segment: segment.segment,
          points: segment.points,
        ),
      ),
    );
    return RouteGeometry.fromReport(report);
  }

  static RouteGeometry _create({
    required List<List<maplibre.LatLng>> segments,
    required List<maplibre.LatLng> points,
    required List<maplibre.LatLng> gapMarkers,
    required int geometryPartCount,
    required int gapCount,
    required int inferredConnectorCount,
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

  static bool _isVisibleGap(TrackingContinuityGap gap) {
    if (gap.cause == TrackingGapCause.explicitPause ||
        gap.cause == TrackingGapCause.nativeInterruption ||
        gap.cause == TrackingGapCause.processRestart ||
        gap.cause == TrackingGapCause.permissionOrServiceLoss ||
        gap.cause == TrackingGapCause.overnightBoundary) {
      return true;
    }
    // Same-segment rejected-fix runs are quality diagnostics, not lifecycle
    // breaks. Show only severe automatic gaps so normal urban uncertainty does
    // not cover an otherwise continuous route with orange markers.
    return (gap.providerGap ?? Duration.zero) >= const Duration(seconds: 60) ||
        (gap.straightLineDistanceMeters ?? 0) >= 150;
  }

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
