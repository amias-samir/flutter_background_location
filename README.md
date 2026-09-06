# flutter_background_location_tracker

Durable, battery-aware route tracking for Android and iOS.

The plugin combines native location and activity APIs with ordered SQLite
storage, pause/resume lifecycle controls, mock-location evidence, adaptive
sampling, multi-day trips, and offline GeoJSON, KML, and GPX export.

> Background location is privacy-sensitive and controlled by the operating
> system. Callback intervals and process lifetime are never guaranteed. Test
> your exact configuration on real devices before releasing it.

## Start here

Use this package when your app needs a complete route from **Start** to
**Complete**, including background capture, route history, export, and
diagnostics.

| Need | Use |
|---|---|
| Single-day route recording | `TrackingClient.open()` |
| Multi-day journeys with End day / Continue trip | `TrackingClient.openWithTrips()` |
| Lifecycle UI state | `TrackingSessionSnapshot.allowedActions` |
| Permission setup | `checkReadiness()` then `requestNextPermission()` |
| Accuracy and battery behavior | `TrackingConfig(accuracy: ..., captureIntent: ...)` |
| Route display/export | `loadTrackBundle()`, `assembleTripRouteGeometry()`, `exportTrack()`, `exportTrip()` |

The recommended integration shape is simple:

```dart
final tracking = await TrackingClient.openWithTrips(
  owner: const TrackingOwner(
    userId: 'signed-in-user',
    organizationId: 'workspace-id',
  ),
  configuration: const TrackingConfiguration(
    recordRetentionPolicy: TrackRecordRetentionPolicy.keepAll,
    defaultTrackingConfig: TrackingConfig(
      accuracy: TrackingAccuracy.high,
      captureIntent: RouteCaptureIntent.vehicle,
      motionFusionMode: MotionFusionMode.lowPowerSensorFusion,
    ),
  ),
);

final readiness = await tracking.checkReadiness();
if (readiness.canStart) {
  await tracking.startTrip(
    const TripStartRequest(routeId: 'home_to_office'),
  );
}
```

From there, render Start, Pause, Resume, End day, Continue trip, and Complete
from `tracking.sessionStream`. Do not guess button state from local widget
variables.

## Features

### Capture

- Foreground and background route recording on Android and iOS.
- Android foreground service with a persistent tracking notification.
- Pause, resume, complete, End day, and Continue trip lifecycle support.
- Track history retention with `keepLatestOnly` or `keepAll`.

### Accuracy and evidence

- Activity classification for stationary, walking, running, bicycle, vehicle,
  and unknown states.
- Optional low-power step/significant-motion fusion and bounded
  accelerometer/gyroscope ambiguity probes.
- Mock/simulation evidence per location fix with allow, flag, or reject policy.
- Typed gap evidence for rejected fixes, lifecycle boundaries, and background
  callback interruptions.

### Routes and export

- Single-day `Track` routes and additive multi-day `Trip` journeys.
- Combined multi-day Trip map and GeoJSON/KML/GPX export.
- Persisted route presentation modes: recorded parts, connected days, or
  continuous presentation with labeled inferred connectors.
- Optional immutable derived geometry with explicit raw/derived map and export
  selection.
- User-defined export names and collision-safe file creation.

### Operations

- Durable, ordered SQLite persistence with crash recovery.
- Streams and plain Dart models with no state-management dependency.
- Optional application-supplied uploader with durable retry state.
- Coordinate-free diagnostics for setup, quality, and support reports.

## Platform support

| Platform | Minimum | Native implementation |
|---|---:|---|
| Flutter | 3.22 | Dart 3.4 or later |
| Android | API 21 | Fused Location Provider, Activity Recognition, foreground service |
| iOS | 13.0 | Core Location and Core Motion |

The Android plugin targets Java 17 and compile SDK 35; the bundled MapLibre
example CI uses JDK 21. iOS supports CocoaPods and Flutter's Swift Package
Manager integration.

## Installation

Add the package to your application:

```yaml
dependencies:
  flutter_background_location_tracker: ^0.1.2
```

Then run:

```shell
flutter pub get
```

Import the public library:

```dart
import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
```

## Minimal integration

The host application needs five package-level steps:

1. Add the Android manifest and iOS `Info.plist` configuration below.
2. Open one application-scoped `TrackingClient` for the authenticated owner.
3. Drive permission UI from `checkReadiness()` and request only its next action.
4. Drive Start, Pause, Resume, and Complete from `session.allowedActions`.
5. Export completed routes with `exportTrack()` and dispose at sign-out.

Create exactly one application-scoped controller for the signed-in owner. The
controller initializes storage/native state before it is returned, replays the
current session to new listeners, and keeps normal reads owner-scoped.

```dart
late final TrackingController tracking;
late final StreamSubscription<TrackingSessionSnapshot> sessionSubscription;

Future<void> configureTracking() async {
  const owner = TrackingOwner(
    userId: 'signed-in-user',
    organizationId: 'workspace-id',
  );
  tracking = await TrackingClient.open(owner: owner);
  sessionSubscription = tracking.sessionStream.listen((session) {
    // Drive every lifecycle button from session.allowedActions.
    print('${session.status.lifecycle}: ${session.currentTrack?.routeId}');
  });
}

Future<void> startRoute() async {
  final readiness = await tracking.checkReadiness();
  if (!readiness.canStart) {
    // From this visible button gesture, present readiness.nextAction.
    // Permission actions use requestNextPermission(); Settings actions use
    // openSettings(...). Recheck readiness before calling Start again.
    return;
  }
  await tracking.startNewTrack(
    const TrackStartRequest(
      owner: TrackingOwner(
        userId: 'signed-in-user',
        organizationId: 'workspace-id',
      ),
      routeId: 'Morning delivery route',
      config: TrackingConfig(accuracy: TrackingAccuracy.high),
    ),
  );
}

Future<void> stopUsingTracking() async {
  await sessionSubscription.cancel();
  await tracking.dispose(); // Pause or Complete an active route first.
}
```

The complete staged permission flow and platform declarations follow below.

| Core API | Use |
|---|---|
| `TrackingClient.open()` | Initialize and restore one owner-scoped controller |
| `TrackingClient.openWithTrips()` | Initialize Track controls plus multi-day Trip support |
| `TrackingController` | Control lifecycle, history, export, and deletion |
| `TrackingTripController` | Start, continue, complete, query, map, export, and delete Trips |
| `TrackingSessionSnapshot` | Render status and enabled actions |
| `TrackingReadiness` | Present the next permission or Settings step |
| `TrackingConfig` | Configure accuracy, sampling, and mock policy |
| `TrackQuery` / `TrackPage` | Load bounded route-history pages |
| `TripQuery` / `TripPage` | Load bounded user-visible multi-day journey pages |

## Multi-day Trip tracking

Use `TrackingClient.openWithTrips()` when one user-visible journey can span
several days. The returned `TrackingTripController` includes all normal Track
controls plus the additive Trip lifecycle, history, geometry, export, and
deletion APIs.

### Data model

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

### Open one owner-scoped Trip controller

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

### Start, end a day, continue, and complete

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

### Capture intent, motion evidence, and connected days

These settings solve different problems:

| Setting | Controls | Does not do |
|---|---|---|
| `accuracy` and individual sampling fields | Native request frequency, distance filter, and accepted uncertainty | Guarantee an OS callback interval |
| `captureIntent` | Moving-profile fallback when activity evidence is unknown or stale | Force a platform activity label |
| `motionFusionMode` | Which optional motion sensors may corroborate moving/stationary state | Derive latitude/longitude from compass, gyro, or acceleration |
| `routePresentation` | Whether truthful daily/lifecycle parts are drawn separately or joined | Recover the path travelled while capture was stopped |

`RouteCaptureIntent.walking`, `cycling`, and `vehicle` resolve unset moving
sampling values to a 3-second interval and 3 m filter. These explicit travel
intents remain in the moving profile even if a pocketed device is temporarily
classified as stationary. `adaptive` remains the battery-aware intent that may
enter stationary sampling. Explicit `movingInterval` and
`movingDistanceFilterMeters` values still win.

Vehicle capture also uses a bounded urban-visibility acceptance envelope:
`high` accepts reported horizontal uncertainty up to 35 m and `precised` up to
25 m. The provider still requests navigation-grade fixes. This avoids throwing
away most tunnel, pocket, or urban-canyon callbacks solely because they exceed
the walking-oriented 20/15 m limits. Pass an explicit
`maximumAcceptedAccuracyMeters` to make the envelope stricter or looser.

`MotionFusionMode.platformActivityOnly` is the compatibility default.
`lowPowerSensorFusion` adds step/pedometer and significant-motion evidence.
`enhancedSensorFusion` additionally permits short accelerometer/gyroscope
windows when evidence conflicts. Probes obey duration, cooldown, and hourly
duty-cycle limits. Compass and gyro are orientation/rotation evidence only;
the package never performs inertial dead reckoning.

Route presentation is persisted with the Trip:

- `separateRecordedParts` preserves every daily and lifecycle boundary;
- `connectDailyLegs` joins only boundaries between consecutive days;
- `continuousPresentation` joins all chronological accepted parts.

Connected modes add straight, typed `InferredRouteConnector` edges. Their
length is excluded from `Trip.measuredDistanceMeters`, because no locations
were captured along those edges. The stored default is used by the shared map
assembler and GeoJSON/KML/GPX Trip export; pass an explicit override only for a
temporary viewer/export choice.

Edges between accepted anchors in the same recorded segment are measured even
when rejected callbacks occurred between them—the exported line already uses
those anchors. Database schema 14 repairs older totals that excluded these
same-segment edges. It does not add inferred Pause, interruption, or overnight
connector distance.

Activity confidence is the platform's confidence in an activity label. It is
not GPS accuracy. Use `ActivitySnapshot.evidenceState`/`age` for freshness,
`TrackPoint.horizontalAccuracy` for location uncertainty in metres, and
`MotionEvidenceSnapshot` for the sources supporting the current motion state.

Feature-detect `TrackingQualityController` for coordinate-free accepted,
rejected, quality-run, visible-gap, lifecycle-boundary, activity-freshness,
and uncertainty-percentile diagnostics.

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

### Restore Trip UI after an application restart

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

### Deliberately continue a completed Trip

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

### Display or export the complete journey

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

### Delete a Trip

Only terminal `completed` or `failed` Trips can be deleted. Deletion removes
all owned legs, database artifacts, upload-outbox rows, package-managed export
snapshots, and matching native journal entries.

```dart
await tracking.deleteTrip(completedTripId);
```

Require an application-level confirmation before this irreversible action.
Active and suspended Trips must first be completed or otherwise resolved.

### Integration rules

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

## Platform configuration

### Android

#### Manifest

The plugin manifest is merged into the host app automatically. It contributes
the complete permission and component set shown below, so applications normally
must not duplicate it. Verify these entries in the merged release manifest if
your build customizes manifest merging:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-feature
        android:name="android.hardware.location.gps"
        android:required="false" />

    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />

    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

    <uses-permission android:name="android.permission.ACTIVITY_RECOGNITION" />
    <uses-permission android:name="com.google.android.gms.permission.ACTIVITY_RECOGNITION" />
    <uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
    <uses-permission
        android:name="android.permission.WRITE_EXTERNAL_STORAGE"
        android:maxSdkVersion="28" />

    <application>
        <service
            android:name="com.samir.flutter_background_location.LocationTrackingService"
            android:enabled="true"
            android:exported="false"
            android:foregroundServiceType="location"
            android:stopWithTask="false" />

        <receiver
            android:name="com.samir.flutter_background_location.ActivityRecognitionReceiver"
            android:enabled="true"
            android:exported="false" />

        <receiver
            android:name="com.samir.flutter_background_location.TrackingBootReceiver"
            android:enabled="true"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.BOOT_COMPLETED" />
                <action android:name="android.intent.action.MY_PACKAGE_REPLACED" />
            </intent-filter>
        </receiver>
    </application>
</manifest>
```

Do not remove `ACCESS_BACKGROUND_LOCATION` or the `location` foreground-service
type. The package intentionally keeps the native
`com.samir.flutter_background_location` namespace for upgrade compatibility.

#### Required runtime state

`startTrack()` and `resumeTrack()` refuse to start native background capture
until all required conditions are true:

- Location Services are enabled.
- **Precise** foreground location is granted.
- Background location is reported as **Allow all the time**.
- Notification permission is granted on Android 13 and later.
- The command is initiated while an Activity is visible.

Activity Recognition permission is requested on Android 10 and later. If it is
denied, route capture can continue, but activity classification becomes unknown
and the battery-saving stationary transition remains conservative.

#### Permission sequence by Android version

1. Start the flow only after the user taps a visible Start/Enable Tracking
   control. The plugin requests `ACCESS_COARSE_LOCATION` and
   `ACCESS_FINE_LOCATION` together. On Android 12 and later the user must select
   **Precise**, not Approximate.
2. On Android 9 and earlier, the older permission model grants background
   capability with the foreground location grant.
3. On Android 10, the plugin makes the separate background permission request;
   the system dialog can offer **Allow all the time**.
4. On Android 11 and later, the runtime dialog cannot grant **Allow all the
   time**. When `requiresSettings` is true, show an educational screen, call
   `openAppSettings()`, and ask the user to choose Location → **Allow all the
   time** and keep **Use precise location** enabled.
5. On Android 13 and later, the user must also allow notifications so the
   foreground-service notification remains visible.
6. After the app resumes from Settings, read permissions again. Enable Start
   only when `state.canTrackInBackground` is true.

Android 11 and later ignore a combined foreground/background runtime request,
which is why permission elevation must be incremental. Android 12 and later
also restrict foreground-service starts from the background. On Android 14 and
later, the system validates location access when the location foreground
service starts. Always call `startTrack()` from a visible screen after a clear
user action.

Android does not let an app grant **Allow all the time** on the user's behalf.
The plugin can request or open the correct Settings page, but the user must make
the final permission choice.

See Android's official guides for [runtime location
permission](https://developer.android.com/develop/sensors-and-location/location/permissions/runtime),
[background location](https://developer.android.com/develop/sensors-and-location/location/permissions/background),
and [foreground-service startup](https://developer.android.com/develop/background-work/services/fgs/launch).

Google Play applies additional policy requirements to background location and
foreground services. The host application is responsible for its prominent
disclosure, privacy policy, Data safety answers, permission flow, Play Console
declaration, and demonstrating that background access is core functionality.

### iOS

#### Background capability

In Xcode, enable:

**Runner target → Signing & Capabilities → Background Modes → Location
updates**

This adds `location` to `UIBackgroundModes`. The plugin validates the background
mode before starting.

#### `Info.plist`

Add all of these keys to the host application's `Info.plist`. Replace the sample
strings with clear, product-specific explanations of what is recorded, when it
continues in the background, and how the user stops it:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Location is used to record your route while a trip is active.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Your active trip continues to record when the app is in the background.</string>
<key>NSMotionUsageDescription</key>
<string>Motion helps adjust location frequency and reduce battery use.</string>
<key>UIBackgroundModes</key>
<array>
    <string>location</string>
</array>
```

`NSLocationWhenInUseUsageDescription` is required for the first authorization
stage. `NSLocationAlwaysAndWhenInUseUsageDescription` is required before the
plugin can request Always access. `NSMotionUsageDescription` is required for
`CMMotionActivityManager`; without motion access, tracking remains on the
conservative moving profile.

The deprecated `NSLocationAlwaysUsageDescription` key is not used because this
package supports iOS 13 and later and checks the modern
`NSLocationAlwaysAndWhenInUseUsageDescription` key.

#### Required runtime state and permission sequence

The plugin requires Location Services, **Precise Location**, and **Always**
authorization before starting background tracking:

1. After an explicit user action, call `permissions(request: true)`. When the
   status is not determined, iOS presents the When In Use prompt using
   `NSLocationWhenInUseUsageDescription`.
2. The user must first choose **Allow While Using App**. **Allow Once** is not
   enough for elevation because iOS can ignore the immediate Always request
   after a temporary grant.
3. Explain why the active route must continue with the screen locked or app in
   the background. When `canRequestBackground` is true, call
   `permissions(request: true)` again. The plugin calls
   `requestAlwaysAuthorization()`.
4. The user must choose **Change to Always Allow** when iOS presents the
   elevation prompt. The timing and wording of system prompts are controlled by
   iOS.
5. If the user keeps When In Use, denies access, or disables Precise Location,
   direct them to Settings and recheck when the app becomes active.
6. Start or resume only when `state.canTrackInBackground` is true.

Do not loop permission requests or present an Always prompt without your own
educational UI. Users can change authorization or Precise Location at any time,
so recheck before every start/resume and handle later revocation.

iOS does not let an app grant Always authorization itself. The plugin requests
the elevation, but only the user can approve **Change to Always Allow** or select
Always in Settings.

See Apple's official documentation for [requesting location
authorization](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services),
[`requestAlwaysAuthorization()`](https://developer.apple.com/documentation/corelocation/cllocationmanager/requestalwaysauthorization()),
[background location updates](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background),
and [`NSMotionUsageDescription`](https://developer.apple.com/documentation/bundleresources/information-property-list/nsmotionusagedescription).

#### Active, paused, and terminated behavior

The native location service runs only while a route is active:

| Route state | Android | iOS |
|---|---|---|
| Active | Foreground service and location/activity requests run | `CLLocationManager` runs; iOS 17+ also holds a `CLBackgroundActivitySession` |
| Paused | Requests, notification, and service stop; the route remains resumable | Location, motion, and background-activity sessions stop; the route remains resumable |
| Resumed | A foreground service and native requests start again | Location, motion, and a new background-activity session start again |
| Completed | Native capture and the service stop, and native active-session state is cleared | All native updates/sessions stop, and native active-session state is cleared |

Putting an active app in the background or locking the screen is not a pause.
With Always + Precise authorization and `UIBackgroundModes/location`, the
active iOS manager continues collecting and journals fixes even if Flutter is
temporarily suspended. The native manager is process-scoped, so rebuilding a
Flutter engine or scene does not label the route interrupted.

On Android, active tracking holds a short-scoped partial wake lock for the
duration of native capture and releases it on Pause, End day, Complete, service
failure, interruption, or service destruction. Motion fusion prefers wake-up
step, significant-motion, accelerometer, gyro, and rotation-vector sensors when
the device provides them, which helps screen-off and pocketed routes keep fresh
motion evidence. The wake lock does not improve satellite visibility; users may
still need to disable aggressive OEM battery restrictions for long precise
routes.

User force-quit is different from minimizing. iOS stops standard continuous
location updates when the user swipes the app away, and an application cannot
override that decision. After a later launch, the plugin reports the route as
interrupted and requires an explicit resume; it never silently marks that route
complete. See Apple's [`startUpdatingLocation()`
documentation](https://developer.apple.com/documentation/corelocation/cllocationmanager/startupdatinglocation())
and [`CLBackgroundActivitySession`](https://developer.apple.com/documentation/corelocation/clbackgroundactivitysession-3mzv3).

For applications that accept reduced, OS-controlled sampling in exchange for
best-effort process relaunch, opt into the distinct significant-change mode:

```dart
const config = TrackingConfig(
  iosTerminationRecoveryMode:
      IosTerminationRecoveryMode.significantChange,
);
```

This mode is not equivalent to continuous GPS. On a relaunch it preserves the
same track identity, reports `recoveredFromTermination`, and labels the
possible missing interval instead of inventing points. The default
`IosTerminationRecoveryMode.interrupted` keeps continuous tracking semantics
and requires manual Resume after termination. User force-quit remains
non-recoverable in both modes until the user opens the app. A host that creates
its Flutter engine lazily can call
`FlutterBackgroundLocationPlugin.prepareTerminationRecovery()` from its iOS
Core Location launch path before attaching UI; recovered capture also restarts
motion fusion so activity evidence does not remain stale after relaunch.
Physical qualification is still required for every supported device/OS bucket
before making a recovery claim.

## Detailed integration guide

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

Read recorded-route summaries without loading every point:

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

## Reading tracks and route geometry

The package stores points because timestamps, accuracy, activity, mock
evidence, validation results, and upload state are point-level facts. It exposes
segments so the application can render the stored route as line geometry.

```dart
final page = await tracking.listTrackPage(TrackQuery(limit: 25));
final bundle = await tracking.loadTrackBundle(page.items.first.id);

final routeSegments = bundle.segments
    .map(
      (segment) => segment.points
          .where((point) => point.accepted)
          .map((point) => (point.latitude, point.longitude))
          .toList(growable: false),
    )
    .where((coordinates) => coordinates.isNotEmpty)
    .toList(growable: false);
```

You can draw each item in `routeSegments` as a separate polyline. This avoids
connecting the location before a pause to the location after a resume.

Map rendering is deliberately not a package dependency. The example app shows
how to display recorded tracks with `maplibre_gl` and the OpenFreeMap Liberty
street style; applications can use MapLibre, Google Maps, Apple MapKit, or any
other renderer.

### Optional derived geometry

Raw point coordinates are immutable. To create a separately versioned,
post-capture smoothed route, use the additive geometry capability:

```dart
final geometry = tracking as TrackingGeometryController;
final run = await geometry.deriveGeometry(
  completedTrackId,
  request: const DerivedGeometryRequest(
    name: 'display_smoothing',
    algorithmVersion: '1',
    smoothingFactor: 0.35,
  ),
);

final mapBundle = await geometry.loadTrackGeometry(
  completedTrackId,
  geometry: TrackGeometrySelection.derived(run.id),
);
```

Each run stores its algorithm, version, configuration, source snapshot,
optional map-data provenance, and derivation time. Smoothing restarts at every
pause/resume segment. Deleting a run deletes only derived rows; loading raw
geometry after deletion returns the original route unchanged. Hosts can add a
separate map-matching integration by implementing the repository capability;
no proprietary map service is required by this package.

## Exporting a completed route

For long or densely sampled routes, prefer the bounded V2 exporter. Reuse the
same initialized repository supplied to `TrackingClient`; do not open a second
database owner solely for export.

```dart
final exporter = TrackExportServiceV2(
  repository: repository,
  owner: const TrackingOwner(
    userId: 'signed-in-user',
    organizationId: 'organization',
  ),
);
final operation = await exporter.exportTrackV2(
  TrackExportRequest(
    trackId: completedTrackId,
    format: TrackExportFormat.gpx,
    fileName: 'warehouse inspection',
  ),
);
final progress = operation.progress.listen((value) {
  print('${value.pointsWritten} points, ${value.bytesWritten} bytes');
});
try {
  final exported = await operation.result;
  print(exported.destination.contentUri ??
      exported.destination.localFilePath);

  final shareFile = await exporter.prepareExportForSharing(exported);
  try {
    // Pass shareFile.path to the host application's sharing package.
  } finally {
    await shareFile.delete();
  }
} finally {
  await progress.cancel();
}
```

To export a completed derived run, set
`TrackExportOptions(geometry: TrackGeometrySelection.derived(run.id))`. The V2
GeoJSON/KML/GPX output labels its source as `derived:<run-id>`. Raw remains the
default and is labeled `raw`. Derived exports intentionally reject
`includeRejectedPoints`, because rejected points have no derived coordinates.

On Android 10+, `contentUri` is the reopenable MediaStore handle and
`displayPath` is informational only. On iOS and pre-scoped-storage Android,
`localFilePath` is present instead. Exactly one of those two access handles is
set. The package adds no sharing dependency.

The compatibility exporter below materializes a complete route and returns its
legacy required `path`. Keep it for existing integrations and bounded routes.

Ask the user for a name, then pass the selected format and name to
`exportTrack()`. The correct extension is added or repaired automatically.

```dart
Future<TrackExportResult> exportCompletedTrip({
  required String trackId,
  required String userEnteredName,
  required TrackExportFormat format,
}) {
  return tracking.exportTrack(
    trackId: trackId,
    format: format,
    fileName: userEnteredName,
  );
}

final completedTrackId = await completeTrip();
if (completedTrackId == null) return;

final result = await exportCompletedTrip(
  trackId: completedTrackId,
  userEnteredName: 'warehouse-inspection-route',
  format: TrackExportFormat.geoJson,
);

print(result.path);
print('${result.pointCount} points in ${result.segmentCount} segments');
```

The default destination is:

- Android: `Download/flutter_background_location`;
- iOS: the app's `Documents/flutter_background_location` directory, or the
  platform-provided downloads directory when available.

Android 10 and later use MediaStore and do not need broad storage permission.
For Android 9 and earlier, public Downloads access follows legacy Android
storage rules. The plugin manifest declares `WRITE_EXTERNAL_STORAGE` only up to
API 28, and the default writer returns `export_storage_permission_required`
unless the host has already requested that permission from the user's explicit
Export action. If you do not want to request legacy storage permission, inject a
custom `ExportFileWriter` for those releases.

If a file already exists, the package adds `_1`, `_2`, and so on. Export files
are plaintext and may reveal sensitive routes. Delete temporary exports after
sharing:

```dart
await tracking.deleteExport(result);
```

Completed tracks export by default. An explicit point-in-time snapshot of an
active or paused track requires opt-in:

```dart
const options = TrackExportOptions(
  allowIncompleteTrackSnapshot: true,
  includeGeoJsonPointFeatures: true,
);
```

### Export geometry

- `TrackExportOptions.geometryContinuity` selects raw evidence, proven
  automatic-gap merging, or explicit connect-all presentation.
- GeoJSON uses a `LineString` for one presentation part and a
  `MultiLineString` for multiple parts.
- GeoJSON segments with fewer than two accepted coordinates are omitted from
  line geometry. Optional point features can preserve them for diagnostics.
- KML writes a line per multi-point segment and a point for a one-fix segment.
- GPX writes one `<trkseg>` per stored segment, including one-fix segments.
- Rejected points can be included as diagnostics but never enter route
  geometry when their coordinates are invalid or non-finite.

### Abort, delete, and erase are different operations

`Complete` retains a successful route. The additive `TrackingPrivacyService`
keeps destructive/exceptional actions explicit and owner-scoped:

| Action | Route record | Native journal | Upload outbox | Managed exports |
|---|---|---|---|---|
| Abort | Retained as cancelled audit route | Selected track cleared | Removed | Retained |
| Delete | Terminal route removed | Selected track cleared | Removed | Explicit choice |
| Erase | Selected route removed | Selected track cleared | Removed | Removed when managed |

Construct it with the same initialized repository, tracker adapter, owner, and
V2 export service used by the application-scoped tracking owner:

```dart
final privacy = TrackingPrivacyService(
  repository: repository,
  tracker: trackerAdapter,
  owner: currentOwner,
  managedExports: exporter,
);

await privacy.abortCurrentTrack(
  const AbortTrackRequest(reason: 'operator_cancelled'),
);

await privacy.deleteRecordedTrack(
  DeleteTrackRequest(
    trackId: selectedTrack.id,
    deleteManagedExports: true,
    confirmed: true, // Set only after explicit host UI confirmation.
  ),
);
```

Retry a command with the same optional `operationId` for idempotent recovery.
Erase is logical deletion across package-managed storage; SQLite and flash
hardware do not provide a physical secure-erasure guarantee, and the package
cannot remove a route file copied by another application or user.

## Retaining track history

The default `keepAll` policy retains every recorded route so it remains
available in track history:

```dart
const TrackingConfiguration(
  recordRetentionPolicy: TrackRecordRetentionPolicy.keepAll,
);
```

Choose `keepLatestOnly` when the product should discard older routes as soon as
a new route starts:

```dart
const TrackingConfiguration(
  recordRetentionPolicy: TrackRecordRetentionPolicy.keepLatestOnly,
);
```

Retention is selected when the client is created. Do not dispose and recreate
the client while native tracking is active.

### Deleting a selected recorded route

Delete an individual completed or failed route with:

```dart
await tracking.deleteTrack(trackId);
```

The SQLite foreign-key relationships cascade the deletion to the route's
segments, points, health events, lifecycle operations, pending commands, and
upload-outbox rows. Active, paused, interrupted, starting, and stopping tracks
are rejected because they may still be running or resumable. This operation is
permanent, so export or upload the route first when another copy is required.

## Tracking configuration

Use the `accuracy` preset for a complete battery/precision profile. `high` is
the default and now favors dense, navigation-grade route capture:

```dart
const balanced = TrackingConfig(accuracy: TrackingAccuracy.medium);

const customized = TrackingConfig(
  accuracy: TrackingAccuracy.low,
  locationAccuracy: TrackingAccuracy.high,
  movingInterval: Duration(seconds: 20),
  movingDistanceFilterMeters: 10,
);
```

Individual values take precedence over the preset. In `customized`, the native
provider uses high accuracy and the moving interval/filter use the supplied
values, while stationary values still come from the low profile.

| Preset | Moving interval | Moving filter | Native request | Stationary interval | Stationary filter | Accepted accuracy |
|---|---:|---:|---|---:|---:|---:|
| `low` | 20 seconds | 20 m | Balanced / nearest 10 m | 2 minutes | 75 m | 100 m |
| `medium` | 10 seconds | 10 m | High / best | 1 minute | 50 m | 60 m |
| `high` (default) | 5 seconds | 5 m | High / navigation | 20 seconds | 20 m | 20 m |
| `precised` | 3 seconds | 3 m | High / navigation | 15 seconds | 10 m | 15 m |

Android and iOS translate the native request to the closest platform accuracy;
the table shows Android/iOS terminology. Presets are starting points, not
callback guarantees or universal recommendations. The accepted-accuracy column
is the preset's `maximumAcceptedAccuracyMeters`; it is available directly as,
for example, `TrackingAccuracy.high.maximumAcceptedAccuracyMeters`.

| Option | Default | Purpose |
|---|---:|---|
| `accuracy` | `high` | Supplies all preset sampling and accepted-accuracy values |
| `locationAccuracy` | `precised` for the default `high` preset | Overrides only Android/iOS native request accuracy |
| `movingInterval` | 5 seconds | Requested interval while moving |
| `movingDistanceFilterMeters` | 5 m | Minimum moving displacement |
| `stationaryInterval` | 20 seconds | Requested interval while stationary |
| `stationaryDistanceFilterMeters` | 20 m | Minimum stationary displacement |
| `maximumAcceptedAccuracyMeters` | 20 m | Reject fixes with poorer reported accuracy |
| `maximumPlausibleSpeedMetersPerSecond` | 70 m/s | Flag implausible point-to-point speed |
| `stationaryConfirmationDuration` | 90 seconds | Still evidence required before low-power mode |
| `stationaryProbeDisplacementMeters` | 30 m | GPS displacement check for stationary entry/exit |
| `stationaryConfidenceThreshold` | 75 | Minimum still confidence |
| `movingConfidenceThreshold` | 60 | Minimum movement confidence |
| `movingConfirmationCount` | 1 | Movement events required to exit stationary mode |
| `activityRecognitionInterval` | 5 seconds | Requested native activity update interval |
| `activityFreshnessThreshold` | 30 seconds | Expire stale activity labels and use the moving fallback |
| `motionEvidenceFreshness` | 30 seconds | Expire stale fused-motion evidence |
| `maximumProviderFixAge` | 5 minutes | Reject genuinely stale provider fixes while retaining delayed background batches |
| `mockLocationPolicy` | `flag` | Allow, flag, or reject detected mock fixes |
| `largeGapThreshold` | 5 minutes | Flag long gaps between accepted fixes |
| `batchPointCount` | 25 | Point threshold for an optional uploader |
| `batchMaxAge` | 2 minutes | Time threshold for an optional uploader |
| `iosTerminationRecoveryMode` | `interrupted` | Standard/manual recovery or opt-in significant-change relaunch semantics |

Operating systems may batch, delay, coalesce, or skip callbacks. Shortening an
interval does not guarantee that frequency. `high` and especially `precised`
can materially increase battery use and should be enabled only when dense route
geometry is necessary. On Android, the host may offer a user-initiated shortcut
to battery-optimization settings, but must not imply that exemption is required
or automatically granted.

## Activity and battery behavior

Native motion APIs report the best available activity class. They do not prove
that the device owner is a driver, passenger, or rider. Cycling is the closest
standard two-wheeler signal; a motorcycle or scooter commonly appears as
`inVehicle`, not `onBicycle`.

The plugin enters the stationary profile only after sustained, confident still
activity plus low GPS displacement. It returns to moving mode after movement
evidence or sufficient displacement. If activity permission or reliable motion
evidence is unavailable, it remains on the moving profile.

Battery results depend on the device, OS version, OEM policy, satellite and
network conditions, route, screen use, and configuration. Measure route
fidelity and battery drain together on the same devices your users carry.

### Bounded adaptive policy

Adaptive changes are disabled unless the host constructs a versioned policy.
The default policy mode is `shadow`: it reports a proposed profile without
changing native capture. Fidelity bounds cap every interval/filter and the
engine always preserves the static configuration's
`maximumAcceptedAccuracyMeters` and `mockLocationPolicy`.

```dart
final engine = AdaptiveBatteryPolicyEngine(
  staticConfig: const TrackingConfig(accuracy: TrackingAccuracy.high),
  policy: const AdaptiveBatteryPolicy(
    version: 1,
    mode: AdaptiveBatteryMode.shadow,
    bounds: AdaptiveFidelityBounds(
      leastAccurateProfile: TrackingAccuracy.medium,
      maximumMovingInterval: Duration(seconds: 30),
      maximumMovingDistanceFilterMeters: 25,
      maximumStationaryInterval: Duration(minutes: 3),
      maximumStationaryDistanceFilterMeters: 100,
    ),
  ),
);
final coordinator = AdaptiveTrackingCoordinator(
  controller: tracking as TrackingConfigurationController,
  engine: engine,
);
final decision = await coordinator.observe(
  AdaptiveBatteryObservation(
    observedAt: DateTime.now(),
    batteryPercent: batteryPercent,
    charging: charging,
    lowPowerMode: lowPowerMode,
  ),
);
print(decision.toRedactedMap());
```

Move to `AdaptiveBatteryMode.apply` only after shadow traces and physical
battery/route benchmarks justify it. Applied transitions use immutable runtime
configuration epochs, minimum residence time, and a maximum transition rate.
`disableAndRestore()` returns to the static policy through the same atomic
epoch path.

## Mock-location interpretation

Every point exposes `mockAssessment`:

- `detected`: the operating system marked this exact fix as mocked or
  simulated;
- `notDetected`: the signal was available and clear for this fix;
- `unavailable`: the signal was unavailable for this fix.

Android uses `Location.isMock` or the legacy mock-provider flag. On iOS 15 and
later, the plugin reads `CLLocation.sourceInformation.isSimulatedBySoftware`.

`notDetected` is evidence, not proof that a coordinate is genuine. Rooted or
jailbroken devices, external accessories, GNSS/RF spoofing, and other methods
may evade platform signals. Do not use this value as the sole fraud or safety
decision.

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

## Lifecycle limits

| Scenario | Android | iOS |
|---|---|---|
| Normal background or screen lock while active | Continues in the foreground service with an active-capture partial wake lock; motion fusion prefers wake-up sensors when available | Continues with Core Location background mode; iOS 17+ background-activity session is held |
| Route paused | Service and native requests are stopped | Location, motion, and background-activity sessions are stopped |
| Route resumed | Service and requests are recreated | Location, motion, and background-activity sessions are recreated |
| Route completed | Service, notification, and native requests are stopped | All native updates and sessions are invalidated |
| Removed from recent apps | Usually continues; OEM-dependent | Swiping away is a user force-quit and stops tracking |
| OS process termination | Best-effort service/session recovery | Route is retained as interrupted and can be explicitly resumed after launch |
| Android Force stop | Cannot be bypassed | Not applicable |
| Reboot | Best-effort restoration; OEM-dependent | The app must be launched to restart this tracker |

Test backgrounding, screen lock, recent-task removal, OS process death,
force-stop/force-quit, permission changes, and reboot as separate scenarios.

## Storage, security, and privacy

SQLite is the route source of truth. A native acknowledgement-based journal
also protects fixes captured before Dart commits them. Native rows are removed
only after the Dart database write succeeds.

The default SQLite stores are not SQLCipher-encrypted. iOS file protection does
not replace application-level database encryption. Inject an approved
`TrackRepository` if your threat model requires encrypted route storage and
validate its key lifecycle independently.

Host applications should:

- show an explicit in-app tracking indicator;
- explain why background and motion access are needed;
- avoid logging coordinates or export contents;
- apply a documented retention policy;
- protect uploader authentication and transport;
- delete plaintext exports after use;
- provide a clear way to pause and complete tracking.

Entries named `sqlite_autoindex_*` are SQLite's internal indexes for primary
key and unique constraints. They are not extra schemas and are not created once
per tracking session.

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

## Example application

See the
[`example/lib/main.dart`](https://github.com/amias-samir/flutter_background_location/blob/main/example/lib/main.dart)
sample for a complete Material example with:

- staged permission recovery;
- Start, Pause, Resume, End day, and Complete Trip button states;
- configurable retention policy;
- live status, activity, and point data;
- one recorded-Trip history item with daily leg/segment/gap summaries;
- GeoJSON, KML, and GPX naming/export;
- MapLibre whole-Trip display with a street-map style, gap markers, and an
  explicit connect-all toggle.

## Production checklist

- Use product-specific permission and notification text.
- Review App Store and Google Play background-location requirements.
- Test on physical Android and iOS devices; simulators are insufficient.
- Measure multi-hour route fidelity and battery drain.
- Test offline capture and later upload recovery.
- Test denied, revoked, reduced-accuracy, and disabled-service states.
- Test OEM battery restrictions and Android reboot restoration.
- Test iOS backgrounding and user force-quit separately.
- Validate every export in an independent GeoJSON/XML reader.
- Perform a privacy and security review before collecting real user routes.

---

## 🥟 Support this project

> **Did this plugin save you development time or help your application?**
> Your support helps fund maintenance, platform updates, testing on real
> devices, and new features for the Flutter community.

<p align="center">
  <a href="https://buymemomo.com/firantey">
    <img
      src="https://img.shields.io/badge/BUY_ME_A_MOMO-SUPPORT_FIRANTEY-FF6B35?style=for-the-badge&amp;labelColor=7C2D12"
      alt="Support Firantey on Buy Me a MOMO"
      height="44"
    />
  </a>
</p>

<p align="center">
  <strong>💛 One plate of MOMO helps keep this plugin maintained and improving.</strong>
</p>

**Support link:** [buymemomo.com/firantey](https://buymemomo.com/firantey)

## License

See the
[MIT license](https://github.com/amias-samir/flutter_background_location/blob/main/LICENSE).
