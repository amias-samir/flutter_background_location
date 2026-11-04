import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fixTime = 1784534400000;
  Map<Object?, Object?> payload(Map<Object?, Object?> activity) =>
      <Object?, Object?>{
        'lat': 0.001,
        'lon': 0.002,
        'accuracy': 5.0,
        'timestamp': fixTime,
        ...activity,
      };

  group('FIX-06 activity in native location payloads', () {
    test('uses the activity time, not the fix time', () {
      final sample = LocationSample.fromMap(payload(<Object?, Object?>{
        'activityType': 'still',
        'activityConfidence': 90,
        'activityTimestamp': fixTime - 120000,
        'activityEvidenceState': 'stale',
        'activityAgeMs': 120000,
        'activitySource': 'android_activity_recognition',
      }));

      final activity = sample.capturedActivity!;
      expect(activity.type, TrackingActivityType.stationary);
      expect(activity.confidence, 90);
      expect(
        activity.recordedAt,
        DateTime.fromMillisecondsSinceEpoch(fixTime - 120000, isUtc: true),
      );
      expect(activity.evidenceState, ActivityEvidenceState.stale);
      expect(activity.age, const Duration(minutes: 2));
      expect(activity.source, 'android_activity_recognition');
    });

    test('treats absent activity evidence as no reading', () {
      // Android sends every activity key, null, before the first reading.
      final android = LocationSample.fromMap(payload(<Object?, Object?>{
        'activityType': null,
        'activityConfidence': null,
        'activityTimestamp': null,
        'activityEvidenceState': null,
        'activityAgeMs': null,
      }));
      // Older iOS builds sent an unknown placeholder instead.
      final legacyIos = LocationSample.fromMap(payload(<Object?, Object?>{
        'activityType': 'unknown',
        'activityConfidence': 0,
      }));
      final none = LocationSample.fromMap(payload(const <Object?, Object?>{}));

      expect(android.capturedActivity, isNull);
      expect(legacyIos.capturedActivity, isNull);
      expect(none.capturedActivity, isNull);
    });

    test('a reading without an activity time is unavailable, not fresh', () {
      final sample = LocationSample.fromMap(payload(<Object?, Object?>{
        'activityType': 'walking',
        'activityConfidence': 70,
      }));

      expect(sample.capturedActivity!.type, TrackingActivityType.walking);
      expect(sample.capturedActivity!.recordedAt, isNull);
      expect(
        sample.capturedActivity!.evidenceState,
        ActivityEvidenceState.unavailable,
      );
    });

    test('keeps explicit native unavailability', () {
      final sample = LocationSample.fromMap(payload(<Object?, Object?>{
        'activityType': 'unknown',
        'activityConfidence': 0,
        'activityTimestamp': fixTime,
        'activityEvidenceState': 'unavailable',
        'activityRawType': 'permissionUnavailable',
      }));

      expect(
        sample.capturedActivity!.evidenceState,
        ActivityEvidenceState.unavailable,
      );
      expect(sample.capturedActivity!.rawType, 'permissionUnavailable');
    });
  });

  group('FIX-01 nested journal values', () {
    test('accepts nested values sent as JSON text', () {
      final sample = LocationSample.fromMap(payload(<Object?, Object?>{
        'activityType': 'still',
        'activityConfidence': 80,
        'activityTimestamp': fixTime,
        'activityProbabilities': '{"still":80,"walking":20}',
        'motionEvidence': '{"state":"moving","confidence":70,'
            '"observedAt":$fixTime}',
      }));

      expect(
          sample.capturedActivity!.probabilities, <TrackingActivityType, int>{
        TrackingActivityType.stationary: 80,
        TrackingActivityType.walking: 20,
      });
      expect(sample.capturedMotionEvidence!.state, FusedMotionState.moving);
      expect(sample.capturedMotionEvidence!.confidence, 70);
    });

    test('reads format-1 toString text as absent evidence', () {
      final sample = LocationSample.fromMap(payload(<Object?, Object?>{
        'activityType': 'still',
        'activityConfidence': 80,
        'activityTimestamp': fixTime,
        'activityProbabilities': '{still=80, walking=20}',
        'motionEvidence': '{state=moving, confidence=70}',
      }));

      expect(sample.capturedActivity!.probabilities, isEmpty);
      expect(sample.capturedMotionEvidence, isNull);
    });
  });

  group('FIX-10 location validity', () {
    test('drops platform sentinels for unknown kinematics', () {
      final sample = LocationSample.fromMap(payload(<Object?, Object?>{
        'speed': -1.0,
        'speedAccuracy': -1.0,
        'heading': -1.0,
        'headingAccuracy': -1.0,
      }));

      expect(sample.speed, isNull);
      expect(sample.speedAccuracy, isNull);
      expect(sample.heading, isNull);
      expect(sample.headingAccuracy, isNull);
    });

    test('drops the altitude when vertical accuracy marks it invalid', () {
      final invalid = LocationSample.fromMap(payload(<Object?, Object?>{
        'altitude': 42.0,
        'verticalAccuracy': -1.0,
      }));
      final unreported = LocationSample.fromMap(payload(<Object?, Object?>{
        'altitude': 42.0,
      }));

      expect(invalid.altitude, isNull);
      expect(invalid.verticalAccuracy, isNull);
      // Android may report altitude without a vertical accuracy.
      expect(unreported.altitude, 42.0);
    });

    test('keeps valid values and normalizes heading into [0, 360)', () {
      final sample = LocationSample.fromMap(payload(<Object?, Object?>{
        'altitude': 42.0,
        'verticalAccuracy': 3.0,
        'speed': 0.0,
        'speedAccuracy': 0.4,
        'heading': 360.0,
        'headingAccuracy': 12.0,
      }));

      expect(sample.altitude, 42.0);
      expect(sample.verticalAccuracy, 3.0);
      expect(sample.speed, 0.0);
      expect(sample.speedAccuracy, 0.4);
      expect(sample.heading, 0.0);
      expect(sample.headingAccuracy, 12.0);
    });
  });
}
