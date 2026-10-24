import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';

/// What the route database keeps for a route ([RouteSummary]) or a Trip
/// ([TripSummary]), as the history cards and the map header show it. The
/// example counts nothing itself.
class RouteTotals {
  const RouteTotals({
    required this.distanceMeters,
    required this.segmentCount,
    required this.moving,
    required this.stopped,
    required this.stopCount,
    required this.qualityEventCount,
    required this.visibleGapCount,
    this.cleanedDistanceMeters,
    this.stepCount,
  });

  RouteTotals.ofRoute(RouteSummary summary)
    : this(
        distanceMeters: summary.distanceMeters,
        cleanedDistanceMeters: summary.cleanedDistanceMeters,
        segmentCount: summary.segmentCount,
        moving: summary.moving,
        stopped: summary.stopped,
        stopCount: summary.stopCount,
        stepCount: summary.stepCount,
        qualityEventCount: summary.qualityEventCount,
        visibleGapCount: summary.visibleGapCount,
      );

  RouteTotals.ofTrip(TripSummary summary)
    : this(
        distanceMeters: summary.distanceMeters,
        cleanedDistanceMeters: summary.cleanedDistanceMeters,
        segmentCount: summary.segmentCount,
        moving: summary.moving,
        stopped: summary.stopped,
        stopCount: summary.stopCount,
        stepCount: summary.stepCount,
        qualityEventCount: summary.qualityEventCount,
        visibleGapCount: summary.visibleGapCount,
      );

  final double distanceMeters;

  /// Length of the current cleaned view, once one was derived.
  final double? cleanedDistanceMeters;
  final int segmentCount;
  final Duration moving;
  final Duration stopped;
  final int stopCount;

  /// Null when the phone did not count steps.
  final int? stepCount;
  final int qualityEventCount;
  final int visibleGapCount;
}

String kilometres(double meters) => '${(meters / 1000).toStringAsFixed(2)} km';

/// "1 h 12 min" or "17 min".
String hoursMinutes(Duration duration) => duration.inMinutes >= 60
    ? '${duration.inHours} h ${duration.inMinutes % 60} min'
    : '${duration.inMinutes} min';
