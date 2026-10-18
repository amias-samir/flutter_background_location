/// Whether a commit moved a route's accepted-point count across a multiple of
/// [batchPointCount].
///
/// A batched commit can add several accepted points at once, so testing the
/// new count for an exact multiple would skip thresholds.
bool crossesUploadThreshold({
  required int acceptedBefore,
  required int acceptedAfter,
  required int batchPointCount,
}) =>
    batchPointCount > 0 &&
    acceptedAfter > acceptedBefore &&
    acceptedAfter ~/ batchPointCount > acceptedBefore ~/ batchPointCount;
