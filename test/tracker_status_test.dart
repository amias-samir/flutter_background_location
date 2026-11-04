import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FIX-11 TrackerStatus.lastPointAt', () {
    test('uses the explicit native fix time', () {
      final status = TrackerStatus.fromMap(const <Object?, Object?>{
        'lifecycle': 'tracking',
        'lastPointAt': 1784534400000,
        'timestamp': 1784534460000,
      });

      expect(
        status.lastPointAt,
        DateTime.fromMillisecondsSinceEpoch(1784534400000, isUtc: true),
      );
    });

    test('does not invent a fix from the status time before the first fix', () {
      final status = TrackerStatus.fromMap(const <Object?, Object?>{
        'lifecycle': 'tracking',
        'lastPointAt': null,
        'timestamp': 1784534460000,
      });

      expect(status.lastPointAt, isNull);
    });

    test('falls back to the status time only when natives omit the key', () {
      final status = TrackerStatus.fromMap(const <Object?, Object?>{
        'lifecycle': 'tracking',
        'timestamp': 1784534460000,
      });

      expect(
        status.lastPointAt,
        DateTime.fromMillisecondsSinceEpoch(1784534460000, isUtc: true),
      );
    });
  });
}
