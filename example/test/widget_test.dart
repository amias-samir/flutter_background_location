import 'package:flutter/material.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('example exposes a Flutter application widget', () {
    expect(const TrackingExampleApp(), isA<Widget>());
  });

  testWidgets('keep all retention is selected by default', (tester) async {
    await tester.pumpWidget(const TrackingExampleApp());
    await tester.pumpAndSettle();

    final selector = tester.widget<SegmentedButton<TrackRecordRetentionPolicy>>(
      find.byType(SegmentedButton<TrackRecordRetentionPolicy>),
    );
    expect(selector.selected, <TrackRecordRetentionPolicy>{
      TrackRecordRetentionPolicy.keepAll,
    });
  });

  testWidgets('start asks for a non-empty route identifier', (tester) async {
    await tester.pumpWidget(const TrackingExampleApp());
    await tester.pumpAndSettle();

    final start = find.text('Start');
    await tester.ensureVisible(start);
    await tester.pumpAndSettle();
    await tester.tap(start);
    await tester.pumpAndSettle();

    expect(find.text('Route identifier'), findsOneWidget);
    expect(find.text('Route ID'), findsOneWidget);
    final startTracking = find.widgetWithText(FilledButton, 'Start tracking');
    expect(tester.widget<FilledButton>(startTracking).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'Morning route');
    await tester.pump();
    expect(tester.widget<FilledButton>(startTracking).onPressed, isNotNull);
  });
}
