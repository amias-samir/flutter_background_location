/// Severity assigned to a consecutive run of rejected raw fixes.
enum TrackQualityRunSeverity {
  /// A rejected run retained for diagnostics but hidden by default.
  informational,

  /// A run long or severe enough to display as a route-quality gap.
  visibleGap,

  /// A boundary caused by an explicit lifecycle or provider interruption.
  lifecycleBoundary,
}

/// Coordinate-free diagnostics for a Track or multi-day Trip snapshot.
final class TrackingQualitySummary {
  /// Creates a privacy-safe aggregate containing no coordinates or owner IDs.
  const TrackingQualitySummary({
    required this.rawCallbackCount,
    required this.acceptedPointCount,
    required this.rejectedPointCount,
    required this.qualityRunCount,
    required this.visibleQualityRunCount,
    required this.continuityGapCount,
    required this.lifecycleBoundaryCount,
    required this.staleActivityCount,
    this.acceptedAccuracyP50Meters,
    this.acceptedAccuracyP95Meters,
    this.rejectedAccuracyP50Meters,
    this.rejectedAccuracyP95Meters,
  });

  /// All persisted provider callbacks, whether accepted or rejected.
  final int rawCallbackCount;

  /// Callbacks accepted as canonical route anchors.
  final int acceptedPointCount;

  /// Callbacks retained for audit but excluded from canonical geometry.
  final int rejectedPointCount;

  /// Consecutive rejected-fix runs.
  final int qualityRunCount;

  /// Quality runs whose severity warrants a visible marker.
  final int visibleQualityRunCount;

  /// Durable topology/continuity decisions.
  final int continuityGapCount;

  /// Continuity decisions caused by lifecycle boundaries.
  final int lifecycleBoundaryCount;

  /// Points whose attached activity evidence was stale.
  final int staleActivityCount;

  /// Median accepted-point horizontal uncertainty in metres.
  final double? acceptedAccuracyP50Meters;

  /// 95th percentile accepted-point uncertainty in metres.
  final double? acceptedAccuracyP95Meters;

  /// Median rejected-point horizontal uncertainty in metres.
  final double? rejectedAccuracyP50Meters;

  /// 95th percentile rejected-point uncertainty in metres.
  final double? rejectedAccuracyP95Meters;
}
