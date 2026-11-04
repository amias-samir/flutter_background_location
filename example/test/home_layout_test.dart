import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';
import 'package:flutter_background_location_tracker_example/main.dart';
import 'package:flutter_background_location_tracker_example/recorded_tracks_section.dart';
import 'package:flutter_background_location_tracker_example/tracking_controls.dart';
import 'package:flutter_test/flutter_test.dart';

// The home page shows the session, the preferences and the route controls
// on one screen; it scrolls only when it cannot fit.

void main() {
  const owner = TrackingOwner(
    userId: 'example-user',
    organizationId: 'example-organization',
  );

  Future<void> pumpHome(
    WidgetTester tester, {
    required Size size,
    double textScale = 1,
    FakeTrackingController? controller,
  }) async {
    tester.view
      ..physicalSize = size * 3
      ..devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final tracking = controller ?? FakeTrackingController(owner: owner);
    await tester.pumpWidget(
      TrackingExampleApp(controllerFactory: (_, _) async => tracking),
    );
    await tester.pumpAndSettle();
  }

  double homeScrollExtent(WidgetTester tester) => tester
      .state<ScrollableState>(
        find
            .descendant(
              of: find.byType(SingleChildScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      )
      .position
      .maxScrollExtent;

  // Tests run as a debug build, the densest home: every diagnostic shows.
  testWidgets('home fits 390×844 without scrolling', (tester) async {
    await pumpHome(tester, size: const Size(390, 844));

    expect(homeScrollExtent(tester), 0);
    expect(find.byType(TrackingStatusCard), findsOneWidget);
    expect(find.byType(TrackingConfigurationControls), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Start'), findsOneWidget);
    expect(find.text('Recorded routes · 0'), findsOneWidget);
  });

  testWidgets('a small phone shows the debug home without overflow', (
    tester,
  ) async {
    await pumpHome(tester, size: const Size(360, 640));

    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(FilledButton, 'Start'), findsOneWidget);
  });

  testWidgets('large text scrolls instead of overflowing', (tester) async {
    await pumpHome(tester, size: const Size(360, 640), textScale: 2);

    expect(tester.takeException(), isNull);
    expect(homeScrollExtent(tester), greaterThan(0));
  });

  testWidgets('preferences lock while a route is open', (tester) async {
    await pumpHome(
      tester,
      size: const Size(390, 844),
      controller: FakeTrackingController(owner: owner)
        ..seedInterruptedTrack(routeId: 'restored_route'),
    );

    expect(find.text('Locked while tracking'), findsOneWidget);
    await tester.tap(find.text('Accuracy'));
    await tester.pumpAndSettle();
    expect(find.text('Accuracy profile'), findsNothing);
  });

  testWidgets('the history tile opens the recorded routes', (tester) async {
    await pumpHome(tester, size: const Size(390, 844));

    await tester.tap(find.text('Recorded routes · 0'));
    await tester.pumpAndSettle();

    expect(find.byType(RecordedTracksSection), findsOneWidget);
    expect(find.text('No routes recorded yet'), findsOneWidget);
    expect(find.byTooltip('Refresh'), findsOneWidget);
  });

  group('route controls', () {
    Future<void> pumpPanel(
      WidgetTester tester, {
      bool canStart = false,
      bool canPause = false,
      bool canResume = false,
      bool canComplete = false,
      bool tripMode = false,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 328,
              child: TrackingActionPanel(
                canStart: canStart,
                canPause: canPause,
                canResume: canResume,
                canComplete: canComplete,
                canEndDay: tripMode && canComplete,
                tripMode: tripMode,
                onStart: () {},
                onPause: () {},
                onResume: () {},
                onComplete: () {},
                onEndDay: () {},
              ),
            ),
          ),
        ),
      ),
    );

    List<String> labels(WidgetTester tester) => <String>[
      for (final label in <String>[
        'Start',
        'Pause',
        'Resume',
        'End day',
        'Complete',
        'Complete Trip',
      ])
        if (find.text(label).evaluate().isNotEmpty) label,
    ];

    testWidgets('idle shows Start only', (tester) async {
      await pumpPanel(tester, canStart: true);
      expect(labels(tester), <String>['Start']);
    });

    testWidgets('nothing allowed shows a disabled Start', (tester) async {
      await pumpPanel(tester);
      expect(labels(tester), <String>['Start']);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'))
            .onPressed,
        isNull,
      );
    });

    testWidgets('tracking shows Pause and Complete', (tester) async {
      await pumpPanel(tester, canPause: true, canComplete: true);
      expect(labels(tester), <String>['Pause', 'Complete']);
    });

    testWidgets('paused shows Resume and Complete', (tester) async {
      await pumpPanel(tester, canResume: true, canComplete: true);
      expect(labels(tester), <String>['Resume', 'Complete']);
    });

    testWidgets('a Trip adds End day, every label whole', (tester) async {
      await pumpPanel(
        tester,
        canPause: true,
        canComplete: true,
        tripMode: true,
      );
      expect(labels(tester), <String>['Pause', 'End day', 'Complete Trip']);
      expect(tester.takeException(), isNull);
    });
  });
}
