# Multi-day Trips

Use `TrackingClient.openWithTrips()` when one user-visible journey can span
several days. The returned `TrackingTripController` includes all normal Track
controls plus the additive Trip lifecycle, history, geometry, export, and
deletion APIs. Back to the [README](../README.md).

## Data model

| Model | Meaning |
|---|---|
| `Trip` | The single journey shown to the user across every day |
| `TripLeg` | One independently completed daily `Track` inside the Trip |
| `TrackSegment` | One uninterrupted capture interval inside a leg |
| `TrackingContinuityGap` | Auditable evidence of missing or rejected geometry |

The `Trip.id` and readable `routeId` stay stable. Each **End day** operation
stops native capture and makes that day's Track immutable. **Continue trip**
creates exactly one ordered next leg rather than reopening the completed Track.
This preserves export and upload idempotency while the application displays one
Trip instead of several unrelated routes.

Use ordinary `pauseCurrentTrack()` and `resumeCurrentTrack()` for a temporary
break during the same day. Use `endCurrentDay()` only when the current daily leg
should be completed.

## Open one owner-scoped Trip controller

Keep one controller for the signed-in owner and dispose it during sign-out. Do
not create a controller per screen or per day.

```dart
const trackingOwner = TrackingOwner(
  userId: 'signed-in-user',
  organizationId: 'workspace-id',
);

late final TrackingTripController tracking;

Future<void> initializeTripTracking() async {
  tracking = await TrackingClient.openWithTrips(
    owner: trackingOwner,
    configuration: const TrackingConfiguration(
      defaultTrackingConfig: TrackingConfig(
        accuracy: TrackingAccuracy.high,
      ),
      recordRetentionPolicy: TrackRecordRetentionPolicy.keepAll,
    ),
  );

  tracking.sessionStream.listen((session) {
    // Drive Pause/Resume and native capture state from allowedActions.
    print(session.status.lifecycle);
  });
}
```

`keepAll` is recommended for multi-day history. Trip-aware retention preserves
every leg belonging to the retained Trip; it does not delete yesterday's leg
while that Trip is still current.

## Start, end a day, continue, and complete

Call lifecycle methods only after the same readiness flow used for normal Track
recording. Supply a stable `operationId` when your application may retry a
command after a timeout or process restart.

```dart
Future<Trip> startJourney() async {
  final readiness = await tracking.checkReadiness();
  if (!readiness.canStart) {
    throw StateError('Present readiness.nextAction before starting.');
  }

  final result = await tracking.startTrip(
    const TripStartRequest(
      routeId: 'Kathmandu field visit',
      operationId: 'server-command-start-42',
      dayLabel: 'Day 1',
      routePresentation: MultiDayRoutePresentation.connectDailyLegs,
      config: TrackingConfig(
        accuracy: TrackingAccuracy.high,
        captureIntent: RouteCaptureIntent.walking,
        motionFusionMode: MotionFusionMode.lowPowerSensorFusion,
      ),
    ),
  );
  return result.trip;
}

Future<void> finishToday() async {
  await tracking.endCurrentDay(
    reason: 'overnight',
    operationId: 'server-command-end-day-42-1',
  );
  // Native capture is now stopped and the Trip is suspended.
}

Future<void> startNextDay(String tripId) async {
  final readiness = await tracking.checkReadiness();
  if (!readiness.canStart) return;

  final result = await tracking.continueTrip(
    tripId,
    operationId: 'server-command-continue-42-2',
  );
  print('Recording leg ${result.leg.legNumber}');
}

Future<void> finishWholeJourney(String tripId) async {
  await tracking.completeTrip(
    tripId,
    reason: 'destination_reached',
    operationId: 'server-command-complete-42',
  );
}
```

## Route presentation

Route presentation is persisted with the Trip:

- `separateRecordedParts` preserves every daily and lifecycle boundary;
- `connectDailyLegs` joins only boundaries between consecutive days;
- `continuousPresentation` joins all chronological accepted parts.

Connected modes add straight, typed `InferredRouteConnector` edges. Their
length is excluded from `Trip.measuredDistanceMeters`, because no locations
were captured along those edges. The stored default is used by the shared map
assembler and GeoJSON/KML/GPX Trip export; pass an explicit override only for a
temporary viewer/export choice.

## Route identifier and lifecycle summary

The route identifier is created only when the Trip starts. Whitespace is
normalized to underscores and a timestamp suffix prevents duplicates. Every
later leg inherits the same Trip route identifier.

Lifecycle summary:

| Current state | Application action | Result |
|---|---|---|
| Active Trip | `pauseCurrentTrack()` | Pauses the current leg; resumable in place |
| Paused leg | `resumeCurrentTrack()` | Resumes the same Track leg |
| Active Trip | `endCurrentDay()` | Completes the leg, stops capture, suspends Trip |
| Suspended Trip | `continueTrip(tripId)` | Starts the next daily leg |
| Active Trip | `completeTrip(tripId)` | Completes the leg and terminal Trip |
| Completed Trip | confirmed `continueTrip(...)` | Adds a new leg without changing old legs |

## Restore Trip UI after an application restart

`openWithTrips()` reconciles durable database and native state before it
returns. Rebuild Trip history from owner-scoped pages instead of keeping the
Trip only in widget memory or shared preferences.

```dart
Future<List<Trip>> loadRecentTrips() async {
  final page = await tracking.listTripPage(
    const TripQuery(owner: trackingOwner, limit: 20),
  );
  return page.items;
}

Future<Trip?> loadTripToContinue() async {
  final page = await tracking.listTripPage(
    const TripQuery(
      owner: trackingOwner,
      limit: 1,
      statuses: <TripStatus>{TripStatus.suspended},
    ),
  );
  return page.items.isEmpty ? null : page.items.first;
}
```

Use `nextCursor` to page older Trips. `loadTripBundle(tripId)` returns ordered
legs and typed gap evidence for a detail screen.

## Deliberately continue a completed Trip

Completed daily Tracks are never reopened. If a journey was completed at the
end of day one by mistake, explicitly confirm continuation so the package can
append a new leg:

```dart
await tracking.continueTrip(
  completedTripId,
  confirmCompletedTripContinuation: true,
  operationId: 'server-command-reopen-42',
);
```

Ask the user for confirmation before passing this flag. If final Trip upload
has already been acknowledged under a non-reopenable remote contract, the
operation throws `TrackingTripException` with code `trip_already_finalized`
rather than silently changing uploaded history.

Handle Trip failures by their stable code instead of parsing messages:

```dart
try {
  await tracking.continueTrip(tripId);
} on TrackingTripException catch (error) {
  switch (error.code) {
    case 'completed_trip_confirmation_required':
      // Ask the user, then retry once with explicit confirmation.
      break;
    case 'active_trip_conflict':
      // Another Trip currently owns native capture.
      break;
    default:
      rethrow;
  }
}
```

## Display or export the complete journey

The same assembler drives the example MapLibre route and GeoJSON, KML, and GPX
exports, preventing map/export topology differences.

```dart
final geometry = await tracking.assembleTripRouteGeometry(
  tripId,
  continuity: RouteGeometryContinuity.mergeAutomaticCallbackGaps,
);

final exported = await tracking.exportTrip(
  tripId: tripId,
  format: TrackExportFormat.gpx,
  fileName: 'complete_field_visit',
  options: const TrackExportOptions(
    geometryContinuity:
        RouteGeometryContinuity.mergeAutomaticCallbackGaps,
  ),
);

print('${geometry.parts.length} drawable parts');
print(exported.path);
```

Trips must be completed before export by default. For an explicitly labeled
work-in-progress snapshot, pass
`TrackExportOptions(allowIncompleteTrackSnapshot: true)`. Combined Trip export
has a 100,000-point safety ceiling; applications handling larger journeys
should archive/page daily legs or provide a streaming backend export.

Geometry modes:

- `preserveEvidenceSegments` preserves every real lifecycle boundary;
- `mergeAutomaticCallbackGaps` merges only typed automatic gaps whose durable
  treatment retained the same canonical segment. This is the recommended map
  and normal export mode;
- `connectAllChronologicalPoints` creates one continuous presentation and
  reports every straight connector as inferred.

Inferred connectors are never inserted into raw `track_points` and their
length is excluded from measured distance. No location package can reconstruct
the road taken when the operating system supplied no usable fixes.

## Delete a Trip

Only terminal `completed` or `failed` Trips can be deleted. Deletion removes
all owned legs, database artifacts, upload-outbox rows, package-managed export
snapshots, and matching native journal entries.

```dart
await tracking.deleteTrip(completedTripId);
```

Require an application-level confirmation before this irreversible action.
Active and suspended Trips must first be completed or otherwise resolved.

## Integration rules

- Use the same `TrackingOwner` for controller creation and every `TripQuery`.
- Keep one application-scoped controller and serialize lifecycle button taps.
- Drive capture controls from `session.allowedActions`; drive Trip history from
  `listTripPage()`.
- Reuse a stable `operationId` when retrying the same logical command. A new ID
  represents a new command.
- Do not reopen or modify completed daily Track rows directly.
- Confirm completed-Trip continuation and terminal deletion in host UI.
- Test overnight, locked-screen, battery-saver, permission-loss, and provider-
  outage behavior on physical devices before release.
