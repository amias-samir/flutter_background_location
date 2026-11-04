# Integration guide

The full integration path for a single-day `TrackingController`: streams,
staged permissions, diagnostics, lifecycle commands, uploads, tests and
troubleshooting. Back to the [README](../README.md). Multi-day journeys are
covered in [Multi-day Trips](multi_day_trips.md).

- [Open the controller and listen](#open-the-controller-and-listen)
- [Staged permissions](#staged-permissions)
- [Diagnostics and setup doctor](#diagnostics-and-setup-doctor)
- [Owner conflicts](#owner-conflicts)
- [Start, pause, resume, and complete](#start-pause-resume-and-complete)
- [Recommended UI state](#recommended-ui-state)
- [Optional upload integration](#optional-upload-integration)
- [Runtime configuration updates](#runtime-configuration-updates)
- [Host application tests](#host-application-tests)
- [Disposing the client](#disposing-the-client)
- [Common issues](#common-issues)

## Open the controller and listen

Prefer one awaited, owner-bound `TrackingController` for the application
lifetime. The legacy constructor remains available for existing integrations.

```dart
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';

late final TrackingController tracking;

Future<void> initializeTracking() async {
  tracking = await TrackingClient.open(
    owner: const TrackingOwner(
      userId: 'user-42',
      organizationId: 'organization-7',
    ),
  );

  tracking.statusStream.listen((status) {
    print('state=${status.lifecycle.name} track=${status.trackId}');
  });

  tracking.activityStream.listen((activity) {
    print(
      'activity=${activity.type.value} confidence=${activity.confidence}',
    );
  });

  tracking.pointStream.listen((point) {
    print(
      'point=${point.sequence} accepted=${point.accepted} '
      'mock=${point.mockAssessment.name}',
    );
  });
}
```

Use the replaying session snapshot to drive lifecycle buttons:

```dart
final sessionSubscription = tracking.sessionStream.listen((session) {
  startButton.enabled = session.allowedActions.canStartNew;
  pauseButton.enabled = session.allowedActions.canPause;
  resumeButton.enabled = session.allowedActions.canResume;
  completeButton.enabled = session.allowedActions.canComplete;
});
```

## Staged permissions

Check readiness without prompting, then request only the next permission step
from a user-initiated action. Return without starting until the normalized state
confirms Always/background access:

```dart
Future<bool> preparePermissions() async {
  final readiness = await tracking.checkReadiness();
  if (readiness.canStart) return true;

  switch (readiness.nextAction) {
    case TrackingReadinessAction.requestForegroundLocation:
    case TrackingReadinessAction.requestBackgroundLocation:
    case TrackingReadinessAction.requestNotification:
    case TrackingReadinessAction.requestActivityRecognition:
      await tracking.requestNextPermission();
      return false;
    case TrackingReadinessAction.explainBackgroundLocation:
      // Show your explanation first. On the user's next affirmative gesture:
      await tracking.acknowledgeReadinessEducation(
        'background_location_explanation_required',
      );
      return false;
    case TrackingReadinessAction.openAppSettings:
    case TrackingReadinessAction.enableLocationServices:
    case TrackingReadinessAction.enablePreciseLocation:
      await tracking.openSettings(TrackingSettingsDestination.application);
      return false;
    case TrackingReadinessAction.none:
      return true;
    case TrackingReadinessAction.unsupported:
    case TrackingReadinessAction.unknown:
      throw StateError('Background tracking is unavailable on this device.');
  }
}
```

The older `permissions(request: true)` helper remains available for existing
apps, but new integrations should prefer `checkReadiness()` plus
`requestNextPermission()` so permission prompts stay staged and user-driven.

## Diagnostics and setup doctor

For device setup screens and diagnostics:

```dart
final diagnostics = tracking as TrackingDiagnosticsController;
final battery = await diagnostics.batteryOptimizationState();
if (battery.supported && !battery.isIgnoringBatteryOptimizations) {
  await tracking.openSettings(
    TrackingSettingsDestination.batteryOptimization,
  );
}

final health = diagnostics.currentHealth; // no coordinates included
final doctor = await diagnostics.runSetupDoctor();
final supportReport = await diagnostics.createSupportReport();
// supportReport.toRedactedMap() excludes coordinates, route/owner IDs,
// filenames, command tokens, and raw native exception payloads.
```

If a readiness action needs the host to show its own explanation, do not open
Settings or request another permission automatically. Let the user tap the next
button.

Read recorded-route summaries without loading every point (see
[Route details](route_details.md) for the stored totals):

```dart
final firstPage = await tracking.listTrackPage(
  TrackQuery(
    statuses: const <TrackStatus>{TrackStatus.completed},
    limit: 25,
  ),
);

for (final route in firstPage.items) {
  print('${route.routeId ?? route.id}: ${route.acceptedPointCount} points');
}
```

## Owner conflicts

If a previous signed-in owner left a live native capture, the owner-bound
session exposes `owner_scope_conflict` and an opaque one-use recovery token,
never the foreign route or owner identity. After an explicit warning/confirmation
gesture, preserve that capture as paused before allowing the new owner to start:

```dart
final blocked = tracking.currentSession;
final token = blocked.blockerRecoveryToken;
if (blocked.blockerCode == 'owner_scope_conflict' && token != null) {
  final hostPersistedOperationId =
      'owner-conflict-${DateTime.now().microsecondsSinceEpoch}';
  // Persist this ID until the confirmation attempt reaches a terminal result.
  await tracking.resolveOwnerConflict(
    OwnerConflictResolutionRequest(
      conflictToken: token,
      operationId: hostPersistedOperationId,
      confirmed: true,
    ),
  );
}
```

`hostPersistedOperationId` must be a stable idempotency key generated and kept
by the host for that confirmation attempt.

## Start, pause, resume, and complete

Start, pause, resume, and complete a track:

```dart
String? activeTrackId;

Future<void> startTrip() async {
  if (!await preparePermissions()) return;

  try {
    final result = await tracking.startOrRecoverTrack(
      const TrackStartRequest(
        owner: TrackingOwner(
          userId: 'user-42',
          organizationId: 'organization-7',
        ),
        routeId: 'Morning delivery route',
        config: TrackingConfig(
          accuracy: TrackingAccuracy.high,
          movingInterval: Duration(seconds: 15),
          movingDistanceFilterMeters: 15,
          stationaryInterval: Duration(minutes: 2),
          stationaryDistanceFilterMeters: 75,
          mockLocationPolicy: MockLocationPolicy.flag,
          androidNotificationTitle: 'Trip recording is active',
          androidNotificationText: 'Tap to return to the app',
        ),
      ),
    );
    activeTrackId = result.trackId;
  } on TrackingNotReadyException {
    // Re-run preparePermissions() from the next user gesture.
    rethrow;
  } on TrackingConflictException {
    // A same-owner route is already active/resumable. Show Resume/Complete.
    rethrow;
  } on TrackingOwnershipException {
    // Another account/owner has unresolved local tracking state.
    rethrow;
  }
}

Future<void> pauseTrip() async {
  final id = activeTrackId;
  if (id == null) return;
  await tracking.pauseTrack(
    trackId: id,
    reason: 'user_paused',
  );
}

Future<void> resumeTrip() async {
  final id = activeTrackId;
  if (id == null) return;
  await tracking.resumeTrack(id);
}

Future<String?> completeTrip() async {
  final id = activeTrackId;
  if (id == null) return null;
  await tracking.completeTrack(
    trackId: id,
    reason: 'user_completed',
  );
  activeTrackId = null;
  return id;
}
```

`routeId` is optional application metadata. When supplied, the client trims
the value, replaces every whitespace run with `_`, and appends a UTC timestamp
with microsecond precision. For example, `Morning delivery route` becomes a
value such as `Morning_delivery_route_20260819_091530_123456`. The stored value
is available as `Track.routeId`, appears in route exports, and is used in the
default export filename. The database's internal `Track.id` remains an
independent lifecycle key.

Commands are serialized and scoped to a track ID. For a command that may be
retried, supply one stable, unique `operationId` for that logical pause or
completion. Do not reuse it for a later, separate pause. A completed track
cannot be resumed.

Use `startOrRecoverTrack()` when a Start button should safely recover the same
owner's active, paused, or interrupted route. Use `startNewTrack()` when the
user explicitly wants a fresh route; it throws `active_track_conflict` if
anything resumable already exists. The legacy `startTrack()` wrapper remains
available for older apps and keeps its start-or-recover behavior.

## Recommended UI state

Drive controls from `TrackerStatus.lifecycle` rather than maintaining a second
independent native-state flag.

| Lifecycle | Enable |
|---|---|
| `idle` | Start |
| `starting` | No repeated command |
| `tracking` | Pause, Complete |
| `paused` | Resume, Complete |
| `interrupted` or `failed` | Resume, Complete |
| `stopping` | No repeated command |

`watchCurrentTrack()` emits the stored active, paused, or interrupted track and
is useful for restoring UI state after an app restart:

```dart
final currentTrackSubscription = tracking.watchCurrentTrack().listen((track) {
  activeTrackId = track?.id;
});
```

## Optional upload integration

The plugin does not choose an HTTP client or backend protocol. Supply a
`TrackUploader` when you want durable ordered batches:

```dart
final tracking = await TrackingClient.open(
  owner: TrackingOwner(userId: userId, organizationId: organizationId),
  uploader: MyTrackUploader(),
);

class MyTrackUploader implements IdempotentTrackCompletionUploader {
  @override
  Future<TrackUploadAcknowledgement> uploadPoints(
    TrackUploadBatch batch,
  ) async {
    // POST batch.toMap() using your authenticated API client.
    // Make batch.idempotencyKey unique on the server.
    return TrackUploadAcknowledgement(
      acceptedThroughSequence: batch.lastSequence,
    );
  }

  @override
  Future<void> completeTrack(Track track) async {
    await completeTrackIdempotently(
      track: track,
      idempotencyKey: track.id,
    );
  }

  @override
  Future<void> completeTrackIdempotently({
    required Track track,
    required String idempotencyKey,
  }) async {
    // Send an idempotent completion request to your backend.
  }
}
```

Accepted points remain in a SQLite outbox until acknowledged. Retries use
persisted leases, bounded batches, exponential backoff, jitter, and stable
idempotency keys. Discovery and draining stay inside the bound owner scope.
Your server must still enforce idempotency and sequence semantics.

## Runtime configuration updates

An active owner-bound controller also implements
`TrackingConfigurationController`. Updates are validated, native producers are
fenced, pending journal events are drained, and a new immutable epoch is
activated before capture resumes:

```dart
final configurable = tracking as TrackingConfigurationController;
final result = await configurable.updateTrackingConfig(
  const TrackingConfig(accuracy: TrackingAccuracy.medium),
);
print('active configuration epoch: ${result.epoch.epochNumber}');
```

Individual `TrackingConfig` values continue to override only their matching
preset values. Existing points remain associated with their original epoch.

## Host application tests

Testing utilities are deliberately kept out of the normal runtime import:

```dart
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_background_location_tracker/flutter_background_location_tracker_testing.dart';

final fake = FakeTrackingController(
  owner: const TrackingOwner(userId: 'test-user', organizationId: 'test-org'),
);
```

The testing library also provides `DeterministicTrackingClock`, synthetic
walking/stationary routes, common permission fixtures,
`TemporaryTrackRepositoryFixture`, a faultable `FakeTrackerAdapter`, a
filesystem-free `FakeExportFileWriter`, and interrupted-session seeding. The
fake supports deterministic ready → Start → point → Pause → Resume → Complete
widget flows and records calls so tests can prove a readiness check did not
prompt or start native capture. See `example/test/widget_test.dart`.

### Provider, Riverpod, and Bloc

Keep the controller application-scoped regardless of state framework. The
package adds no dependency on any of them:

```dart
// Provider: create once above MaterialApp; do not auto-dispose while active.
Provider<TrackingController>.value(value: tracking, child: const App());

// Riverpod: expose the already-open owner-bound instance.
final trackingProvider = Provider<TrackingController>((ref) => tracking);

// Bloc: subscribe once, then translate package snapshots into app state.
subscription = tracking.sessionStream.listen(
  (session) => add(TrackingSessionChanged(session)),
);
```

Widgets should render `session.allowedActions`; framework state must not invent
a second lifecycle machine. Cancel UI subscriptions when widgets/blocs are
disposed, but dispose the application controller only after Pause or Complete.

## Disposing the client

Cancel your stream subscriptions and dispose the client only after the active
track has been paused or completed:

```dart
await statusSubscription.cancel();
await pointSubscription.cancel();
await activitySubscription.cancel();
await tracking.dispose();
```

`dispose()` deliberately throws while native tracking is active so the host
does not silently detach from a live session.

## Common issues

### `TrackingPermissionException`

Inspect `exception.state`. Check location services, precise location,
notification permission, `requiresSettings`, and `canRequestBackground`.

### `tracking_already_active` or `already_tracking`

Use one application-scoped controller and drive the UI from `sessionStream`.
Do not call native Start directly. Prefer `startOrRecoverTrack(...)` to reuse or
resume the same owner's route; use `resolveOwnerConflict(...)` only after an
explicit confirmation when the redacted blocker belongs to a previous owner.

### Export says only completed tracks are allowed

Complete the track before exporting, or explicitly set
`allowIncompleteTrackSnapshot: true` when a snapshot is intentional.

### No activity classification

Activity permission is separate from location permission. The route can still
record, but adaptive stationary detection stays conservative when motion data
is unavailable.

### Export is missing a pause-to-resume connection

This is expected in `preserveEvidenceSegments` and
`mergeAutomaticCallbackGaps`: a user pause, interruption, permission loss, or
overnight boundary is real evidence, not an automatic callback gap. Select
`connectAllChronologicalPoints` only when the UI clearly labels inferred
connectors and does not present their length as measured distance.
