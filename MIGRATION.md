# Migration guide

## Package rename

Use `flutter_background_location_tracker` in `pubspec.yaml` and imports. The
native Android namespace remains `com.samir.flutter_background_location` so an
upgrade can restore existing native state.

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
