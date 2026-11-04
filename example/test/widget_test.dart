import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_background_location_tracker_example/main.dart';
import 'package:flutter_background_location_tracker_example/recorded_tracks_section.dart';
import 'package:flutter_background_location_tracker_example/recorded_trips_section.dart';
import 'package:flutter_background_location_tracker_example/route_map_page.dart';
import 'package:flutter_background_location_tracker_example/route_totals.dart';
import 'package:flutter_background_location_tracker_example/tracking_controls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as maplibre;

void main() {
  TrackingExampleApp testApp() => TrackingExampleApp(
    controllerFactory: (owner, _) async => FakeTrackingController(owner: owner),
  );

  test('example exposes a Flutter application widget', () {
    expect(const TrackingExampleApp(), isA<Widget>());
  });

  testWidgets('keep all retention is selected by default', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    final selector = tester.widget<SegmentedButton<TrackRecordRetentionPolicy>>(
      find.byType(SegmentedButton<TrackRecordRetentionPolicy>),
    );
    expect(selector.selected, <TrackRecordRetentionPolicy>{
      TrackRecordRetentionPolicy.keepAll,
    });
  });

  testWidgets('precised profile explains and opens battery settings', (
    tester,
  ) async {
    const owner = TrackingOwner(
      userId: 'example-user',
      organizationId: 'example-organization',
    );
    final controller = FakeTrackingController(owner: owner);
    await tester.pumpWidget(
      TrackingExampleApp(controllerFactory: (_, _) async => controller),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Accuracy'));
    await tester.pumpAndSettle();
    expect(find.text('Accuracy profile'), findsOneWidget);
    await tester.tap(find.text('Precised'));
    await tester.pumpAndSettle();

    expect(find.text('Precised tracking uses more battery'), findsOneWidget);
    expect(find.textContaining('Unrestricted'), findsOneWidget);
    await tester.tap(find.text('Open battery settings'));
    await tester.pumpAndSettle();

    expect(
      controller.calls.any(
        (call) =>
            call.method == 'openSettings' &&
            call.arguments['destination'] == 'batteryOptimization',
      ),
      isTrue,
    );
    expect(find.text('Precised'), findsOneWidget, reason: 'the tile');
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Battery settings'), findsOne);
  });

  test('each capture intent describes how it really captures', () {
    String detail(RouteCaptureIntent intent, TrackingAccuracy accuracy) =>
        PreferenceLabels.intentDetail(intent, accuracy);

    expect(
      detail(RouteCaptureIntent.adaptive, TrackingAccuracy.high),
      'Moving: a fix every 5 s or 5 m and at each turn. Still: slows to '
      'every 20 s or 20 m. Records stops; keeps fixes within 20 m (35 m '
      'while riding).',
    );
    expect(
      detail(RouteCaptureIntent.walking, TrackingAccuracy.high),
      'Always a fix every 3 s or 3 m and at each turn, never slowing when '
      'still. Keeps fixes within 20 m; no stop records. Walking and cycling '
      'capture alike.',
    );
    expect(
      detail(RouteCaptureIntent.cycling, TrackingAccuracy.high),
      detail(RouteCaptureIntent.walking, TrackingAccuracy.high),
      reason: 'the package captures walking and cycling alike',
    );
    expect(
      detail(RouteCaptureIntent.vehicle, TrackingAccuracy.high),
      'Always a fix every 3 s or 3 m and at each turn, never slowing when '
      'still. Keeps fixes within 35 m, wider for urban streets; no stop '
      'records.',
    );
    expect(
      detail(RouteCaptureIntent.vehicle, TrackingAccuracy.low),
      isNot(contains('wider')),
      reason: 'low keeps 100 m for every intent',
    );
    expect(
      detail(RouteCaptureIntent.adaptive, TrackingAccuracy.low),
      isNot(contains('while riding')),
    );
  });

  testWidgets('start asks for a non-empty route identifier', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    final start = find.widgetWithText(FilledButton, 'Start').first;
    await tester.tap(start);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Route ID'), findsOneWidget);
    final startTracking = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, 'Start'),
    );
    expect(tester.widget<FilledButton>(startTracking).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'Morning route');
    await tester.pump();
    expect(tester.widget<FilledButton>(startTracking).onPressed, isNotNull);
  });

  testWidgets('process restoration enables Resume and Complete', (
    tester,
  ) async {
    const owner = TrackingOwner(
      userId: 'example-user',
      organizationId: 'example-organization',
    );
    final controller = FakeTrackingController(owner: owner)
      ..seedInterruptedTrack(routeId: 'restored_route');
    await tester.pumpWidget(
      TrackingExampleApp(controllerFactory: (_, _) async => controller),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Start'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Resume'))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Complete'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('every recorded-route overflow action invokes its handler', (
    tester,
  ) async {
    final calls = <String>[];
    final track = _completedTrack();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordedTracksSection(
            tracks: <Track>[track],
            hasMore: false,
            onLoadMore: () async {},
            onViewMap: (_) async => calls.add('map'),
            onExport: (_, format) async => calls.add(format.name),
            onDelete: (_) async => calls.add('delete'),
          ),
        ),
      ),
    );

    final expectations = <String, String>{
      'Export GeoJSON': 'geoJson',
      'Export KML': 'kml',
      'Export GPX': 'gpx',
      'View on map': 'map',
      'Delete': 'delete',
    };
    for (final entry in expectations.entries) {
      await tester.tap(find.byTooltip('Route actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(calls.last, entry.value, reason: entry.key);
    }
  });

  testWidgets('a tap on a route card opens its map', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordedTracksSection(
            tracks: <Track>[_completedTrack()],
            hasMore: false,
            onLoadMore: null,
            onViewMap: (track) async => opened.add(track.id),
            onExport: null,
            onDelete: null,
          ),
        ),
      ),
    );

    await tester.tap(find.text('route_1'));
    await tester.pump();
    expect(opened, <String>['track-1']);
  });

  testWidgets('the map sheet lists the stops and shows a tapped one', (
    tester,
  ) async {
    final track = _completedTrack();
    final source = _segment(track, 1, const <(double, double)>[
      (0.5, 0.5),
      (0.5, 0.501),
    ]);
    final stop = TrackStop(
      id: 'stop-1',
      trackId: track.id,
      segmentId: source.segment.id,
      kind: TrackStopKind.dwell,
      latitude: 0.5,
      longitude: 0.5005,
      centreSigmaMeters: 2,
      radiusMeters: 25,
      startedAt: DateTime(2026, 10, 19, 10, 5),
      lastSeenAt: DateTime(2026, 10, 19, 11, 17),
      endedAt: DateTime(2026, 10, 19, 11, 17),
      evidenceCount: 30,
      qualityPolicyVersion: 5,
    );
    final route = RouteGeometry.fromReport(
      const RouteGeometryAssembler().assemble(
        sourceParts: <RouteGeometrySourcePart>[
          RouteGeometrySourcePart(
            legNumber: 1,
            segment: source.segment,
            points: source.points,
          ),
        ],
      ),
      stops: <TrackStop>[stop],
    );
    final shown = <RouteStopMarker>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RouteMapHeader(
            content: RouteMapContent(route: route),
            continuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
            onContinuityChanged: (_) {},
            onViewChanged: (_) {},
            onStopSelected: shown.add,
          ),
        ),
      ),
    );

    expect(find.text('Stops'), findsOneWidget);
    expect(find.text('1 h 12 min'), findsOneWidget);
    expect(find.text('10:05–11:17'), findsOneWidget);
    await tester.tap(find.text('1 h 12 min'));
    expect(shown.single.coordinate, const maplibre.LatLng(0.5, 0.5005));
  });

  testWidgets('only the stop list scrolls in the map panel', (tester) async {
    final track = _completedTrack();
    final source = _segment(track, 1, const <(double, double)>[
      (0.5, 0.5),
      (0.5, 0.501),
    ]);
    final start = DateTime(2026, 10, 19, 8);
    final route = RouteGeometry.fromReport(
      const RouteGeometryAssembler().assemble(
        sourceParts: <RouteGeometrySourcePart>[
          RouteGeometrySourcePart(
            legNumber: 1,
            segment: source.segment,
            points: source.points,
          ),
        ],
      ),
      totals: const RouteTotals(
        distanceMeters: 1490,
        displayDistanceMeters: 1490,
        segmentCount: 1,
        moving: Duration(minutes: 40),
        stopped: Duration(minutes: 20),
        stopCount: 12,
        qualityEventCount: 0,
        visibleGapCount: 0,
      ),
      stops: <TrackStop>[
        for (var index = 0; index < 12; index += 1)
          TrackStop(
            id: 'stop-$index',
            trackId: track.id,
            segmentId: source.segment.id,
            kind: TrackStopKind.dwell,
            latitude: 0.5,
            longitude: 0.5,
            centreSigmaMeters: 2,
            radiusMeters: 25,
            startedAt: start.add(Duration(minutes: index * 10)),
            lastSeenAt: start.add(Duration(minutes: index * 10 + 3)),
            endedAt: start.add(Duration(minutes: index * 10 + 3)),
            evidenceCount: 30,
            qualityPolicyVersion: 5,
          ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: RouteMapHeader(
              content: RouteMapContent(route: route),
              continuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
              onContinuityChanged: (_) {},
              onViewChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    final distance = tester.getTopLeft(find.text('1.49 km'));
    final list = find.byType(Scrollable);
    expect(list, findsOneWidget, reason: 'the stop list alone scrolls');
    expect(
      tester.state<ScrollableState>(list).position.maxScrollExtent,
      greaterThan(0),
    );
    await tester.drag(list, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('1.49 km')), distance);
  });

  test('map geometry keeps paused route segments separate', () {
    final track = _completedTrack(segmentCount: 2);
    final bundle = TrackBundle(
      track: track,
      segments: <TrackSegmentWithPoints>[
        _segment(track, 1, const <(double, double)>[(0, 0), (1, 1)]),
        _segment(track, 2, const <(double, double)>[(20, 20), (21, 21)]),
      ],
    );

    final geometry = RouteGeometry.fromBundle(bundle);

    expect(geometry.segments, hasLength(2));
    expect(geometry.segments.first.last.latitude, 1);
    expect(geometry.segments.last.first.latitude, 20);
    expect(geometry.start.latitude, 0);
    expect(geometry.start.longitude, 0);
    expect(geometry.destination.latitude, 21);
    expect(geometry.destination.longitude, 21);
    expect(geometry.hasDistinctEndpoints, isTrue);
  });

  test('single-point map uses the same coordinate for both endpoints', () {
    final track = _completedTrack();
    final geometry = RouteGeometry.fromBundle(
      TrackBundle(
        track: track,
        segments: <TrackSegmentWithPoints>[
          _segment(track, 1, const <(double, double)>[(27.7, 85.3)]),
        ],
      ),
    );

    expect(geometry.start.latitude, geometry.destination.latitude);
    expect(geometry.start.longitude, geometry.destination.longitude);
    expect(geometry.hasDistinctEndpoints, isFalse);
  });

  test('Complete Trip finds the Trip of a paused leg', () async {
    const owner = TrackingOwner(
      userId: 'example-user',
      organizationId: 'example-organization',
    );
    // Pausing a leg suspends its Trip.
    final tracking = _OpenTrips(<Trip>[
      Trip(
        id: 'trip-1',
        organizationId: 'example-organization',
        userId: 'example-user',
        routeId: 'multi_day_route',
        status: TripStatus.suspended,
        startedAt: DateTime.utc(2026),
        currentLegTrackId: 'track-1',
        legCount: 1,
        acceptedPointCount: 5,
        rejectedPointCount: 0,
        measuredDistanceMeters: 120,
        lifecycleRevision: 2,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    ]);

    final trip = await findOpenTrip(tracking, owner, 'track-1');

    expect(trip?.id, 'trip-1');
    expect(await findOpenTrip(tracking, owner, 'track-2'), isNull);
  });

  testWidgets('completed Trip menu exposes export, map, continue, and delete', (
    tester,
  ) async {
    final calls = <String>[];
    final trip = Trip(
      id: 'trip-1',
      organizationId: 'example-organization',
      userId: 'example-user',
      routeId: 'multi_day_route',
      status: TripStatus.completed,
      startedAt: DateTime.utc(2026),
      endedAt: DateTime.utc(2026, 1, 3),
      legCount: 3,
      acceptedPointCount: 20,
      rejectedPointCount: 2,
      measuredDistanceMeters: 1234,
      lifecycleRevision: 6,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026, 1, 3),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordedTripsSection(
            trips: <RecordedTripSummary>[RecordedTripSummary(trip: trip)],
            hasMore: false,
            onLoadMore: () async {},
            onViewMap: (_) async => calls.add('map'),
            onContinue: (_) async => calls.add('continue'),
            onExport: (_, format) async => calls.add(format.name),
            onDelete: (_) async => calls.add('delete'),
          ),
        ),
      ),
    );

    final expectations = <String, String>{
      'Export GeoJSON': 'geoJson',
      'Export KML': 'kml',
      'Export GPX': 'gpx',
      'View all days on map': 'map',
      'Continue completed Trip': 'continue',
      'Delete Trip': 'delete',
    };
    for (final entry in expectations.entries) {
      await tester.tap(find.byTooltip('Trip actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry.key));
      await tester.pumpAndSettle();
      expect(calls.last, entry.value, reason: entry.key);
    }
  });

  test('the map marks the gaps the route database marks visible', () {
    final track = _completedTrack();
    final source = _segment(track, 1, const <(double, double)>[
      (27.7, 85.3),
      (27.71, 85.31),
    ]);
    RouteGeometry geometryWith(TrackingGapCause cause) {
      final gap = TrackingContinuityGap(
        id: 'gap-1',
        trackId: track.id,
        beforePointId: source.points.first.id,
        afterPointId: source.points.last.id,
        beforeSegmentId: source.segment.id,
        afterSegmentId: source.segment.id,
        cause: cause,
        treatment: TrackingGapTreatment.retainCurrentSegment,
        distanceTreatment: TrackingGapDistanceTreatment.excluded,
        continuityPolicyVersion: 1,
        providerGap: const Duration(seconds: 61),
        createdAt: DateTime.utc(2026),
      );
      expect(
        gap.isVisible,
        cause != TrackingGapCause.expectedStationarySuppression,
      );
      return RouteGeometry.fromReport(
        const RouteGeometryAssembler().assemble(
          sourceParts: <RouteGeometrySourcePart>[
            RouteGeometrySourcePart(
              legNumber: 1,
              segment: source.segment,
              points: source.points,
            ),
          ],
          gaps: <TrackingContinuityGap>[gap],
          continuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
        ),
      );
    }

    final severe = geometryWith(TrackingGapCause.acceptedFixRejectionRun);
    expect(severe.segments, hasLength(1));
    expect(severe.gapMarkers, hasLength(1));
    expect(severe.gapCount, 1);
    expect(
      geometryWith(TrackingGapCause.expectedStationarySuppression).gapMarkers,
      isEmpty,
      reason: 'a stop or pause is no hole',
    );
  });

  test('the cleaned view moves points but invents no stops', () {
    final track = _completedTrack();
    // East offsets in metres around a synthetic origin, one fix per 20 s.
    const east = <double>[-90, -60, -30, 3, -4, 6, -2, 5, 30, 60, 90];
    final source = _timedSegment(track, east, spacing: 20, accuracy: 5);
    final stay = source.points.sublist(3, 8);
    final report = const RouteGeometryAssembler().assemble(
      sourceParts: <RouteGeometrySourcePart>[
        RouteGeometrySourcePart(
          legNumber: 1,
          segment: source.segment,
          points: source.points,
        ),
      ],
      continuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
    );
    final centre = maplibre.LatLng(stay.first.latitude, 0.5);

    final cleaned = RouteGeometry.fromReport(
      report,
      cleaned: <String, maplibre.LatLng>{
        for (final point in stay) point.id: centre,
      },
    );

    expect(cleaned.points.where((point) => point == centre), hasLength(5));
    expect(cleaned.segments.single, hasLength(east.length));
    expect(
      cleaned.stopMarkers,
      isEmpty,
      reason: 'stops come from the route database',
    );
  });

  test('a zig-zag inside its own uncertainty is drawn as uncertain', () {
    final track = _completedTrack();
    final zigzag = _timedSegment(
      track,
      const <double>[0, 9, -7, 8, -9, 6, -5],
      spacing: 14,
      accuracy: 8,
    );
    final walk = _timedSegment(
      track,
      const <double>[0, 12, 24, 36, 48, 60, 72],
      spacing: 10,
      accuracy: 5,
    );
    RouteGeometry geometryOf(TrackSegmentWithPoints source) =>
        RouteGeometry.fromReport(
          const RouteGeometryAssembler().assemble(
            sourceParts: <RouteGeometrySourcePart>[
              RouteGeometrySourcePart(
                legNumber: 1,
                segment: source.segment,
                points: source.points,
              ),
            ],
            continuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
          ),
        );

    expect(geometryOf(zigzag).uncertainSegments, isNotEmpty);
    expect(geometryOf(walk).uncertainSegments, isEmpty);
  });

  test('recorded stops are markers in both views, never gaps', () {
    final track = _completedTrack();
    // Fixes held at the stop are not route points: the route goes from the
    // arrival at -10 m to the departure at 25 m.
    const east = <double>[-90, -60, -30, -10, 25, 60, 90];
    final source = _timedSegment(track, east, spacing: 300, accuracy: 5);
    final arrival = source.points[3];
    final departure = source.points[4];
    final gap = TrackingContinuityGap(
      id: 'gap-1',
      trackId: track.id,
      beforePointId: arrival.id,
      afterPointId: departure.id,
      beforeSegmentId: source.segment.id,
      afterSegmentId: source.segment.id,
      cause: TrackingGapCause.expectedStationarySuppression,
      treatment: TrackingGapTreatment.retainCurrentSegment,
      distanceTreatment: TrackingGapDistanceTreatment.measured,
      continuityPolicyVersion: 3,
      providerGap: const Duration(seconds: 300),
      createdAt: DateTime.utc(2026),
    );
    final report = const RouteGeometryAssembler().assemble(
      sourceParts: <RouteGeometrySourcePart>[
        RouteGeometrySourcePart(
          legNumber: 1,
          segment: source.segment,
          points: source.points,
        ),
      ],
      gaps: <TrackingContinuityGap>[gap],
      continuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
    );
    final stop = TrackStop(
      id: 'stop-1',
      trackId: track.id,
      segmentId: source.segment.id,
      kind: TrackStopKind.dwell,
      latitude: 0.5,
      longitude: 0.5,
      centreSigmaMeters: 2,
      radiusMeters: 25,
      startedAt: arrival.capturedAt,
      lastSeenAt: departure.capturedAt.subtract(const Duration(seconds: 10)),
      endedAt: departure.capturedAt,
      evidenceCount: 30,
      qualityPolicyVersion: 3,
      arrivalPointId: arrival.id,
      departurePointId: departure.id,
    );
    const centre = maplibre.LatLng(0.5, 0.5);
    final collapsed = <String, maplibre.LatLng>{
      arrival.id: centre,
      departure.id: centre,
    };

    final raw = RouteGeometry.fromReport(report, stops: <TrackStop>[stop]);
    expect(raw.stopMarkers, hasLength(1));
    expect(raw.stopMarkers.single.coordinate, centre);
    expect(raw.stopMarkers.single.duration, const Duration(minutes: 5));
    expect(raw.gapMarkers, isEmpty, reason: 'a stop is not a gap');
    expect(RouteGeometry.fromReport(report).gapMarkers, isEmpty);

    final cleaned = RouteGeometry.fromReport(
      report,
      cleaned: collapsed,
      stops: <TrackStop>[stop],
    );
    expect(cleaned.stopMarkers, hasLength(1), reason: 'no second marker');
    expect(cleaned.gapMarkers, isEmpty);
  });

  test('the map header shows the route database\'s totals', () {
    final track = _completedTrack();
    final route = RouteGeometry.fromBundle(
      TrackBundle(
        track: track,
        segments: <TrackSegmentWithPoints>[
          _segment(track, 1, const <(double, double)>[(0, 0), (0.001, 0)]),
        ],
      ),
    );
    expect(routeHeadline(route), '2 points • 0 stop(s) • 1 drawable part(s)');
    expect(routeStats(null, cleaned: true), isEmpty);

    final totals = RouteTotals.ofRoute(
      RouteSummary(
        trackId: track.id,
        startedAt: track.startedAt,
        distanceMeters: 12345,
        cleanedDistanceMeters: 12010,
        acceptedPointCount: 2,
        rejectedPointCount: 0,
        segmentCount: 1,
        recording: const Duration(minutes: 112),
        moving: const Duration(minutes: 95),
        stopped: const Duration(minutes: 17),
        stopCount: 3,
        stepCount: 4321,
        qualityEventCount: 4,
        visibleGapCount: 1,
        stopEvidenceRunCount: 2,
        stopsSource: TrackStopSource.recorded,
        updatedAt: track.startedAt,
      ),
    );
    expect(routeStats(totals, cleaned: true), const <RouteStat>[
      RouteStat('12.35 km', 'Distance', note: 'cleaned ≈ 12.01 km'),
      RouteStat('1 h 35 min', 'Moving'),
      RouteStat('17 min', 'Stopped'),
      RouteStat('4321', 'Steps'),
    ]);
    expect(
      routeStats(totals, cleaned: false).first,
      const RouteStat('12.35 km', 'Distance'),
    );
    final withTotals = RouteGeometry.fromReport(
      const RouteGeometryAssembler().assemble(
        sourceParts: <RouteGeometrySourcePart>[
          for (final segment in <TrackSegmentWithPoints>[
            _segment(track, 1, const <(double, double)>[(0, 0), (0.001, 0)]),
          ])
            RouteGeometrySourcePart(
              legNumber: 1,
              segment: segment.segment,
              points: segment.points,
            ),
        ],
      ),
      totals: totals,
    );
    expect(
      routeHeadline(withTotals),
      '2 points • 3 stop(s) • 1 drawable part(s) • 4 quality event(s) • '
      '1 visible gap(s)',
      reason: 'the stop count is the stored one',
    );
  });

  test('a tapped stop says how long it lasted and when', () {
    final closed = RouteStopMarker(
      coordinate: const maplibre.LatLng(0.5, 0.5),
      startedAt: DateTime(2026, 10, 19, 10, 5),
      endedAt: DateTime(2026, 10, 19, 11, 17),
    );
    expect(describeStop(closed), 'Stopped 1 h 12 min, 10:05–11:17');
    final current = RouteStopMarker(
      coordinate: const maplibre.LatLng(0.5, 0.5),
      startedAt: DateTime(2026, 10, 19, 9, 58),
      endedAt: DateTime(2026, 10, 19, 10, 1),
      current: true,
    );
    expect(describeStop(current), 'Stopped 3 min so far, since 09:58');
  });

  testWidgets('a Trip card shows its stops and the time stopped', (
    tester,
  ) async {
    Trip trip(String id) => Trip(
      id: id,
      organizationId: 'example-organization',
      userId: 'example-user',
      routeId: id,
      status: TripStatus.completed,
      startedAt: DateTime.utc(2026),
      endedAt: DateTime.utc(2026, 1, 1, 2),
      legCount: 1,
      acceptedPointCount: 20,
      rejectedPointCount: 40,
      measuredDistanceMeters: 1234,
      lifecycleRevision: 2,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026, 1, 1, 2),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordedTripsSection(
            trips: <RecordedTripSummary>[
              RecordedTripSummary(
                trip: trip('with_stops'),
                totals: const RouteTotals(
                  distanceMeters: 1234,
                  displayDistanceMeters: 1234,
                  segmentCount: 1,
                  moving: Duration(minutes: 95),
                  stopped: Duration(minutes: 17),
                  stopCount: 2,
                  stepCount: 4321,
                  qualityEventCount: 3,
                  visibleGapCount: 1,
                ),
              ),
              RecordedTripSummary(trip: trip('without_totals')),
            ],
            hasMore: false,
            onLoadMore: null,
            onViewMap: null,
            onContinue: null,
            onExport: null,
            onDelete: null,
          ),
        ),
      ),
    );
    expect(find.text('2 stops'), findsOneWidget);
    expect(find.text('17 min'), findsOneWidget);
    expect(find.text('Moving'), findsOneWidget, reason: 'one card has totals');
    expect(find.text('1 h 35 min'), findsOneWidget);
    expect(find.text('4321 steps'), findsOneWidget);
    expect(find.text('3 quality event(s) • 1 visible gap(s)'), findsOneWidget);
  });

  testWidgets('a clean build leaves quality events and gaps off Trip cards', (
    tester,
  ) async {
    final trip = Trip(
      id: 'clean',
      organizationId: 'example-organization',
      userId: 'example-user',
      routeId: 'clean',
      status: TripStatus.completed,
      startedAt: DateTime.utc(2026),
      endedAt: DateTime.utc(2026, 1, 1, 2),
      legCount: 1,
      acceptedPointCount: 20,
      rejectedPointCount: 40,
      measuredDistanceMeters: 1234,
      lifecycleRevision: 2,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026, 1, 1, 2),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordedTripsSection(
            trips: <RecordedTripSummary>[
              RecordedTripSummary(
                trip: trip,
                totals: const RouteTotals(
                  distanceMeters: 1234,
                  displayDistanceMeters: 1234,
                  segmentCount: 1,
                  moving: Duration(minutes: 95),
                  stopped: Duration(minutes: 17),
                  stopCount: 2,
                  qualityEventCount: 0,
                  visibleGapCount: 0,
                ),
              ),
            ],
            hasMore: false,
            onLoadMore: null,
            onViewMap: null,
            onContinue: null,
            onExport: null,
            onDelete: null,
            onExportDiagnostics: (_) async {},
            showDiagnostics: false,
          ),
        ),
      ),
    );
    expect(find.text('2 stops'), findsOneWidget);
    expect(find.textContaining('quality event'), findsNothing);
    expect(find.textContaining('visible gap'), findsNothing);

    await tester.tap(find.byTooltip('Trip actions'));
    await tester.pumpAndSettle();
    expect(find.text('Export GPX'), findsOneWidget);
    expect(find.text('Export diagnostic GeoJSON'), findsNothing);
  });

  testWidgets('a clean build keeps capture diagnostics off the status card', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TrackingStatusCard(session: null, showDiagnostics: false),
        ),
      ),
    );
    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Uncertainty'), findsOneWidget);
    for (final label in <String>[
      'Confidence',
      'Motion',
      'Profile',
      'Fix',
      'Sequence',
      'Mock',
    ]) {
      expect(find.text(label), findsNothing, reason: label);
    }
  });

  testWidgets('a route card shows its stored details', (tester) async {
    final track = _completedTrack();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecordedTracksSection(
            tracks: <Track>[track],
            totals: const <String, RouteTotals>{
              'track-1': RouteTotals(
                distanceMeters: 100,
                displayDistanceMeters: 100,
                segmentCount: 1,
                moving: Duration(minutes: 40),
                stopped: Duration(minutes: 20),
                stopCount: 1,
                qualityEventCount: 0,
                visibleGapCount: 0,
              ),
            },
            hasMore: false,
            onLoadMore: null,
            onViewMap: null,
            onExport: null,
            onDelete: null,
          ),
        ),
      ),
    );
    expect(find.text('40 min'), findsOneWidget);
    expect(find.text('1 stop'), findsOneWidget);
    expect(find.text('20 min'), findsOneWidget);
    expect(
      find.textContaining('steps'),
      findsNothing,
      reason: 'steps not counted',
    );
  });
}

/// Points [spacing] seconds apart, [east] metres east of a synthetic origin.
TrackSegmentWithPoints _timedSegment(
  Track track,
  List<double> east, {
  required int spacing,
  required double accuracy,
}) {
  const metersPerDegree = 111195.07973436875;
  final base = _segment(track, 1, <(double, double)>[
    for (final meters in east)
      (0.5, 0.5 + meters / (metersPerDegree * 0.99996192)),
  ]);
  return TrackSegmentWithPoints(
    segment: base.segment,
    points: <TrackPoint>[
      for (var index = 0; index < base.points.length; index += 1)
        TrackPoint(
          id: base.points[index].id,
          trackId: track.id,
          segmentId: base.segment.id,
          sequence: index + 1,
          latitude: base.points[index].latitude,
          longitude: base.points[index].longitude,
          capturedAt: track.startedAt.add(Duration(seconds: index * spacing)),
          persistedAt: track.startedAt.add(Duration(seconds: index * spacing)),
          activityType: TrackingActivityType.unknown,
          activityConfidence: 40,
          motionState: MotionState.moving,
          isMocked: false,
          mockDetectionAvailable: true,
          accepted: true,
          qualityFlags: 0,
          horizontalAccuracy: accuracy,
        ),
    ],
  );
}

Track _completedTrack({int segmentCount = 1}) => Track(
  id: 'track-1',
  userId: 'example-user',
  organizationId: 'example-organization',
  routeId: 'route_1',
  status: TrackStatus.completed,
  startedAt: DateTime.utc(2026),
  endedAt: DateTime.utc(2026, 1, 1, 1),
  totalDistanceMeters: 100,
  acceptedPointCount: segmentCount * 2,
  rejectedPointCount: 0,
  segmentCount: segmentCount,
  nextSequence: segmentCount * 2 + 1,
  currentSegmentId: null,
  config: const TrackingConfig(),
);

TrackSegmentWithPoints _segment(
  Track track,
  int number,
  List<(double, double)> coordinates,
) {
  final segmentId = '${track.id}-segment-$number';
  return TrackSegmentWithPoints(
    segment: TrackSegment(
      id: segmentId,
      trackId: track.id,
      segmentNumber: number,
      status: TrackSegmentStatus.completed,
      startedAt: track.startedAt,
      endedAt: track.endedAt,
      distanceMeters: 50,
      acceptedPointCount: coordinates.length,
    ),
    points: <TrackPoint>[
      for (var index = 0; index < coordinates.length; index += 1)
        TrackPoint(
          id: '$segmentId-point-$index',
          trackId: track.id,
          segmentId: segmentId,
          sequence: (number - 1) * coordinates.length + index + 1,
          latitude: coordinates[index].$1,
          longitude: coordinates[index].$2,
          capturedAt: track.startedAt.add(Duration(seconds: index)),
          persistedAt: track.startedAt.add(Duration(seconds: index)),
          activityType: TrackingActivityType.walking,
          activityConfidence: 90,
          motionState: MotionState.moving,
          isMocked: false,
          mockDetectionAvailable: true,
          accepted: true,
          qualityFlags: 0,
        ),
    ],
  );
}

/// Lists Trips the way the route database does: only those whose status the
/// query asks for.
final class _OpenTrips implements MultiDayTripController {
  _OpenTrips(this.trips);

  final List<Trip> trips;

  @override
  Future<TripPage> listTripPage(TripQuery query) async => TripPage(
    items: trips.where((trip) => query.statuses.contains(trip.status)),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
