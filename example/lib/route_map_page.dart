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
  var _cleaned = true;

  Future<RouteGeometry> _load() async {
    final tracking = widget.tracking;
    if (tracking is TrackingGeometryController) {
      final geometry = tracking as TrackingGeometryController;
      final report = await geometry.assembleTrackRouteGeometry(
        widget.track.id,
        continuity: _continuity,
      );
      return RouteGeometry.fromReport(
        report,
        cleaned: _cleaned ? await cleanedCoordinates(geometry, report) : null,
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
    cleaned: _cleaned,
    onCleanedChanged: widget.tracking is TrackingGeometryController
        ? (value) => setState(() => _cleaned = value)
        : null,
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
  var _cleaned = true;

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
    final report = results[0] as RouteGeometryReport;
    final tracking = widget.tracking;
    return RouteGeometry.fromReport(
      report,
      gaps: (results[1] as TripBundle).gaps,
      cleaned: _cleaned && tracking is TrackingGeometryController
          ? await cleanedCoordinates(
              tracking as TrackingGeometryController,
              report,
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) => _RouteMapScaffold(
    title: widget.trip.routeId ?? 'Multi-day Trip',
    continuity: _continuity,
    onContinuityChanged: (value) => setState(() => _continuity = value),
    cleaned: _cleaned,
    onCleanedChanged: widget.tracking is TrackingGeometryController
        ? (value) => setState(() => _cleaned = value)
        : null,
    future: _load(),
  );
}

/// Cleaned positions for every point of [report], by point ID.
///
/// Each track keeps one stop-aware cleaning run, derived again only when the
/// track has newer points or the run used older stop rules. The recorded
/// points never change.
Future<Map<String, maplibre.LatLng>> cleanedCoordinates(
  TrackingGeometryController geometry,
  RouteGeometryReport report,
) async {
  final newestSequence = <String, int>{};
  for (final part in report.parts) {
    for (final point in part.points) {
      newestSequence[point.trackId] = math.max(
        newestSequence[point.trackId] ?? 0,
        point.sequence,
      );
    }
  }
  final cleaned = <String, maplibre.LatLng>{};
  for (final MapEntry(key: trackId, value: newest) in newestSequence.entries) {
    final current = await currentCleaningRun(
      geometry,
      trackId,
      newestSequence: newest,
    );
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

/// The track's current stop-aware cleaning run: the newest completed run when
/// it covers [newestSequence] and used the current stop rules, otherwise a new
/// one. Older runs are deleted.
Future<DerivedGeometryRun> currentCleaningRun(
  TrackingGeometryController geometry,
  String trackId, {
  required int newestSequence,
}) async {
  final runs =
      (await geometry.listDerivedGeometry(trackId))
          .where(
            (run) =>
                run.algorithm ==
                    DerivedGeometryAlgorithm.stopAwareRouteCleaning &&
                run.status == DerivedGeometryRunStatus.completed,
          )
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final reusable =
      runs.isNotEmpty &&
      runs.first.sourceMaximumSequence >= newestSequence &&
      runs.first.algorithmVersion ==
          DerivedGeometryAlgorithm.stopAwareRouteCleaningVersion;
  final current = reusable
      ? runs.first
      : await geometry.deriveGeometry(
          trackId,
          request: const DerivedGeometryRequest(
            name: 'cleaned',
            algorithm: DerivedGeometryAlgorithm.stopAwareRouteCleaning,
          ),
        );
  for (final stale in runs.where((run) => run.id != current.id)) {
    await geometry.deleteDerivedGeometry(trackId, stale.id);
  }
  return current;
}

class _RouteMapScaffold extends StatelessWidget {
  const _RouteMapScaffold({
    required this.title,
    required this.continuity,
    required this.onContinuityChanged,
    required this.cleaned,
    required this.onCleanedChanged,
    required this.future,
  });

  final String title;
  final RouteGeometryContinuity continuity;
  final ValueChanged<RouteGeometryContinuity> onContinuityChanged;
  final bool cleaned;

  /// Null when the tracking facade cannot derive geometry.
  final ValueChanged<bool>? onCleanedChanged;
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
                          '${route.stopMarkers.length} stop(s) • '
                          '${route.geometryPartCount} drawable part(s) • '
                          '${route.gapCount} quality event(s) • '
                          '${route.visibleGapCount} visible gap(s)',
                        ),
                      ),
                      if (onCleanedChanged case final onChanged?) ...<Widget>[
                        const SizedBox(width: 8),
                        SegmentedButton<bool>(
                          showSelectedIcon: false,
                          segments: const <ButtonSegment<bool>>[
                            ButtonSegment(value: true, label: Text('Cleaned')),
                            ButtonSegment(value: false, label: Text('Raw')),
                          ],
                          selected: <bool>{cleaned},
                          onSelectionChanged: (selection) =>
                              onChanged(selection.first),
                        ),
                      ],
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
                    child: Text(
                      route.cleanedDistanceMeters == null
                          ? 'Recorded ${_kilometres(route.recordedDistanceMeters)}'
                                ' • raw evidence'
                          : 'Recorded ${_kilometres(route.recordedDistanceMeters)}'
                                ' • cleaned ≈ '
                                '${_kilometres(route.cleanedDistanceMeters!)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
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
                      key: ValueKey<(RouteGeometryContinuity, bool)>((
                        continuity,
                        cleaned,
                      )),
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

String _kilometres(double meters) => '${(meters / 1000).toStringAsFixed(2)} km';

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
    for (final stop in widget.route.stopMarkers) {
      await _drawCircle(
        controller,
        coordinate: stop.coordinate,
        color: '#1565C0',
        radius: 7,
        strokeWidth: 2,
      );
      try {
        await controller.addSymbol(
          maplibre.SymbolOptions(
            geometry: stop.coordinate,
            textField: _duration(stop.duration),
            textSize: 12,
            textOffset: const Offset(0, 1.4),
            textColor: '#0D47A1',
            textHaloColor: '#FFFFFF',
            textHaloWidth: 1.5,
          ),
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

  static String _duration(Duration duration) => duration.inMinutes >= 60
      ? '${duration.inHours} h ${duration.inMinutes % 60} min'
      : '${math.max(1, duration.inMinutes)} min';

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

/// A stop drawn as one marker: the cleaned centre and how long it lasted.
class RouteStopMarker {
  const RouteStopMarker({required this.coordinate, required this.duration});

  final maplibre.LatLng coordinate;
  final Duration duration;
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
    this.recordedDistanceMeters = 0,
    this.cleanedDistanceMeters,
  });

  final List<List<maplibre.LatLng>> segments;
  final List<maplibre.LatLng> points;
  final List<maplibre.LatLng> gapMarkers;

  /// Stops of the cleaned view; empty for raw evidence.
  final List<RouteStopMarker> stopMarkers;

  /// Low-confidence stretches drawn over [segments].
  final List<List<maplibre.LatLng>> uncertainSegments;

  /// Length of the recorded accepted points, part by part.
  final double recordedDistanceMeters;

  /// Length of the cleaned view, or null for raw evidence.
  final double? cleanedDistanceMeters;
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

  /// Builds map geometry from [report]. With [cleaned] positions, stops
  /// collapse to markers and their gaps are not drawn as gaps.
  factory RouteGeometry.fromReport(
    RouteGeometryReport report, {
    Iterable<TrackingContinuityGap>? gaps,
    Map<String, maplibre.LatLng>? cleaned,
  }) {
    final all = <maplibre.LatLng>[];
    final pointCoordinates = <String, maplibre.LatLng>{};
    final segments = <List<maplibre.LatLng>>[];
    final uncertain = <List<maplibre.LatLng>>[];
    final stops = <RouteStopMarker>[];
    final stopPointIds = <String>{};
    var recorded = 0.0;
    double? cleanedDistance = cleaned == null ? null : 0.0;
    for (final part in report.parts) {
      final valid = part.points.where(_valid).toList();
      final raw = <maplibre.LatLng>[
        for (final point in valid)
          maplibre.LatLng(point.latitude, point.longitude),
      ];
      final coordinates = <maplibre.LatLng>[
        for (var index = 0; index < valid.length; index += 1)
          cleaned?[valid[index].id] ?? raw[index],
      ];
      for (var index = 0; index < valid.length; index += 1) {
        all.add(coordinates[index]);
        pointCoordinates[valid[index].id] = coordinates[index];
      }
      if (coordinates.length >= 2) segments.add(coordinates);
      recorded += _pathMeters(raw);
      if (cleanedDistance != null) {
        cleanedDistance += _pathMeters(coordinates);
        stops.addAll(_stopsOf(valid, coordinates, stopPointIds));
      }
      uncertain.addAll(_uncertainStretches(valid, coordinates, stopPointIds));
    }
    final markers = <maplibre.LatLng>[];
    final representedBoundaries = <String>{};
    for (final gap in gaps ?? report.gaps) {
      if (!_isVisibleGap(gap)) continue;
      // In the cleaned view a stop is a marker, not a gap, and so is a gap
      // that starts or ends at a stop.
      if (cleaned != null &&
          (gap.cause == TrackingGapCause.expectedStationarySuppression ||
              stopPointIds.contains(gap.beforePointId) ||
              stopPointIds.contains(gap.afterPointId))) {
        continue;
      }
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
      stopMarkers: stops,
      uncertainSegments: uncertain,
      recordedDistanceMeters: recorded,
      cleanedDistanceMeters: cleanedDistance,
    );
  }

  /// Shortest stay drawn as a stop marker; it matches the package's rule for
  /// a stop without still evidence.
  static const minimumStopMarkerDuration = Duration(minutes: 2);

  /// Runs of consecutive points the cleaning collapsed onto one coordinate:
  /// three or more, or two whose stay, until the next point, lasted
  /// [minimumStopMarkerDuration]. A stay counts the time until the next point
  /// because fixes held at a stop are not drawn.
  static List<RouteStopMarker> _stopsOf(
    List<TrackPoint> points,
    List<maplibre.LatLng> coordinates,
    Set<String> stopPointIds,
  ) {
    final stops = <RouteStopMarker>[];
    var first = 0;
    for (var index = 1; index <= points.length; index += 1) {
      final continues =
          index < points.length && coordinates[index] == coordinates[first];
      if (continues) continue;
      final count = index - first;
      final leftAt = index < points.length
          ? points[index].capturedAt
          : points[index - 1].capturedAt;
      final stay = leftAt.difference(points[first].capturedAt);
      if (count >= 3 || (count == 2 && stay >= minimumStopMarkerDuration)) {
        stops.add(
          RouteStopMarker(coordinate: coordinates[first], duration: stay),
        );
        for (var member = first; member < index; member += 1) {
          stopPointIds.add(points[member].id);
        }
      }
      first = index;
    }
    return stops;
  }

  /// Stretches of five or more fixes, at least 30 s long, that zig-zag
  /// inside their own uncertainty: little net progress for the path drawn.
  static List<List<maplibre.LatLng>> _uncertainStretches(
    List<TrackPoint> points,
    List<maplibre.LatLng> coordinates,
    Set<String> stopPointIds,
  ) {
    const window = 5;
    final flagged = List<bool>.filled(points.length, false);
    for (var start = 0; start + window <= points.length; start += 1) {
      final members = points.sublist(start, start + window);
      if (members.any((point) => stopPointIds.contains(point.id))) continue;
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

  static double _pathMeters(List<maplibre.LatLng> path) {
    var total = 0.0;
    for (var index = 1; index < path.length; index += 1) {
      total += _distanceMeters(path[index - 1], path[index]);
    }
    return total;
  }

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
    List<RouteStopMarker> stopMarkers = const <RouteStopMarker>[],
    List<List<maplibre.LatLng>> uncertainSegments =
        const <List<maplibre.LatLng>>[],
    double recordedDistanceMeters = 0,
    double? cleanedDistanceMeters,
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
      recordedDistanceMeters: recordedDistanceMeters,
      cleanedDistanceMeters: cleanedDistanceMeters,
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
