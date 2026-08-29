import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as maplibre;

class TrackMapPage extends StatelessWidget {
  const TrackMapPage({super.key, required this.tracking, required this.track});

  final Tracking tracking;
  final Track track;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Recorded route')),
    body: FutureBuilder<TrackBundle>(
      future: tracking.loadTrackBundle(track.id),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: SelectableText(snapshot.error.toString()));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final route = RouteGeometry.fromBundle(snapshot.requireData);
        if (route.points.isEmpty) {
          return const Center(child: Text('No accepted coordinates yet.'));
        }
        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                '${route.pointCount} points • '
                '${route.segments.length} drawable segment(s)',
              ),
            ),
            Expanded(
              child: Stack(
                children: <Widget>[
                  Positioned.fill(child: TrackRouteMap(route: route)),
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
    await _drawEndpoint(
      controller,
      coordinate: widget.route.start,
      color: '#D32F2F',
      radius: widget.route.hasDistinctEndpoints ? 8 : 10,
    );
    await _drawEndpoint(
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

  Future<void> _drawEndpoint(
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
    required this.bounds,
    required this.center,
    required this.pointCount,
  });

  final List<List<maplibre.LatLng>> segments;
  final List<maplibre.LatLng> points;
  final maplibre.LatLngBounds bounds;
  final maplibre.LatLng center;
  final int pointCount;

  maplibre.LatLng get start => points.first;

  maplibre.LatLng get destination => points.last;

  bool get hasDistinctEndpoints =>
      start.latitude != destination.latitude ||
      start.longitude != destination.longitude;

  factory RouteGeometry.fromBundle(TrackBundle bundle) {
    final all = <maplibre.LatLng>[];
    final segments = <List<maplibre.LatLng>>[];
    for (final segment in bundle.segments) {
      final coordinates = segment.points
          .where((point) => point.accepted && _valid(point))
          .map((point) => maplibre.LatLng(point.latitude, point.longitude))
          .toList(growable: false);
      all.addAll(coordinates);
      if (coordinates.length >= 2) segments.add(coordinates);
    }
    final bounds = _bounds(all);
    return RouteGeometry(
      segments: segments,
      points: all,
      bounds: bounds,
      center: maplibre.LatLng(
        (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
        (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
      ),
      pointCount: all.length,
    );
  }

  static bool _valid(TrackPoint point) =>
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
