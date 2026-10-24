import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker_example/recorded_tracks_section.dart';
import 'package:flutter_background_location_tracker_example/recorded_trips_section.dart';
import 'package:flutter_background_location_tracker_example/route_map_page.dart';
import 'package:flutter_background_location_tracker_example/route_totals.dart';
import 'package:flutter_test/flutter_test.dart';

// What the example shows for routes recorded under older rules and reviewed
// since: the corrected distance, incomplete step counts and the reviewed
// route on the map. All values come from the package; coordinates are
// synthetic offsets east of (0.5, 0.5).

void main() {
  // The step counter stopped at 08:51 on the device's clock.
  final stoppedAt = DateTime(2026, 10, 24, 8, 51);

  group('history cards', () {
    testWidgets('a route card shows the corrected distance, no point count', (
      tester,
    ) async {
      final reviewed = _track('track-1', distanceMeters: 1777);
      final unsummarised = _track('track-2', distanceMeters: 2500);
      await tester.pumpWidget(
        _app(
          RecordedTracksSection(
            tracks: <Track>[reviewed, unsummarised],
            totals: <String, RouteTotals>{
              reviewed.id: RouteTotals.ofRoute(
                _summary(distanceMeters: 1777, correctedDistanceMeters: 1490),
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
      );

      expect(find.text('1.49 km'), findsOneWidget);
      expect(
        find.text('1.78 km'),
        findsNothing,
        reason: 'the measured distance is a route detail',
      );
      expect(
        find.text('2.50 km'),
        findsOneWidget,
        reason: 'without stored totals, the route\'s own distance',
      );
      expect(find.textContaining('points'), findsNothing);
      expect(find.byIcon(Icons.pin_drop_outlined), findsNothing);
    });

    testWidgets('a Trip card shows the corrected distance, no point count', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          RecordedTripsSection(
            trips: <RecordedTripSummary>[
              RecordedTripSummary(
                trip: _trip('reviewed', distanceMeters: 1777),
                totals: RouteTotals.ofTrip(
                  _tripSummary(
                    distanceMeters: 1777,
                    correctedDistanceMeters: 1490,
                  ),
                ),
              ),
              RecordedTripSummary(
                trip: _trip('unsummarised', distanceMeters: 2500),
              ),
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
      );

      expect(find.text('1.49 km'), findsOneWidget);
      expect(find.text('1.78 km'), findsNothing);
      expect(find.text('2.50 km'), findsOneWidget);
      expect(find.textContaining('points'), findsNothing);
      expect(find.byIcon(Icons.pin_drop_outlined), findsNothing);
    });

    testWidgets('incomplete steps say when the counter stopped', (
      tester,
    ) async {
      final incomplete = _track('track-1', distanceMeters: 1777);
      final complete = _track('track-2', distanceMeters: 1463);
      await tester.pumpWidget(
        _app(
          ListView(
            children: <Widget>[
              RecordedTracksSection(
                tracks: <Track>[incomplete, complete],
                totals: <String, RouteTotals>{
                  incomplete.id: RouteTotals.ofRoute(
                    _summary(
                      distanceMeters: 1777,
                      stepCount: 167,
                      stepCountStoppedAt: stoppedAt.toUtc(),
                    ),
                  ),
                  complete.id: RouteTotals.ofRoute(
                    _summary(distanceMeters: 1463, stepCount: 2175),
                  ),
                },
                hasMore: false,
                onRefresh: null,
                onLoadMore: null,
                onViewMap: null,
                onExport: null,
                onDelete: null,
              ),
              RecordedTripsSection(
                trips: <RecordedTripSummary>[
                  RecordedTripSummary(
                    trip: _trip('incomplete', distanceMeters: 1777),
                    totals: RouteTotals.ofTrip(
                      _tripSummary(
                        distanceMeters: 1777,
                        stepCount: 167,
                        stepCountStoppedAt: stoppedAt.toUtc(),
                      ),
                    ),
                  ),
                ],
                hasMore: false,
                onRefresh: null,
                onLoadMore: null,
                onViewMap: null,
                onContinue: null,
                onExport: null,
                onDelete: null,
              ),
            ],
          ),
        ),
      );

      expect(
        find.text('≥ 167 steps · counter stopped at 08:51'),
        findsNWidgets(2),
      );
      expect(find.text('167 steps'), findsNothing, reason: 'a lower bound');
      expect(find.text('2175 steps'), findsOneWidget);
    });
  });

  group('route details', () {
    test('steps are a lower bound once the counter stopped', () {
      expect(stepsLabel(4321), '4321 steps');
      expect(
        stepsLabel(167, stoppedAt: stoppedAt),
        '≥ 167 steps · counter stopped at 08:51',
      );
      expect(
        stepsLabel(167, stoppedAt: stoppedAt.toUtc()),
        '≥ 167 steps · counter stopped at 08:51',
        reason: 'stored in UTC, shown on the device\'s clock',
      );
      expect(
        stepsLabel(20, stoppedAt: DateTime(2026, 10, 24, 21, 5)),
        '≥ 20 steps · counter stopped at 21:05',
      );
      expect(
        RouteTotals.ofRoute(
          _summary(
            distanceMeters: 1777,
            stepCount: 514,
            stepCountStoppedAt: stoppedAt.toUtc(),
          ),
        ).stepsText,
        '≥ 514 steps · counter stopped at 08:51',
      );
      expect(
        RouteTotals.ofRoute(_summary(distanceMeters: 1777)).stepsText,
        isNull,
        reason: 'steps not counted',
      );
    });

    testWidgets('the corrected distance leads, the recorded one follows', (
      tester,
    ) async {
      final track = _track('track-1', distanceMeters: 1777);
      final route = RouteGeometry.fromReport(
        const RouteGeometryAssembler().assemble(
          sourceParts: _parts(
            _bundle(track, const <double>[0, 25, 50]),
            legNumber: 1,
          ),
        ),
        totals: RouteTotals.ofRoute(
          _summary(
            distanceMeters: 1777,
            correctedDistanceMeters: 1490,
            stepCount: 167,
            stepCountStoppedAt: stoppedAt.toUtc(),
          ),
        ),
      );
      RouteView? picked;
      await tester.pumpWidget(
        _app(
          RouteMapHeader(
            content: RouteMapContent(
              route: route,
              view: RouteView.reviewed,
              views: const <RouteView>[
                RouteView.reviewed,
                RouteView.cleaned,
                RouteView.raw,
              ],
            ),
            continuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
            onContinuityChanged: (_) {},
            onViewChanged: (view) => picked = view,
          ),
        ),
      );

      expect(
        find.text(
          '3 points • 2 stop(s) • 1 drawable part(s) • 0 quality event(s) • '
          '0 visible gap(s)',
        ),
        findsOneWidget,
        reason: 'the point count and the stored stop count',
      );
      expect(find.text('Distance 1.49 km'), findsOneWidget);
      expect(find.text('recorded 1.78 km'), findsOneWidget);
      expect(
        find.text(
          'Moving 40 min • stopped 20 min • '
          '≥ 167 steps · counter stopped at 08:51',
        ),
        findsOneWidget,
      );
      final selector = tester.widget<SegmentedButton<RouteView>>(
        find.byType(SegmentedButton<RouteView>),
      );
      expect(selector.selected, <RouteView>{RouteView.reviewed});

      await tester.tap(find.text('Raw'));
      await tester.pump();
      expect(picked, RouteView.raw);
    });

    test('the recorded distance shows only when it differs as shown', () {
      List<String> lines({double? corrected}) => routeTotalsLines(
        RouteTotals.ofRoute(
          _summary(distanceMeters: 1777, correctedDistanceMeters: corrected),
        ),
        cleaned: false,
      );

      expect(lines(corrected: 1490), <String>[
        'Distance 1.49 km',
        'recorded 1.78 km',
        'Moving 40 min • stopped 20 min',
      ]);
      expect(lines(), <String>[
        'Distance 1.78 km',
        'Moving 40 min • stopped 20 min',
      ], reason: 'not reviewed');
      expect(lines(corrected: 1776.8), <String>[
        'Distance 1.78 km',
        'Moving 40 min • stopped 20 min',
      ], reason: 'reviewed, with the same distance as shown');
    });
  });

  group('map', () {
    test('only a completed review is the reviewed route', () {
      DerivedGeometryRun run(
        String id, {
        String algorithm = DerivedGeometryAlgorithm.routeQualityReview,
        DerivedGeometryRunStatus status = DerivedGeometryRunStatus.completed,
        int minute = 0,
      }) => DerivedGeometryRun(
        id: id,
        trackId: 'track-1',
        name: id,
        algorithm: algorithm,
        algorithmVersion: '1',
        configuration: const <String, Object?>{},
        sourceMaximumSequence: 6,
        status: status,
        createdAt: DateTime.utc(2026, 10, 24, 9, minute),
      );

      expect(currentReviewRun(const <DerivedGeometryRun>[]), isNull);
      expect(
        currentReviewRun(<DerivedGeometryRun>[
          run(
            'cleaned',
            algorithm: DerivedGeometryAlgorithm.stopAwareRouteCleaning,
          ),
          run('failed', status: DerivedGeometryRunStatus.failed),
          run('processing', status: DerivedGeometryRunStatus.processing),
        ]),
        isNull,
      );
      expect(
        currentReviewRun(<DerivedGeometryRun>[
          run('older', minute: 1),
          run('newer', minute: 2),
          run(
            'cleaned',
            algorithm: DerivedGeometryAlgorithm.stopAwareRouteCleaning,
            minute: 3,
          ),
        ])?.id,
        'newer',
      );
    });

    test(
      'a reviewed route is drawn as reviewed, the recorded one a tap away',
      () async {
        final tracking = _ReviewedRouteTracking.example();

        final reviewed = await loadTrackMap(
          tracking,
          'track-1',
          continuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
        );
        expect(reviewed.view, RouteView.reviewed);
        expect(reviewed.views, <RouteView>[
          RouteView.reviewed,
          RouteView.cleaned,
          RouteView.raw,
        ]);
        expect(
          reviewed.route.points.map((point) => point.longitude),
          _atLongitudes(<double>[
            for (final index in <int>[0, 1, 3, 4, 5])
              _ReviewedRouteTracking.east[index],
          ]),
          reason: 'the fixes the review keeps',
        );
        expect(reviewed.route.stopMarkers, hasLength(1));
        expect(
          reviewed.route.gapMarkers,
          hasLength(1),
          reason: 'only the gap stored as visible',
        );
        expect(
          routeHeadline(reviewed.route),
          '5 points • 1 stop(s) • 1 drawable part(s) • 0 quality event(s) • '
          '1 visible gap(s)',
        );
        expect(
          routeTotalsLines(reviewed.route.totals, cleaned: false),
          <String>[
            'Distance 1.49 km',
            'recorded 1.78 km',
            'Moving 40 min • stopped 20 min',
          ],
        );

        final recorded = await loadTrackMap(
          tracking,
          'track-1',
          continuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
          view: RouteView.raw,
        );
        expect(recorded.view, RouteView.raw);
        expect(
          recorded.route.points.map((point) => point.longitude),
          _atLongitudes(<double>[
            for (final index in <int>[0, 1, 2, 3])
              _ReviewedRouteTracking.east[index],
          ]),
          reason: 'the fixes accepted while recording',
        );
        expect(recorded.route.stopMarkers, hasLength(1));

        final cleaned = await loadTrackMap(
          tracking,
          'track-1',
          continuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
          view: RouteView.cleaned,
        );
        expect(cleaned.view, RouteView.cleaned);
        expect(cleaned.route.pointCount, 4);
      },
    );

    test('a route without a review opens in its cleaned view', () async {
      final tracking = _ReviewedRouteTracking.example(withReview: false);

      final content = await loadTrackMap(
        tracking,
        'track-1',
        continuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
        view: RouteView.reviewed,
      );

      expect(content.views, <RouteView>[RouteView.cleaned, RouteView.raw]);
      expect(content.view, RouteView.cleaned);
    });

    test(
      'a Trip draws reviewed days as reviewed, the others as recorded',
      () async {
        final tracking = _ReviewedTripTracking.example();

        final reviewed = await loadTripMap(
          tracking,
          'trip-1',
          continuity: RouteGeometryContinuity.preserveEvidenceSegments,
        );
        expect(reviewed.view, RouteView.reviewed);
        expect(
          reviewed.route.points.map((point) => point.longitude),
          _atLongitudes(const <double>[0, 25, 75, 1000, 1025, 1050]),
          reason: 'day 1 as reviewed, day 2 as recorded',
        );
        expect(reviewed.route.geometryPartCount, 2);
        expect(reviewed.route.stopMarkers, hasLength(1));
        expect(
          routeTotalsLines(reviewed.route.totals, cleaned: false).take(2),
          <String>['Distance 2.49 km', 'recorded 2.78 km'],
        );

        final recorded = await loadTripMap(
          tracking,
          'trip-1',
          continuity: RouteGeometryContinuity.preserveEvidenceSegments,
          view: RouteView.raw,
        );
        expect(recorded.view, RouteView.raw);
        expect(recorded.route.pointCount, 7);
      },
    );
  });
}

Widget _app(Widget body) => MaterialApp(home: Scaffold(body: body));

const _metersPerDegree = 111195.07973436875;

/// Longitude [meters] east of the synthetic origin (0.5, 0.5).
double _longitude(double meters) =>
    0.5 + meters / (_metersPerDegree * 0.99996192);

/// Matches the longitudes of fixes [east] metres east of the origin, within
/// the rounding of the map's longitude normalisation.
List<Matcher> _atLongitudes(List<double> east) => <Matcher>[
  for (final meters in east) closeTo(_longitude(meters), 1e-9),
];

Track _track(String id, {required double distanceMeters}) => Track(
  id: id,
  userId: 'example-user',
  organizationId: 'example-organization',
  routeId: id,
  status: TrackStatus.completed,
  startedAt: DateTime.utc(2026, 10, 24, 2),
  endedAt: DateTime.utc(2026, 10, 24, 3),
  totalDistanceMeters: distanceMeters,
  acceptedPointCount: 178,
  rejectedPointCount: 12,
  segmentCount: 1,
  nextSequence: 191,
  currentSegmentId: null,
  config: const TrackingConfig(),
);

Trip _trip(String id, {required double distanceMeters}) => Trip(
  id: id,
  organizationId: 'example-organization',
  userId: 'example-user',
  routeId: id,
  status: TripStatus.completed,
  startedAt: DateTime.utc(2026, 10, 24, 2),
  endedAt: DateTime.utc(2026, 10, 24, 3),
  legCount: 1,
  acceptedPointCount: 178,
  rejectedPointCount: 12,
  measuredDistanceMeters: distanceMeters,
  lifecycleRevision: 2,
  createdAt: DateTime.utc(2026, 10, 24, 2),
  updatedAt: DateTime.utc(2026, 10, 24, 3),
);

RouteSummary _summary({
  required double distanceMeters,
  double? correctedDistanceMeters,
  int? stepCount,
  DateTime? stepCountStoppedAt,
  int stopCount = 2,
  int visibleGapCount = 0,
}) => RouteSummary(
  trackId: 'track-1',
  startedAt: DateTime.utc(2026, 10, 24, 2),
  endedAt: DateTime.utc(2026, 10, 24, 3),
  distanceMeters: distanceMeters,
  correctedDistanceMeters: correctedDistanceMeters,
  acceptedPointCount: 178,
  rejectedPointCount: 12,
  segmentCount: 1,
  recording: const Duration(hours: 1),
  moving: const Duration(minutes: 40),
  stopped: const Duration(minutes: 20),
  stopCount: stopCount,
  stepCount: stepCount,
  stepCountStoppedAt: stepCountStoppedAt,
  qualityEventCount: 0,
  visibleGapCount: visibleGapCount,
  stopEvidenceRunCount: 0,
  stopsSource: TrackStopSource.recorded,
  updatedAt: DateTime.utc(2026, 10, 24, 3),
);

TripSummary _tripSummary({
  required double distanceMeters,
  double? correctedDistanceMeters,
  int? stepCount,
  DateTime? stepCountStoppedAt,
  int legCount = 1,
  int stopCount = 2,
}) => TripSummary(
  tripId: 'trip-1',
  startedAt: DateTime.utc(2026, 10, 24, 2),
  endedAt: DateTime.utc(2026, 10, 24, 3),
  legCount: legCount,
  distanceMeters: distanceMeters,
  correctedDistanceMeters: correctedDistanceMeters,
  acceptedPointCount: 178,
  rejectedPointCount: 12,
  segmentCount: legCount,
  recording: const Duration(hours: 1),
  moving: const Duration(minutes: 40),
  stopped: const Duration(minutes: 20),
  stopCount: stopCount,
  stepCount: stepCount,
  stepCountStoppedAt: stepCountStoppedAt,
  qualityEventCount: 0,
  visibleGapCount: 0,
  stopEvidenceRunCount: 0,
  updatedAt: DateTime.utc(2026, 10, 24, 3),
);

/// One segment of fixes [east] metres east of the origin, 10 s apart; the
/// fixes at [rejected] indexes are not accepted.
TrackBundle _bundle(
  Track track,
  List<double> east, {
  Set<int> rejected = const <int>{},
  List<TrackStop> stops = const <TrackStop>[],
}) {
  final segmentId = '${track.id}-segment-1';
  return TrackBundle(
    track: track,
    stops: stops,
    segments: <TrackSegmentWithPoints>[
      TrackSegmentWithPoints(
        segment: TrackSegment(
          id: segmentId,
          trackId: track.id,
          segmentNumber: 1,
          status: TrackSegmentStatus.completed,
          startedAt: track.startedAt,
          endedAt: track.endedAt,
          distanceMeters: 0,
          acceptedPointCount: east.length - rejected.length,
        ),
        points: <TrackPoint>[
          for (var index = 0; index < east.length; index += 1)
            TrackPoint(
              id: _pointId(track.id, index),
              trackId: track.id,
              segmentId: segmentId,
              sequence: index + 1,
              latitude: 0.5,
              longitude: _longitude(east[index]),
              capturedAt: track.startedAt.add(Duration(seconds: index * 10)),
              persistedAt: track.startedAt.add(Duration(seconds: index * 10)),
              activityType: TrackingActivityType.walking,
              activityConfidence: 90,
              motionState: MotionState.moving,
              isMocked: false,
              mockDetectionAvailable: true,
              accepted: !rejected.contains(index),
              qualityFlags: 0,
              horizontalAccuracy: 5,
              rejectionReason: rejected.contains(index)
                  ? 'synthetic_rejection'
                  : null,
            ),
        ],
      ),
    ],
  );
}

String _pointId(String trackId, int index) => '$trackId-segment-1-point-$index';

Iterable<RouteGeometrySourcePart> _parts(
  TrackBundle bundle, {
  required int legNumber,
}) => bundle.segments.map(
  (segment) => RouteGeometrySourcePart(
    legNumber: legNumber,
    segment: segment.segment,
    points: segment.points,
  ),
);

TrackStop _stop(Track track, int index) => TrackStop(
  id: '${track.id}-stop-$index',
  trackId: track.id,
  segmentId: '${track.id}-segment-1',
  kind: TrackStopKind.dwell,
  latitude: 0.5,
  longitude: _longitude(0),
  centreSigmaMeters: 2,
  radiusMeters: 25,
  startedAt: track.startedAt,
  lastSeenAt: track.startedAt.add(const Duration(minutes: 3)),
  endedAt: track.startedAt.add(const Duration(minutes: 3)),
  evidenceCount: 12,
  qualityPolicyVersion: 4,
);

DerivedGeometryRun _run(
  String id,
  String trackId,
  String algorithm, {
  int sourceMaximumSequence = 6,
}) => DerivedGeometryRun(
  id: id,
  trackId: trackId,
  name: id,
  algorithm: algorithm,
  algorithmVersion: '1',
  configuration: const <String, Object?>{},
  sourceMaximumSequence: sourceMaximumSequence,
  status: DerivedGeometryRunStatus.completed,
  createdAt: DateTime.utc(2026, 10, 24, 4),
);

/// A route recorded under older rules as the facade returns it: [recorded]
/// as stored and, once reviewed, [reviewed] with the fixes the review keeps.
final class _ReviewedRouteTracking
    implements
        TrackingController,
        TrackingGeometryController,
        TrackingSummaryController,
        TrackingStopController {
  _ReviewedRouteTracking({
    required this.recorded,
    required this.reviewed,
    required this.runs,
    required this.summary,
    required this.gaps,
  });

  /// A walk whose third fix is a spike accepted while recording, and whose
  /// last two fixes were rejected then; the review keeps the others.
  factory _ReviewedRouteTracking.example({bool withReview = true}) {
    final track = _track('track-1', distanceMeters: 1777);
    final stops = <TrackStop>[_stop(track, 1)];
    TrackingContinuityGap gap(int before, int after, {required bool visible}) =>
        TrackingContinuityGap(
          id: 'gap-$before-$after',
          trackId: track.id,
          beforePointId: _pointId(track.id, before),
          afterPointId: _pointId(track.id, after),
          beforeSegmentId: '${track.id}-segment-1',
          afterSegmentId: '${track.id}-segment-1',
          cause: TrackingGapCause.providerBatching,
          treatment: TrackingGapTreatment.retainCurrentSegment,
          distanceTreatment: TrackingGapDistanceTreatment.measured,
          continuityPolicyVersion: 4,
          providerGap: const Duration(seconds: 90),
          createdAt: track.endedAt!,
          visible: visible,
        );
    return _ReviewedRouteTracking(
      recorded: _bundle(track, east, rejected: const <int>{4, 5}, stops: stops),
      reviewed: _bundle(track, east, rejected: const <int>{2}, stops: stops),
      runs: <DerivedGeometryRun>[
        _run(
          'cleaned',
          track.id,
          DerivedGeometryAlgorithm.stopAwareRouteCleaning,
        ),
        if (withReview)
          _run('review', track.id, DerivedGeometryAlgorithm.routeQualityReview),
      ],
      summary: _summary(
        distanceMeters: 1777,
        correctedDistanceMeters: withReview ? 1490 : null,
        stopCount: 1,
        visibleGapCount: 1,
      ),
      gaps: <TrackingContinuityGap>[
        // The stored decisions: a 90 s gap is a hole only when stored so.
        gap(0, 1, visible: false),
        gap(1, 3, visible: true),
      ],
    );
  }

  static const east = <double>[0, 25, 400, 75, 100, 125];

  final TrackBundle recorded;
  final TrackBundle reviewed;
  final List<DerivedGeometryRun> runs;
  final RouteSummary summary;
  final List<TrackingContinuityGap> gaps;

  @override
  Future<List<TrackStop>> listTrackStops(String trackId) async =>
      recorded.stops;

  @override
  Future<List<DerivedGeometryRun>> listDerivedGeometry(String trackId) async =>
      runs;

  @override
  Future<RouteGeometryReport> assembleTrackRouteGeometry(
    String trackId, {
    RouteGeometryContinuity continuity =
        RouteGeometryContinuity.mergeAutomaticCallbackGaps,
  }) async => const RouteGeometryAssembler().assemble(
    sourceParts: _parts(recorded, legNumber: 1),
    gaps: gaps,
    continuity: continuity,
  );

  @override
  Future<TrackBundle> loadTrackGeometry(
    String trackId, {
    TrackGeometrySelection geometry = const TrackGeometrySelection.raw(),
  }) async => geometry is DerivedTrackGeometry && geometry.runId == 'review'
      ? reviewed
      // The cleaned view keeps the recorded positions here.
      : recorded;

  @override
  Future<DerivedGeometryRun> currentCleanedGeometry(String trackId) async =>
      runs.first;

  @override
  Future<RouteSummary> routeSummary(String trackId) async => summary;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A two-day Trip whose first day was recorded under older rules and
/// reviewed, and whose second day needed no review.
final class _ReviewedTripTracking
    implements
        MultiDayTripController,
        TrackingGeometryController,
        TrackingSummaryController,
        TrackingStopController {
  _ReviewedTripTracking({
    required this.trip,
    required this.days,
    required this.reviewedDays,
    required this.summary,
  });

  factory _ReviewedTripTracking.example() {
    final first = _track('track-1', distanceMeters: 1777);
    final second = _track('track-2', distanceMeters: 1000);
    return _ReviewedTripTracking(
      trip: _trip('trip-1', distanceMeters: 2777),
      days: <TrackBundle>[
        _bundle(
          first,
          const <double>[0, 25, 400, 75],
          stops: <TrackStop>[_stop(first, 1)],
        ),
        _bundle(second, const <double>[1000, 1025, 1050]),
      ],
      reviewedDays: <String, TrackBundle>{
        first.id: _bundle(
          first,
          const <double>[0, 25, 400, 75],
          rejected: const <int>{2},
          stops: <TrackStop>[_stop(first, 1)],
        ),
      },
      summary: _tripSummary(
        distanceMeters: 2777,
        correctedDistanceMeters: 2490,
        legCount: 2,
        stopCount: 1,
      ),
    );
  }

  final Trip trip;

  /// Each day as recorded, in order.
  final List<TrackBundle> days;

  /// The reviewed days, by track ID.
  final Map<String, TrackBundle> reviewedDays;
  final TripSummary summary;

  TrackBundle _day(String trackId) =>
      days.firstWhere((day) => day.track.id == trackId);

  @override
  Future<TripBundle> loadTripBundle(String tripId) async => TripBundle(
    trip: trip,
    legs: <TripLeg>[
      for (final (index, day) in days.indexed)
        TripLeg(
          tripId: trip.id,
          trackId: day.track.id,
          legNumber: index + 1,
          startedAt: day.track.startedAt,
          trackStatus: day.track.status,
        ),
    ],
    gaps: const <TrackingContinuityGap>[],
  );

  @override
  Future<List<TrackStop>> listTripStops(String tripId) async => <TrackStop>[
    for (final day in days) ...day.stops,
  ];

  @override
  Future<List<DerivedGeometryRun>> listDerivedGeometry(String trackId) async =>
      <DerivedGeometryRun>[
        if (reviewedDays.containsKey(trackId))
          _run(
            'review-$trackId',
            trackId,
            DerivedGeometryAlgorithm.routeQualityReview,
          ),
      ];

  @override
  Future<TrackBundle> loadTrackGeometry(
    String trackId, {
    TrackGeometrySelection geometry = const TrackGeometrySelection.raw(),
  }) async =>
      geometry is DerivedTrackGeometry ? reviewedDays[trackId]! : _day(trackId);

  @override
  Future<RouteGeometryReport> assembleTripRouteGeometry(
    String tripId, {
    RouteGeometryContinuity? continuity,
  }) async => const RouteGeometryAssembler().assemble(
    sourceParts: <RouteGeometrySourcePart>[
      for (final (index, day) in days.indexed)
        ..._parts(day, legNumber: index + 1),
    ],
    continuity: continuity ?? RouteGeometryContinuity.preserveEvidenceSegments,
  );

  @override
  Future<TripSummary> tripSummary(String tripId) async => summary;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
