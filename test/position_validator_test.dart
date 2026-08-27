import 'package:flutter_background_location_tracker/src/application/position_validator.dart';
import 'package:flutter_background_location_tracker/src/domain/activity_snapshot.dart';
import 'package:flutter_background_location_tracker/src/domain/fix_quality.dart';
import 'package:flutter_background_location_tracker/src/domain/location_sample.dart';
import 'package:flutter_background_location_tracker/src/domain/track_point.dart';
import 'package:flutter_background_location_tracker/src/domain/tracker_status.dart';
import 'package:flutter_background_location_tracker/src/domain/tracking_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 7, 20, 8);

  LocationSample sample({
    double latitude = 27.7172,
    double longitude = 85.324,
    DateTime? capturedAt,
    double? accuracy = 5,
    bool isMocked = false,
    bool mockDetectionAvailable = false,
  }) =>
      LocationSample(
        latitude: latitude,
        longitude: longitude,
        capturedAt: capturedAt ?? now,
        horizontalAccuracy: accuracy,
        isMocked: isMocked,
        mockDetectionAvailable: mockDetectionAvailable,
      );

  TrackPoint previous({
    double latitude = 27.7172,
    double longitude = 85.324,
    DateTime? capturedAt,
  }) =>
      TrackPoint(
        id: 'point-0',
        trackId: 'track-1',
        segmentId: 'segment-1',
        sequence: 1,
        latitude: latitude,
        longitude: longitude,
        capturedAt: capturedAt ?? now.subtract(const Duration(seconds: 10)),
        persistedAt: now,
        activityType: TrackingActivityType.unknown,
        activityConfidence: 0,
        motionState: MotionState.unknown,
        isMocked: false,
        mockDetectionAvailable: false,
        accepted: true,
        qualityFlags: TrackPointQualityFlag.none,
      );

  group('mock-location assessment', () {
    test('native event metadata retains its durable queue identity', () {
      final value = LocationSample.fromMap(<Object?, Object?>{
        'lat': 27.7172,
        'lon': 85.324,
        'timestamp': 1700000000000,
        'eventId': 'event-1',
        'trackId': 'track-1',
      });

      expect(value.eventId, 'event-1');
      expect(value.trackId, 'track-1');
    });

    test('distinguishes detected, not detected, and unavailable', () {
      expect(
        sample().mockAssessment,
        MockLocationAssessment.unavailable,
      );
      expect(
        sample(mockDetectionAvailable: true).mockAssessment,
        MockLocationAssessment.notDetected,
      );
      expect(
        sample(isMocked: true, mockDetectionAvailable: true).mockAssessment,
        MockLocationAssessment.detected,
      );
    });

    test('fromMap requires explicit clear-signal availability', () {
      final unavailable = LocationSample.fromMap(<Object?, Object?>{
        'latitude': 27.7,
        'longitude': 85.3,
        'timestamp': now.millisecondsSinceEpoch,
      });
      final unavailableClearFlag = LocationSample.fromMap(<Object?, Object?>{
        'latitude': 27.7,
        'longitude': 85.3,
        'timestamp': now.millisecondsSinceEpoch,
        'isMocked': false,
      });
      final notDetected = LocationSample.fromMap(<Object?, Object?>{
        'latitude': 27.7,
        'longitude': 85.3,
        'timestamp': now.millisecondsSinceEpoch,
        'isMocked': false,
        'mockDetectionAvailable': true,
      });
      final detectedDespiteBadAvailability =
          LocationSample.fromMap(<Object?, Object?>{
        'latitude': 27.7,
        'longitude': 85.3,
        'timestamp': now.millisecondsSinceEpoch,
        'isMocked': true,
        'mockDetectionAvailable': false,
      });

      expect(unavailable.mockAssessment, MockLocationAssessment.unavailable);
      expect(
        unavailableClearFlag.mockAssessment,
        MockLocationAssessment.unavailable,
      );
      expect(notDetected.mockAssessment, MockLocationAssessment.notDetected);
      expect(
        detectedDespiteBadAvailability.mockAssessment,
        MockLocationAssessment.detected,
      );
    });

    for (final expectation in <({
      MockLocationPolicy policy,
      bool accepted,
      bool flagged,
      String? reason,
    })>[
      (
        policy: MockLocationPolicy.allow,
        accepted: true,
        flagged: false,
        reason: null,
      ),
      (
        policy: MockLocationPolicy.flag,
        accepted: true,
        flagged: true,
        reason: null,
      ),
      (
        policy: MockLocationPolicy.reject,
        accepted: false,
        flagged: true,
        reason: 'mock_location_detected',
      ),
    ]) {
      test('${expectation.policy.name} policy is applied only to detections',
          () {
        final validator = PositionValidator(
          TrackingConfig(mockLocationPolicy: expectation.policy),
        );
        final result = validator.validate(
          sample: sample(
            isMocked: true,
            mockDetectionAvailable: true,
          ),
          previous: null,
          now: now,
        );

        expect(result.accepted, expectation.accepted);
        expect(
          result.qualityFlags & TrackPointQualityFlag.mockLocation != 0,
          expectation.flagged,
        );
        expect(result.rejectionReason, expectation.reason);
      });
    }

    test('reject policy does not reject unavailable or clean evidence', () {
      final validator = PositionValidator(
        const TrackingConfig(mockLocationPolicy: MockLocationPolicy.reject),
      );

      for (final candidate in <LocationSample>[
        sample(),
        sample(mockDetectionAvailable: true),
      ]) {
        final result = validator.validate(
          sample: candidate,
          previous: null,
          now: now,
        );
        expect(result.accepted, isTrue);
        expect(
          result.qualityFlags & TrackPointQualityFlag.mockLocation,
          isZero,
        );
      }
    });
  });

  group('position validation', () {
    const config = TrackingConfig(
      maximumAcceptedAccuracyMeters: 50,
      maximumPlausibleSpeedMetersPerSecond: 20,
      largeGapThreshold: Duration(minutes: 5),
    );
    const validator = PositionValidator(config);

    test('rejects non-finite and out-of-range coordinates', () {
      for (final candidate in <LocationSample>[
        sample(latitude: double.nan),
        sample(latitude: 91),
        sample(longitude: -181),
      ]) {
        final result = validator.validate(
          sample: candidate,
          previous: null,
          now: now,
        );
        expect(result.accepted, isFalse);
        expect(result.rejectionReason, 'invalid_coordinate');
        expect(
          result.qualityFlags & TrackPointQualityFlag.invalidCoordinate,
          isNot(0),
        );
      }
    });

    test('rejects unusable accuracy and future or stale timestamps', () {
      final poorAccuracy = validator.validate(
        sample: sample(accuracy: 51),
        previous: null,
        now: now,
      );
      final future = validator.validate(
        sample: sample(capturedAt: now.add(const Duration(minutes: 3))),
        previous: null,
        now: now,
      );
      final stale = validator.validate(
        sample: sample(capturedAt: now.subtract(const Duration(seconds: 10))),
        previous: previous(
          capturedAt: now.subtract(const Duration(seconds: 10)),
        ),
        now: now,
      );

      expect(poorAccuracy.rejectionReason, 'poor_accuracy');
      expect(future.rejectionReason, 'future_timestamp');
      expect(stale.rejectionReason, 'stale_timestamp');
    });

    test('flags implausible speed without discarding an otherwise valid fix',
        () {
      final result = validator.validate(
        sample: sample(latitude: 27.7272),
        previous:
            previous(capturedAt: now.subtract(const Duration(seconds: 1))),
        now: now,
      );

      expect(result.accepted, isTrue);
      expect(result.rejectionReason, isNull);
      expect(
        result.qualityFlags & TrackPointQualityFlag.implausibleSpeed,
        isNot(0),
      );
    });

    test('flags a large gap independently from acceptance', () {
      final result = validator.validate(
        sample: sample(),
        previous:
            previous(capturedAt: now.subtract(const Duration(minutes: 6))),
        now: now,
      );

      expect(result.accepted, isTrue);
      expect(result.qualityFlags & TrackPointQualityFlag.largeGap, isNot(0));
    });

    test('versioned policy separates geometry from motion eligibility', () {
      final decision = const FixQualityPolicy(config).evaluate(
        sample: sample(accuracy: 0),
        previous: null,
        now: now,
      );

      expect(decision.acceptedForGeometry, isTrue);
      expect(decision.acceptedForMotionEvidence, isFalse);
      expect(decision.issues, contains(FixQualityIssue.zeroAccuracy));
      expect(decision.policyVersion, greaterThan(0));
    });

    test('receipt-time evidence distinguishes stale and future fixes', () {
      final stale = const FixQualityPolicy(config).evaluate(
        sample: LocationSample(
          latitude: 27.7,
          longitude: 85.3,
          horizontalAccuracy: 5,
          capturedAt: now,
          providerTimeDeltaMsAtReceipt: 600000,
        ),
        previous: null,
        now: now,
      );
      final future = const FixQualityPolicy(config).evaluate(
        sample: LocationSample(
          latitude: 27.7,
          longitude: 85.3,
          horizontalAccuracy: 5,
          capturedAt: now,
          providerTimeDeltaMsAtReceipt: -180000,
        ),
        previous: null,
        now: now,
      );

      expect(stale.issues, contains(FixQualityIssue.staleTimestamp));
      expect(stale.acceptedForGeometry, isFalse);
      expect(future.issues, contains(FixQualityIssue.futureTimestamp));
      expect(future.acceptedForGeometry, isFalse);
    });
  });
}
