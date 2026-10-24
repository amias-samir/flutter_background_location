import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';

/// What the route database keeps for a route ([RouteSummary]) or a Trip
/// ([TripSummary]), as the history cards and the map header show it. The
/// example counts nothing itself.
class RouteTotals {
  const RouteTotals({
    required this.distanceMeters,
    required this.displayDistanceMeters,
    required this.segmentCount,
    required this.moving,
    required this.stopped,
    required this.stopCount,
    required this.qualityEventCount,
    required this.visibleGapCount,
    this.correctedDistanceMeters,
    this.cleanedDistanceMeters,
    this.stepCount,
    this.stepCountStoppedAt,
  });

  RouteTotals.ofRoute(RouteSummary summary)
    : this(
        distanceMeters: summary.distanceMeters,
        correctedDistanceMeters: summary.correctedDistanceMeters,
        displayDistanceMeters: summary.displayDistanceMeters,
        cleanedDistanceMeters: summary.cleanedDistanceMeters,
        segmentCount: summary.segmentCount,
        moving: summary.moving,
        stopped: summary.stopped,
        stopCount: summary.stopCount,
        stepCount: summary.stepCount,
        stepCountStoppedAt: summary.stepCountStoppedAt,
        qualityEventCount: summary.qualityEventCount,
        visibleGapCount: summary.visibleGapCount,
      );

  RouteTotals.ofTrip(TripSummary summary)
    : this(
        distanceMeters: summary.distanceMeters,
        correctedDistanceMeters: summary.correctedDistanceMeters,
        displayDistanceMeters: summary.displayDistanceMeters,
        cleanedDistanceMeters: summary.cleanedDistanceMeters,
        segmentCount: summary.segmentCount,
        moving: summary.moving,
        stopped: summary.stopped,
        stopCount: summary.stopCount,
        stepCount: summary.stepCount,
        stepCountStoppedAt: summary.stepCountStoppedAt,
        qualityEventCount: summary.qualityEventCount,
        visibleGapCount: summary.visibleGapCount,
      );

  /// Measured distance, as recorded.
  final double distanceMeters;

  /// Length of the fixes the current rules keep, for a route recorded under
  /// older rules and reviewed since; null when [distanceMeters] already is.
  final double? correctedDistanceMeters;

  /// The distance a card shows: the corrected one when the route was
  /// reviewed, else [distanceMeters].
  final double displayDistanceMeters;

  /// Length of the current cleaned view, once one was derived.
  final double? cleanedDistanceMeters;
  final int segmentCount;
  final Duration moving;
  final Duration stopped;
  final int stopCount;

  /// Null when the phone did not count steps.
  final int? stepCount;

  /// When the step counter stopped counting while the person walked:
  /// [stepCount] is then a lower bound. Null when the count is complete.
  final DateTime? stepCountStoppedAt;
  final int qualityEventCount;
  final int visibleGapCount;

  /// [stepCount] as shown ([stepsLabel]); null when steps were not counted.
  String? get stepsText => switch (stepCount) {
    final steps? => stepsLabel(steps, stoppedAt: stepCountStoppedAt),
    null => null,
  };
}

String kilometres(double meters) => '${(meters / 1000).toStringAsFixed(2)} km';

/// "1 h 12 min" or "17 min".
String hoursMinutes(Duration duration) => duration.inMinutes >= 60
    ? '${duration.inHours} h ${duration.inMinutes % 60} min'
    : '${duration.inMinutes} min';

/// "4321 steps", or "≥ 167 steps · counter stopped at 08:51" when the step
/// counter stopped counting at [stoppedAt] while the person walked. The
/// count is never estimated.
String stepsLabel(int steps, {DateTime? stoppedAt}) => stoppedAt == null
    ? '$steps steps'
    : '≥ $steps steps · counter stopped at ${clockTime(stoppedAt)}';

/// [time] on the device's 24-hour clock: "08:51".
String clockTime(DateTime time) {
  final local = time.toLocal();
  return '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}
