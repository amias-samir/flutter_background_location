# flutter_background_location

Foreground and background route tracking for Android and iOS. The package
combines native location and motion APIs with ordered SQLite storage,
pause/resume segments, mock-location signals, adaptive sampling, and offline
GeoJSON, KML, and GPX export.

> This implementation still requires real-device route, lifecycle, OEM, and
> battery validation before production rollout. Mobile operating systems do
> not guarantee exact callback intervals or indefinite process survival.

## Features

- Android location foreground service with a persistent notification.
- iOS Core Location updates using the `location` background mode.
- Motion classification: stationary, walking, running, cycling, motorized
  vehicle, and unknown.
- Moving and stationary sampling profiles with hysteresis to reduce GPS use.
- Platform mock/simulation evidence stored with every point.
- One logical track across multiple pause/resume periods.
- A new segment on every resume, with no false distance across pause gaps.
- Transactional, monotonic point sequences and local SQLite persistence.
- Crash-durable pause and completion intents reconciled on the next launch.
- Native fix journaling before Flutter delivery, with acknowledgement only
  after the route database commit succeeds.
- Accepted/rejected points, accuracy checks, speed flags, and gap flags.
- Offline GeoJSON `MultiLineString`, segmented KML, and GPX 1.1 export.
- Optional injectable uploader backed by a leased SQLite outbox, persisted
  retry/backoff state, byte/count limits, and idempotency keys.
- Streams and plain Dart contracts; no host state-management dependency.

## Requirements

| Platform | Minimum |
|---|---|
| Flutter | 3.22 |
| Dart | 3.4 |
| Android | API 21, Java 17 |
| iOS | 13.0 |

The Android library compiles against SDK 35 and uses Android Gradle Plugin
8.6.1 and Kotlin 1.9.24.

The iOS plugin supports both CocoaPods and Flutter's Swift Package Manager
integration.

## Installation

```yaml
dependencies:
  flutter_background_location:
    path: ../flutter_background_location
```

Then run `flutter pub get`.

## Host app setup

### Android

The plugin manifest contributes coarse/fine/background location, location
foreground-service, notification, activity-recognition, boot, and wake-lock
permissions. It also registers the foreground service and boot receiver.

Start tracking only from a visible screen after a clear user action. Android
12+ restricts foreground-service starts from the background, and Android 14+
checks location permission when the service starts.

On Android 11+, the first permission dialog normally cannot grant “Allow all
the time.” If `TrackingPermissionState.requiresSettings` is true, explain the
setting, call `openAppSettings()`, and retry after the user returns. Background
location also requires an appropriate Play policy declaration when distributed
through Google Play.

### iOS

Enable **Signing & Capabilities → Background Modes → Location updates** and add
these values to the host target's `Info.plist`:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Location is used to record your active route.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Location is recorded while an active route continues in the background.</string>
<key>NSMotionUsageDescription</key>
<string>Motion is used to reduce GPS and battery usage while stationary.</string>
<key>UIBackgroundModes</key>
<array>
    <string>location</string>
</array>
```

Use product-specific text that tells the user exactly why tracking continues
with the screen locked. The default configuration requires precise, Always
location authorization for background sessions. Permission elevation is
staged: after When In Use is granted, explain the background need and call the
permission/start action again to request Always access.

## Usage

```dart
import 'package:flutter_background_location/flutter_background_location.dart';

final tracking = FieldTrackingClient(
  configuration: const FieldTrackingConfiguration(
    databaseName: 'field_routes.sqlite',
  ),
);

await tracking.initialize();

tracking.statusStream.listen((status) {
  print('lifecycle=${status.lifecycle.name}');
});

tracking.activityStream.listen((activity) {
  print('activity=${activity.type.value} confidence=${activity.confidence}');
});

tracking.pointStream.listen((point) {
  print('sequence=${point.sequence} mock=${point.mockAssessment.name}');
});

final trackId = await tracking.startTrack(
  userId: 'user-42',
  organizationId: 'organization-7',
  patrolId: 'patrol-9',
  config: const TrackingConfig(
    movingInterval: Duration(seconds: 15),
    movingDistanceFilterMeters: 15,
    stationaryInterval: Duration(minutes: 2),
    stationaryDistanceFilterMeters: 75,
    mockLocationPolicy: MockLocationPolicy.flag,
  ),
);

await tracking.pauseTrack(trackId: trackId);

// This may happen the next day or after a new FieldTrackingClient is created.
await tracking.resumeTrack(trackId);

await tracking.completeTrack(trackId: trackId);
```

Commands are serialized and scoped to a track ID. Optional `operationId`
values make pause and completion retries idempotent. A completed track is no
longer resumable.

### Export

```dart
final result = await tracking.exportTrack(
  trackId: trackId,
  format: TrackExportFormat.gpx,
);

print(result.path);

// Remove the plaintext artifact when it is no longer needed.
await tracking.deleteExport(result);
```

Completed tracks export by default. To create an explicit point-in-time
snapshot of an active or paused track, pass
`TrackExportOptions(allowIncompleteTrackSnapshot: true)`.

GeoJSON route geometry omits segments with fewer than two accepted points from
the `MultiLineString`, because a GeoJSON line cannot contain one point. Those
segments are preserved as Point features even when optional point properties
are disabled. KML emits a Point, and GPX preserves the one-point `<trkseg>`.
Rejected rows with invalid or non-finite coordinates can be included for
diagnostics, but are never inserted into route geometry.

## Mock-location interpretation

The API intentionally reports:

- `detected`: the OS marked this exact fix as mocked/simulated.
- `notDetected`: the OS signal was available and was clear.
- `unavailable`: the signal was not available for this exact fix.

`notDetected` does **not** prove a location is genuine. Rooted/jailbroken
devices, external accessories, RF/GNSS spoofing, or other techniques may evade
platform signals. Android uses `Location.isMock` (or the legacy mock-provider
flag). iOS uses `CLLocation.sourceInformation.isSimulatedBySoftware` when
available on that exact iOS 15+ fix.

Choose `MockLocationPolicy.allow`, `flag`, or `reject`. Rejected fixes remain in
the database for diagnostics but do not contribute to route geometry or
distance.

## Activity interpretation and battery use

Activity recognition is best-effort device context, not proof that the user is
the driver, passenger, or rider. Standard Android/iOS motion APIs distinguish
cycling from a general motorized vehicle but do not reliably distinguish a
motorcycle or scooter from a car. Motorized two-wheelers may therefore appear
as `inVehicle`.

Entering stationary mode requires sustained high-confidence still activity and
low displacement across multiple acceptable GPS fixes. If that corroboration,
motion permission, or the motion source is unavailable, location tracking stays
on the conservative moving profile. Battery consumption depends on the device,
OS, signal conditions, route, accuracy, intervals, OEM policy, and
screen/network activity. Tune `TrackingConfig` only after same-device route
fidelity and battery-control tests.

## Platform lifecycle limits

| Scenario | Android | iOS |
|---|---|---|
| Normal background / screen lock | Foreground-service support | Core Location background mode |
| Removed from recent apps | Usually continues; OEM-dependent | App-switcher force-quit stops tracking |
| OS process termination | Best-effort service/session recovery | Standard continuous updates resume only after the app launches |
| System-settings Force stop | Cannot be bypassed | N/A |
| Reboot | Best-effort restoration; device/OEM test required | The app must be launched to restart this tracker |

Never describe one test simply as “force-close.” Test backgrounding, screen
lock, recent-task removal, OS process death, user force-stop/force-quit, and
reboot separately.

## Storage and privacy

SQLite is the source of truth. Points are stored one row at a time before an
optional upload, and resume creates a separate segment while preserving the
global point sequence. Each platform also keeps an acknowledgement-based native
handoff journal so a captured fix is not lost between native delivery and the
Dart database commit. Android places it in the app's no-backup directory; iOS
uses Application Support with backup exclusion and file protection. Both have
explicit safety bounds and stop capture visibly instead of silently evicting
unacknowledged fixes.

Ordinary `sqflite` storage and the native SQLite handoff journals are **not
SQLCipher-encrypted**. iOS file protection does not replace an application-level
encrypted database. If the threat model requires database encryption, inject an
approved `TrackRepository` implementation and validate its secure key lifecycle
before production use.

GeoJSON, KML, and GPX files are plaintext and can reveal sensitive routes. The
host app should show the destination before sharing, avoid logging coordinates,
apply a retention policy, and call `deleteExport` after the artifact is no
longer needed.

## Example and validation

See [`example/lib/main.dart`](example/lib/main.dart) for start, pause, resume,
complete, permission recovery, status display, and export calls.

Automated tests cover validation, mock policy, motion hysteresis, durable
lifecycle recovery, pending-fix replay and acknowledgement, transactional
sequence allocation across independent SQLite connections, rejected-point
distance exclusion, overnight segmentation, uploader concurrency, and
independent JSON/XML parsing of every export format. Production acceptance
still requires multi-hour real-device, offline, permission-downgrade, OEM,
low-power, reboot/process, route-fidelity, and battery-control testing.
