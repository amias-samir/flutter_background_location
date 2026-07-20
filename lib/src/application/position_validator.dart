import 'dart:math' as math;

import '../domain/location_sample.dart';
import '../domain/track_point.dart';
import '../domain/tracking_config.dart';

final class PositionValidationResult {
  const PositionValidationResult({
    required this.accepted,
    required this.qualityFlags,
    this.rejectionReason,
  });

  final bool accepted;
  final int qualityFlags;
  final String? rejectionReason;
}

final class PositionValidator {
  const PositionValidator(this.config);

  final TrackingConfig config;

  PositionValidationResult validate({
    required LocationSample sample,
    required TrackPoint? previous,
    required DateTime now,
  }) {
    var flags = TrackPointQualityFlag.none;
    String? rejection;

    if (!sample.latitude.isFinite ||
        !sample.longitude.isFinite ||
        sample.latitude < -90 ||
        sample.latitude > 90 ||
        sample.longitude < -180 ||
        sample.longitude > 180) {
      flags |= TrackPointQualityFlag.invalidCoordinate;
      rejection = 'invalid_coordinate';
    }

    final accuracy = sample.horizontalAccuracy;
    if (accuracy != null &&
        (!accuracy.isFinite ||
            accuracy < 0 ||
            accuracy > config.maximumAcceptedAccuracyMeters)) {
      flags |= TrackPointQualityFlag.poorAccuracy;
      rejection ??= 'poor_accuracy';
    }

    if (sample.capturedAt.isAfter(now.add(const Duration(minutes: 2)))) {
      flags |= TrackPointQualityFlag.staleTimestamp;
      rejection ??= 'future_timestamp';
    }

    if (sample.mockAssessment == MockLocationAssessment.detected) {
      if (config.mockLocationPolicy != MockLocationPolicy.allow) {
        flags |= TrackPointQualityFlag.mockLocation;
      }
      if (config.mockLocationPolicy == MockLocationPolicy.reject) {
        rejection ??= 'mock_location_detected';
      }
    }

    if (previous != null) {
      final elapsed = sample.capturedAt.difference(previous.capturedAt);
      if (elapsed <= Duration.zero) {
        flags |= TrackPointQualityFlag.staleTimestamp;
        rejection ??= 'stale_timestamp';
      } else {
        if (elapsed > config.largeGapThreshold) {
          flags |= TrackPointQualityFlag.largeGap;
        }
        final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
        final speed = _distanceMeters(
              previous.latitude,
              previous.longitude,
              sample.latitude,
              sample.longitude,
            ) /
            seconds;
        if (speed.isFinite &&
            speed > config.maximumPlausibleSpeedMetersPerSecond) {
          flags |= TrackPointQualityFlag.implausibleSpeed;
        }
      }
    }

    return PositionValidationResult(
      accepted: rejection == null,
      qualityFlags: flags,
      rejectionReason: rejection,
    );
  }

  static double _distanceMeters(
    double latitude1,
    double longitude1,
    double latitude2,
    double longitude2,
  ) {
    const radius = 6371008.8;
    final lat1 = latitude1 * math.pi / 180;
    final lat2 = latitude2 * math.pi / 180;
    final deltaLatitude = (latitude2 - latitude1) * math.pi / 180;
    final deltaLongitude = (longitude2 - longitude1) * math.pi / 180;
    final a = math.sin(deltaLatitude / 2) * math.sin(deltaLatitude / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(deltaLongitude / 2) *
            math.sin(deltaLongitude / 2);
    return radius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
}
