import 'package:flutter/foundation.dart';

/// The most fixes `TrackingClient` stores in one transaction, or null for
/// its defaults (100 while replaying the native journal, 25 when live).
/// Tests set 1 to compare batched storage with the fix-by-fix path.
@visibleForTesting
int? pointBatchLimit;

/// [pointBatchLimit], read by the client.
int? get pointBatchLimitOverride => pointBatchLimit;
