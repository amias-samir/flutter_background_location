import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_background_location_tracker_example/main.dart';
import 'package:flutter_background_location_tracker_example/recorded_tracks_section.dart';
import 'package:flutter_background_location_tracker_example/recorded_trips_section.dart';
import 'package:flutter_background_location_tracker_example/route_map_page.dart';
import 'package:flutter_background_location_tracker_example/route_totals.dart';
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

    await _scrollHome(tester, 500);

    final accuracySelector = find.byType(
      DropdownButtonFormField<TrackingAccuracy>,
    );
    await tester.ensureVisible(accuracySelector);
    await tester.pumpAndSettle();
    await tester.tap(accuracySelector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('precised').last);
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
    await _scrollHome(tester, 700);
    final batterySettings = find.widgetWithText(
      OutlinedButton,
      'Battery settings',
    );
    await tester.ensureVisible(batterySettings);
    await tester.pumpAndSettle();
    expect(batterySettings, findsOne);
  });

  testWidgets('start asks for a non-empty route identifier', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    await _scrollHome(tester, 1000);

    final start = find.widgetWithText(FilledButton, 'Start').first;
    await tester.ensureVisible(start);
    await tester.pumpAndSettle();
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

    await _scrollHome(tester, 1000);

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
            onRefresh: () async {},
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
            onRefresh: () async {},
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
    expect(routeTotalsLines(null, cleaned: true), isEmpty);

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
    expect(routeTotalsLines(totals, cleaned: true), <String>[
      'Distance 12.35 km • cleaned ≈ 12.01 km',
      'Moving 1 h 35 min • stopped 17 min • 4321 steps',
    ]);
    expect(routeTotalsLines(totals, cleaned: false).first, 'Distance 12.35 km');
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
            onRefresh: null,
            onLoadMore: null,
            onViewMap: null,
            onContinue: null,
            onExport: null,
            onDelete: null,
          ),
        ),
      ),
    );
    expect(find.text('2 stop(s) • 17 min'), findsOneWidget);
    expect(find.textContaining('stop(s)'), findsOneWidget);
    expect(find.text('Moving 1 h 35 min'), findsOneWidget);
    expect(find.text('4321 steps'), findsOneWidget);
    expect(find.text('3 quality event(s)'), findsOneWidget);
    expect(find.text('1 visible gap(s)'), findsOneWidget);
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
            onRefresh: null,
            onLoadMore: null,
            onViewMap: null,
            onExport: null,
            onDelete: null,
          ),
        ),
      ),
    );
    expect(find.text('Moving 40 min'), findsOneWidget);
    expect(find.text('1 stop(s) • 20 min'), findsOneWidget);
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

Future<void> _scrollHome(WidgetTester tester, double distance) async {
  await tester.drag(find.byType(ListView), Offset(0, -distance));
  await tester.pumpAndSettle();
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
