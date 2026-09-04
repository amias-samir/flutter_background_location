# Migration guide

## Package rename

Use `flutter_background_location_tracker` in `pubspec.yaml` and imports. The
native Android namespace remains `com.samir.flutter_background_location` so an
upgrade can restore existing native state.

## Accuracy preset retuning

The four preset names remain source-compatible, but their resolved sampling
values are intentionally more accuracy-focused. `low` now uses the former
`medium` profile, `medium` uses the former `high` profile, and default `high`
uses navigation-grade accuracy with a 10-second moving interval. `precised`
keeps its 5-second moving interval while tightening its stationary filter to
15 m. Its accepted accuracy is now 15 m, which reduces avoidable rejected fixes
under partial sky visibility while remaining stricter than `high` at 20 m.

Applications that depend on the older battery-oriented values should pass
explicit intervals, distance filters, native `locationAccuracy`, and
`maximumAcceptedAccuracyMeters`. Explicit values continue to take precedence
over the preset. New configuration epochs record preset-definition version 3,
so exported diagnostics can distinguish this profile from the earlier 10 m
`precised` acceptance threshold.

## Legacy client to owner-bound controller

Existing code remains supported:

```dart
final tracking = TrackingClient();
await tracking.initialize();
final id = await tracking.startTrack(
  userId: userId,
  organizationId: organizationId,
);
```

New code should bind the authenticated owner once and use explicit Start
semantics:

```dart
final tracking = await TrackingClient.open(
  owner: TrackingOwner(userId: userId, organizationId: organizationId),
);
final result = await tracking.startNewTrack(
  TrackStartRequest(
    owner: tracking.currentOwner,
    routeId: 'Morning route',
  ),
);
```

Use `startOrRecoverTrack` when a Start gesture should recover the same owner's
active/paused/interrupted route. `startNewTrack` instead returns a typed
`active_track_conflict` and never silently resumes.

## Parallel streams to one replaying session

Replace separate status/activity/current-route button logic with
`sessionStream` and `TrackingSessionSnapshot.allowedActions`. Legacy streams
remain available; status/session replay current state, while activity and point
streams are live event streams.

## Permissions

Replace automatic `permissions(request: true)` flows with:

1. `checkReadiness()` (read-only);
2. show the UI for `nextAction`;
3. call `requestNextPermission()` only from a visible user gesture;
4. call `openSettings(...)` explicitly for Settings actions;
5. recheck after returning to the app.

## History and exports

Use `listTrackPage(TrackQuery(...))` for route lists. Keep
`loadTrackBundle(trackId)` for a selected map route; long-route exporters use
the bounded V2 export service. Existing `listTracks()` and
`TrackExportResult.path` stay available during the pre-1.0 compatibility
window.

## Schema 12 continuity and multi-day Trips

Schema 12 is additive. Existing Tracks, segments, points, configuration epochs,
outbox records, managed exports, and derived geometry remain unchanged. Each
existing Track receives one implicit owner-scoped Trip/leg membership row.

Existing `TrackingClient.open()` integrations remain source-compatible. To
present a journey once while completing each day independently, opt into:

```dart
final TrackingTripController tracking = await TrackingClient.openWithTrips(
  owner: TrackingOwner(userId: userId, organizationId: organizationId),
);
```

Replace final completion at the end of each day with `endCurrentDay()`, call
`continueTrip()` the next morning, and call `completeTrip()` only at the final
destination. Do not reopen completed Track rows; a continuation creates a new
immutable daily leg. Use `listTripPage()` for normal history and `exportTrip()`
for one GeoJSON/KML/GPX artifact.

The old `largeGapThreshold` remains decodable, but elapsed accepted-point time
alone no longer proves a capture interruption. New configuration separates
provider-fix age, callback-health warning, accepted-geometry gap diagnostics,
and continuity fallback policy. Map/export clients that want the corrected
normal presentation should select
`RouteGeometryContinuity.mergeAutomaticCallbackGaps`; raw evidence remains
available through `preserveEvidenceSegments`.

## Schema 13 activity, sensor fusion, quality runs, and presentation

Schema 13 is additive and migrates automatically. Existing Trips default to
`MultiDayRoutePresentation.separateRecordedParts`, existing configurations
decode with `RouteCaptureIntent.adaptive` and
`MotionFusionMode.platformActivityOnly`, and raw Track/point coordinates are
not rewritten.

New point columns preserve activity source, raw type, probable distribution,
age/freshness, and relevant foreground/power state. Coordinate-free fused
motion transitions and bounded probe summaries use `track_motion_evidence`;
the store retains at most 512 summaries per Track and never stores raw sensor
vectors. Consecutive rejected fixes are grouped in `track_quality_runs` so a
single minor rejection need not appear as a broken route marker.

For a known walking workflow, opt in explicitly:

```dart
const TrackingConfig(
  accuracy: TrackingAccuracy.high,
  captureIntent: RouteCaptureIntent.walking,
  motionFusionMode: MotionFusionMode.lowPowerSensorFusion,
);
```

To preserve the old topology, omit `routePresentation`. To join only the end
of one day to the start of the next, pass
`MultiDayRoutePresentation.connectDailyLegs` in `TripStartRequest`. A connected
line is presentation-only; it does not add raw points or measured distance.

Built-in derived geometry now also accepts
`algorithm: 'uncertainty_weighted_smoothing'`. Hosts can implement
`RouteGeometryProcessor` for opt-in road/footpath alignment. Processor pages
are bounded and overlapping; invalid, distant, missing, or low-confidence
matches fall back to raw anchors. Host applications remain responsible for
network consent, credentials, licensing, cancellation, and privacy policy.

## Runtime configuration

Feature-detect `TrackingConfigurationController` and call
`updateTrackingConfig`. The package fences native producers and activates an
immutable configuration epoch; changing a `TrackingConfig` object in host
memory does not update an active route.

Adaptive behavior remains opt-in. Start with `AdaptiveBatteryMode.shadow`, set
explicit `AdaptiveFidelityBounds`, and only enable apply mode after comparable
physical route/battery evidence. Disable through
`AdaptiveTrackingCoordinator.disableAndRestore()` so rollback creates a normal
configuration epoch.

## Raw and derived geometry

Existing `loadTrackBundle()` and exports remain raw. Feature-detect
`TrackingGeometryController` to create/list/delete immutable derivation runs,
then pass `TrackGeometrySelection.derived(run.id)` explicitly to map or V2
export APIs. Deleting a run never deletes or rewrites raw points. The legacy
materializing exporter rejects derived selection; use V2 for bounded derived
exports.

## iOS termination recovery

The default is `IosTerminationRecoveryMode.interrupted`, matching previous
manual-Resume behavior. `significantChange` is a new opt-in sampling contract,
not a silent upgrade: it uses reduced OS-controlled significant-change events
and can request best-effort relaunch. Hosts with lazy Flutter engines must call
the public iOS `prepareTerminationRecovery()` hook from the location launch
path. User force-quit remains non-recoverable until manual app launch.

## Tests

Import `flutter_background_location_tracker_testing.dart` from tests and use
`FakeTrackingController` for widget state or `FakeTrackerAdapter` when testing
a real client/storage integration. Deterministic clocks, synthetic routes,
permission fixtures, interrupted-state seeding, a temporary SQLite fixture,
and a faultable in-memory export writer are also available. No method-channel
mock is required.
