import '../domain/fix_quality.dart';
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
    final decision = FixQualityPolicy(config).evaluate(
      sample: sample,
      previous: previous,
      now: now,
    );

    return PositionValidationResult(
      accepted: decision.acceptedForGeometry,
      qualityFlags: decision.qualityFlags,
      rejectionReason: decision.rejectionReason,
    );
  }
}
