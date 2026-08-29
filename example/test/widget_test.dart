import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_background_location_tracker_example/main.dart';
import 'package:flutter_background_location_tracker_example/recorded_tracks_section.dart';
import 'package:flutter_background_location_tracker_example/route_map_page.dart';
import 'package:flutter_test/flutter_test.dart';

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
