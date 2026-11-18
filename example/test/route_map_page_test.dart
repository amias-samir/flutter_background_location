import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker_example/route_map_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as maplibre;

/// A two-point route with one stop, built without the package.
RouteGeometry _route() {
  const start = maplibre.LatLng(0.5, 0.5);
  const end = maplibre.LatLng(0.5, 0.501);
  return RouteGeometry(
    segments: const <List<maplibre.LatLng>>[
      <maplibre.LatLng>[start, end],
    ],
    points: const <maplibre.LatLng>[start, end],
    gapMarkers: const <maplibre.LatLng>[maplibre.LatLng(0.5, 0.5005)],
    bounds: maplibre.LatLngBounds(southwest: start, northeast: end),
    center: const maplibre.LatLng(0.5, 0.5005),
    pointCount: 2,
    geometryPartCount: 1,
    gapCount: 1,
    inferredConnectorCount: 0,
    stopMarkers: <RouteStopMarker>[
      RouteStopMarker(
        coordinate: const maplibre.LatLng(0.5, 0.5005),
        startedAt: DateTime(2026, 10, 19, 10),
        endedAt: DateTime(2026, 10, 19, 10, 12),
      ),
    ],
  );
}

Widget _app(RouteMapLoader loader, {Key? key}) => MaterialApp(
  home: RouteMapPage(
    key: key,
    title: 'Route',
    loader: loader,
    initialContinuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
    mapBuilder: (key, route, showDiagnostics, fitPadding) =>
        const ColoredBox(color: Color(0xFFE0E0E0)),
  ),
);

void main() {
  testWidgets('the route loads once, not on every rebuild', (tester) async {
    var loads = 0;
    Future<RouteMapContent> loader(
      RouteMapRequest request,
      bool Function() isCancelled,
    ) async {
      loads += 1;
      return RouteMapContent(route: _route());
    }

    await tester.pumpWidget(_app(loader));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_app(loader));
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(find.text('Route'), findsOneWidget);
  });

  testWidgets('leaving the page cancels its load', (tester) async {
    final pending = Completer<RouteMapContent>();
    bool Function()? cancelled;
    await tester.pumpWidget(
      _app((request, isCancelled) {
        cancelled = isCancelled;
        return pending.future;
      }),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(cancelled!(), isFalse);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(cancelled!(), isTrue, reason: 'the page is gone');
    pending.complete(RouteMapContent(route: _route()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed load explains itself and retries', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      _app((request, isCancelled) async {
        attempts += 1;
        if (attempts == 1) {
          throw const TrackingStorageException(
            code: 'storage_failed',
            message: 'internal detail that must not show',
          );
        }
        return RouteMapContent(route: _route());
      }),
    );
    await tester.pumpAndSettle();
    expect(find.text("Couldn't open this route"), findsOneWidget);
    expect(find.textContaining('internal detail'), findsNothing);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text("Couldn't open this route"), findsNothing);
    expect(find.byTooltip('Fit route'), findsOneWidget);
  });

  testWidgets('a view switch keeps the previous map until the new one loads', (
    tester,
  ) async {
    final next = Completer<RouteMapContent>();
    final requests = <RouteView?>[];
    await tester.pumpWidget(
      _app((request, isCancelled) {
        requests.add(request.view);
        if (requests.length == 1) {
          return Future.value(
            RouteMapContent(
              route: _route(),
              view: RouteView.cleaned,
              views: const <RouteView>[RouteView.cleaned, RouteView.raw],
            ),
          );
        }
        return next.future;
      }),
    );
    await tester.pumpAndSettle();
    // Open the sheet to reach the view picker.
    await tester.drag(find.byType(RouteMapHeader), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(SegmentedButton<RouteView>),
        matching: find.text('Raw'),
      ),
    );
    await tester.pump();

    expect(requests, <RouteView?>[null, RouteView.raw]);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byTooltip('Fit route'), findsOneWidget, reason: 'still drawn');

    next.complete(RouteMapContent(route: _route()));
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a route being prepared says so and offers it once ready', (
    tester,
  ) async {
    final updates = StreamController<TrackHistoryEvent>.broadcast();
    addTearDown(updates.close);
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: RouteMapPage(
          title: 'Route',
          initialContinuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
          updates: updates.stream,
          mapBuilder: (key, route, showDiagnostics, fitPadding) =>
              const ColoredBox(color: Color(0xFFE0E0E0)),
          loader: (request, isCancelled) async {
            loads += 1;
            return RouteMapContent(
              route: _route(),
              view: RouteView.cleaned,
              views: const <RouteView>[RouteView.cleaned, RouteView.raw],
              preparing: loads == 1,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Preparing the cleaned view'), findsOneWidget);

    updates.add(
      const TrackHistoryEvent(
        kind: TrackHistoryChangeKind.updated,
        trackId: 'track-1',
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Route details are ready.'), findsOneWidget);
    expect(loads, 1, reason: 'the drawn route does not change by itself');

    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(find.text('Route details are ready.'), findsNothing);
  });

  group('map layers', () {
    test('the route is one feature collection of line strings', () {
      final lines = routeFeatureCollection(_route().segments);
      final features = lines['features'] as List<Map<String, dynamic>>;
      expect(features, hasLength(1));
      final geometry = features.single['geometry'] as Map<String, dynamic>;
      expect(geometry['type'], 'LineString');
      final coordinates = geometry['coordinates'] as List<List<double>>;
      expect(coordinates, hasLength(2));
      expect(coordinates.first[0], closeTo(0.5, 1e-9));
      expect(coordinates.last[0], closeTo(0.501, 1e-9), reason: '[lng, lat]');
      expect(coordinates.last[1], closeTo(0.5, 1e-9));
    });

    test('markers carry stable ids, kinds and stop labels', () {
      final route = _route();
      final withGaps = markerFeatureCollection(route, showDiagnostics: true);
      final ids = <Object?>[
        for (final feature
            in withGaps['features'] as List<Map<String, dynamic>>)
          feature['id'],
      ];
      expect(ids, <String>['gap-0', 'stop-0', 'start', 'end']);
      final stop = (withGaps['features'] as List<Map<String, dynamic>>)[1];
      expect((stop['properties'] as Map)['label'], '12 min');

      final plain = markerFeatureCollection(route, showDiagnostics: false);
      expect(
        (plain['features'] as List<Map<String, dynamic>>).map((f) => f['id']),
        <String>['stop-0', 'start', 'end'],
        reason: 'gaps only with diagnostics',
      );
    });

    test('start is green, end red and stops blue', () {
      final features =
          markerFeatureCollection(_route(), showDiagnostics: false)['features']
              as List<Map<String, dynamic>>;
      final colours = <Object?, Object?>{
        for (final feature in features)
          feature['id']: (feature['properties'] as Map)['color'],
      };
      expect(colours, <String, String>{
        'stop-0': '#1565c0',
        'start': '#2e7d32',
        'end': '#c62828',
      });
    });

    test('stop labels have a source of their own', () {
      final labels =
          stopLabelFeatureCollection(_route())['features']
              as List<Map<String, dynamic>>;
      expect(labels, hasLength(1));
      expect((labels.single['properties'] as Map)['label'], '12 min');
      final at =
          (labels.single['geometry'] as Map)['coordinates'] as List<double>;
      expect(at[0], closeTo(0.5005, 1e-9), reason: '[lng, lat]');
      expect(at[1], closeTo(0.5, 1e-9));
    });

    test('the first camera centres on the route', () {
      final camera = initialRouteCamera(
        _route(),
        const Size(400, 800),
        const EdgeInsets.all(48),
      );
      expect(camera.target, _route().center);
      expect(camera.zoom, inInclusiveRange(2, 17));
    });
  });
}
