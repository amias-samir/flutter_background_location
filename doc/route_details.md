# Route details

How the package decides which fixes form the route, how it records stops and
steps, and what it stores about each route. Back to the
[README](../README.md).

- [Capture intent and motion evidence](#capture-intent-and-motion-evidence)
- [Stops](#stops)
- [Accuracy envelopes, re-acquisition and turns](#accuracy-envelopes-re-acquisition-and-turns)
- [Measured distance and quality diagnostics](#measured-distance-and-quality-diagnostics)
- [Reading tracks and route geometry](#reading-tracks-and-route-geometry)
- [Route summaries](#route-summaries)
- [Steps](#steps)
- [Optional derived geometry](#optional-derived-geometry)
- [Release builds record a clean route](#release-builds-record-a-clean-route)

## Capture intent and motion evidence

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

`MotionFusionMode.platformActivityOnly` is the compatibility default.
`lowPowerSensorFusion` adds step/pedometer and significant-motion evidence.
`enhancedSensorFusion` additionally permits short accelerometer/gyroscope
windows when evidence conflicts. Probes obey duration, cooldown, and hourly
duty-cycle limits. Compass and gyro are orientation/rotation evidence only;
the package never performs inertial dead reckoning.

Activity confidence is the platform's confidence in an activity label. It is
not GPS accuracy. Use `ActivitySnapshot.evidenceState`/`age` for freshness,
`TrackPoint.horizontalAccuracy` for location uncertainty in metres, and
`MotionEvidenceSnapshot` for the sources supporting the current motion state.

## Stops

Adaptive capture records a clean route and the stops along it. Indoors, or in
a pocket, a phone that isn't going anywhere still reports fixes that wander
several metres while claiming good accuracy. From the first quiet fix of a
stay, fixes near it are stored as rejected `stationary_hold` evidence. They
add no distance, don't draw a scribble, and stay out of default exports and
uploads.

- **What starts a stay:** a quiet fix, with no moving reading in the last
  30 s and no measured walking-pace Doppler speed. A moving fix ends a short
  pause at once, so walking on keeps its distance.
- **What makes it a stop:** at least `minimumStopDuration` (five minutes by
  default) within the hold radius with no net progress, or still evidence.
  Still evidence also lets
  the native stationary profile engage. A stay the provider sent no fixes in
  is a stop when the first fix afterwards is still at the place.
- **What keeps it:** unknown, tilting or low-confidence readings, activity
  silence, and walking about inside the place, such as between rooms.
- **What ends it:** a fix outside the hold radius with a measured Doppler
  speed, a second outside fix while moving evidence is current, or fixes that
  keep moving away for a minute.
- **What counts as distance:** the stop-to-departure chord. Movement within a
  site smaller than the hold radius (at least 25 m) is not measured.
- **Scope:** new routes with the adaptive intent only. Explicit travel intents
  record every fix.

Set the minimum stop duration in the route's `TrackingConfig`. It is persisted
with the route and is distinct from the native stationary sampling interval:

```dart
const config = TrackingConfig(minimumStopDuration: Duration(minutes: 3));
```

The duration must be at least one millisecond. Existing recorded stops are not rewritten when
the setting changes. Stop-aware derived geometry uses the route's stored value.

Each stop is recorded with its place and its start and end times. The
owner-scoped controllers implement `TrackingStopController`:

```dart
final stops = await (tracking as TrackingStopController).listTripStops(tripId);
for (final stop in stops) {
  print('${stop.startedAt}: stayed ${stop.duration.inMinutes} min');
}
```

`TrackStop` carries the stop's centre, hold radius, `startedAt`, `endedAt`
(null while the stop is current), `duration`, `kind` (`TrackStopKind.still`
or `dwell`) and the number of fixes held. A stop ends at the departure fix,
or at its last fix when the route pauses or completes during it.
`TrackBundle.stops` carries a route's stops, and exports include them.

A visit to one place is one stop, and the route database stores it as one
row. A phone with precise fixes holds a stop within the 25 m minimum radius,
so walking between the buildings of a place, such as a temple's shrines, ends
one stay and starts the next. A stay that begins within three minutes of the
previous stop's end, centred within 75 m of it, extends that stop's row
instead of adding one; schema 17 consolidated the rows older versions stored
per stay. What the API returns is what is stored.

Routes recorded without live stop records (quality policies 1 and 2, or an
explicit travel intent) get their stops once they complete: the package
derives them from the stored points with the cleaned view's stay rule, stores
them as closed `dwell` rows and marks the route
(`RouteSummary.stopsSource`), in the background after the client opens and on
first read. The points never change.

Rejected fixes that arrive while the device is at a recorded stop are stop
evidence, not visible gaps, and `TrackingQualitySummary.stopEvidenceRunCount`
counts the rejected-fix runs made only of stop evidence, so
`qualityRunCount - stopEvidenceRunCount` is the number worth a look.

## Accuracy envelopes, re-acquisition and turns

Where the phone is carried changes what it records. The body blocks satellite
signals: on a two-phone motorbike test, a phone in the rider's jacket pocket
reported a median accuracy of 10 m and lost GNSS-quality fixes for about
15 minutes after a long stop in a valley, while a phone in the passenger's
bag reported 2 m throughout. The pocketed phone's route was 2.5 % shorter and
showed 17 visible gaps, all where its fixes were rejected. For riding, prefer
a bag, top box, tank bag or handlebar mount to a jacket or trouser pocket.

Vehicle capture also uses a bounded urban-visibility acceptance envelope:
`high` accepts reported horizontal uncertainty up to 35 m and `precised` up to
25 m. The provider still requests navigation-grade fixes. This avoids throwing
away most tunnel, pocket, or urban-canyon callbacks solely because they exceed
the walking-oriented 20/15 m limits. Pass an explicit
`maximumAcceptedAccuracyMeters` to make the envelope stricter or looser.
Adaptive capture applies the same envelope to a fix that is riding: its
Doppler speed is at least 5 m/s, or at least 2 m/s with a fresh in-vehicle or
on-bicycle reading (quality policy 4). Walking and standing keep the walking
limit, and an explicit `maximumAcceptedAccuracyMeters` still wins.

Quality policy 5, the default for new adaptive routes, decides the same way
on every phone. The first fix after a silence that lands far from the route
is accepted at once only when its Doppler speed is precise and consistent;
otherwise it waits for a fix that agrees with it, so a wrong re-acquisition
fix never pulls the route 100–300 m off. A fix the route could not have
reached is kept as rejected `kinematic_outlier` evidence. Reported accuracy
may widen a decision's tolerance but never narrows it, because phones report
it differently. Each fix is decided only from the evidence stored with it,
so a route received live, recovered after a restart or drained from the
native journal later gets the same stops and distance.

The High and Precised presets also capture turns (`turnCaptureDegrees`, 45°).
At riding speed a fix every 5 seconds lies tens of metres from the last, so a
junction or hairpin between them would be cut across. When a fix moving at
least 3 m/s with a reliable course has turned 45° since the last recorded
fix, it is recorded at once. The moving High and Precised profile reads an
unfiltered fix every second, batched up to the moving interval where the
device supports it, and records one fix per moving interval or a turn,
whatever the distance moved, on Android and iOS alike (sampling policy 2,
`TrackingConfig.samplingPolicyVersion`, preset definition 6), so walking,
standing and driving record at the same cadence on every phone. Set
`turnCaptureDegrees: 0` to turn turn capture off. Routes recording across an
upgrade keep the sampling they started with.

## Measured distance and quality diagnostics

Route presentation (separate parts, connected days, or continuous) is
described in [Multi-day Trips](multi_day_trips.md#route-presentation).

Edges between accepted anchors in the same recorded segment are measured even
when rejected callbacks occurred between them—the exported line already uses
those anchors. Database schema 14 repairs older totals that excluded these
same-segment edges. It does not add inferred Pause, interruption, or overnight
connector distance.

Feature-detect `TrackingQualityController` for coordinate-free accepted,
rejected, quality-run, visible-gap, lifecycle-boundary, activity-freshness,
and uncertainty-percentile diagnostics.

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
how to display recorded tracks with `maplibre_gl` and the muted OpenFreeMap
Positron style; applications can use MapLibre, Google Maps, Apple MapKit, or any
other renderer.

## Route summaries

The route database keeps each route's details up to date in the transaction
that changes them, so a host shows or uploads them without computing
anything. The owner-scoped controllers implement `TrackingSummaryController`:

```dart
final details = tracking as TrackingSummaryController;
final summary = await details.routeSummary(trackId);
print('${summary.displayDistanceMeters} m, moving ${summary.moving}, '
    'stopped ${summary.stopped} at ${summary.stopCount} stops, '
    '${summary.stepCount ?? 'no'} steps');
final trip = await details.tripSummary(tripId);
```

`RouteSummary` carries the measured distance, accepted and rejected point
counts, segments, first and newest fix times, and these values:

| Value | Meaning |
|---|---|
| `recording` | Time inside the route's segments, pauses excluded; while recording, up to the newest fix |
| `stopped`, `stopCount` | Time at the stored stops, and their number |
| `moving` | `recording` less `stopped` |
| `paused`, `elapsed` | Time paused, and start to end with pauses |
| `maxSpeedMetersPerSecond` | Fastest Doppler speed of an accepted fix with speed accuracy of 2 m/s or better, or unreported |
| `averageMovingSpeedMetersPerSecond` | Distance over moving time |
| `stepCount` | Steps counted while the route recorded; null when not counted |
| `stepCountStoppedAt` | When the step counter stopped counting while the person walked: the count is incomplete from then, never estimated; null when complete |
| `correctedDistanceMeters` | The distance under the current rules, for a route recorded under older ones and reviewed (see below); null otherwise |
| `displayDistanceMeters` | The distance to show: `correctedDistanceMeters` when present, otherwise `distanceMeters` |
| `qualityEventCount` | Rejected-fix runs that left a visible hole in the route; runs made only of stop evidence are counted in `stopEvidenceRunCount` |
| `visibleGapCount` | Holes in the route: lifecycle breaks, or gaps of at least 60 s or 150 m between accepted fixes |
| `cleanedDistanceMeters` | Length of the current cleaned view, once one was derived |

A gap across a stop or pause is never a visible gap: the device stayed where
it was. Each stored gap keeps this decision, and
`TrackingContinuityGap.isVisible` applies the same rule, so a map that marks
`isVisible` gaps agrees with the count. `TripSummary` holds the same totals
over a Trip's legs. `TrackBundle.summary` and `TripBundle.summary` carry them
too.

**Routes recorded by an older version.** Two phones recording the same
route should report the same stops, distance, quality events and visible
gaps; the rules behind quality policy 5 and continuity policy 4 make them do
so. A completed route recorded under older rules is decided again under the
current ones, in the background after the client opens and when it is first
read, and the review is stored beside what the route recorded: its stops,
gaps, quality runs and step decisions come from the review, and
`correctedDistanceMeters` reports its distance. The route's points, their
acceptance, `distanceMeters` (the measured distance) and its uploads never
change. `listDerivedGeometry` lists the reviewed route as a run with the
algorithm `DerivedGeometryAlgorithm.routeQualityReview`; loading it shows
exactly the fixes the review keeps, and deleting it restores the recorded
stops, gaps and totals.

`currentCleanedGeometry(trackId)` returns the route's current stop-aware
cleaned view: the newest run when it covers the route's newest point under the
current cleaning version, otherwise a new one. It deletes older runs and
stores the cleaned distance in the summary.

## Steps

While a route records, Android counts steps with the phone's step counter and
iOS with the motion coprocessor's pedometer, in every motion fusion mode.
Steps need the activity permission the package already requests:
`ACTIVITY_RECOGNITION` on Android 10 and later, and Motion & Fitness on iOS.
The package never prompts for steps on its own; without the permission, or
on a phone without a step counter, `stepCount` stays null. A permission
granted while a route records starts the count within a minute. Each location
fix carries the count since its capture session started (`stepCount`), each
point keeps it, and the route counts each session once, at its highest count,
so a restart or recovery never counts steps twice. Steps taken after the
newest fix count when the route pauses or completes: the native side reads a
final count on every way capture stops. The native capability `step_count`
reports a step counter.

Some phones stop delivering step counts while the person walks. Android
prefers the wake-up step counter and repairs a counter that falls silent
while other evidence shows walking (it flushes, re-registers and switches to
the other counter); iOS reads the pedometer before pausing and stopping.
`stepCoverage` on fixes and status reports the counter's state (capability
`step_count_coverage`). A count that stopped and was not recovered keeps the
steps counted so far and sets `stepCountStoppedAt`, so a UI can show
"≥ 1,234 steps · counter stopped at 09:22"; nothing is estimated. Changes of
the counter's state are recorded as count-free health events, and
`StepCounterDiagnosticsController.stepCounterDiagnostics()` returns the
counter's count-free event history for support (capability
`step_counter_diagnostics`).

Steps are fitness data. They are kept in the route database and its exports.
Upload batches leave them out of `TrackUploadBatch.toMap()`, but the batch's
`TrackPoint`s carry `stepCount`. A host that sends steps to a server must
declare fitness data in its own privacy disclosures, such as its App Store
privacy details and Google Play data safety form.

## Optional derived geometry

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

For a cleaned map, use the stop-aware algorithm. Each stay of the configured
minimum stop duration or
more collapses to one point, and spikes elsewhere are projected away. It reads
held fixes as stop evidence and also cleans routes recorded before the stop
hold existed. Runs record the version they applied; derive again when
`run.algorithmVersion` differs from
`DerivedGeometryAlgorithm.stopAwareRouteCleaningVersion`. Pass
`TrackGeometrySelection.derived(run.id)` as `TrackExportOptions.geometry` to
export a track's cleaned view:

```dart
final cleaned = await geometry.deriveGeometry(
  trackId,
  request: const DerivedGeometryRequest(
    name: 'cleaned',
    algorithm: DerivedGeometryAlgorithm.stopAwareRouteCleaning,
  ),
);
final gpx = await tracking.exportTrack(
  trackId: trackId,
  format: TrackExportFormat.gpx,
  options: TrackExportOptions(
    geometry: TrackGeometrySelection.derived(cleaned.id),
  ),
);
```

Each run stores its algorithm, version, configuration, source snapshot,
optional map-data provenance, and derivation time. Smoothing restarts at every
pause/resume segment. Deleting a run deletes only derived rows; loading raw
geometry after deletion returns the original route unchanged. Hosts can add a
separate map-matching integration by implementing the repository capability;
no proprietary map service is required by this package.

## Release builds record a clean route

Release and profile builds keep only the clean route: the accepted path, its
stops, distance, duration and steps. Debug builds keep everything recorded
for investigating a field test. You don't need to set anything:

```dart
const TrackingConfiguration(); // recordingDetail: RouteRecordingDetail.automatic
```

Every mode collects and decides the same fixes, so these are identical in
every mode:

- capture and sampling;
- the accepted points and the held or rejected fixes kept as hidden evidence
  on the device;
- measured and corrected distance, stops and steps;
- uploads.

In clean detail (`RouteRecordingDetail.clean`) a route stores:

- **Gaps:** only the gap rows that mark a segment boundary, none of them
  visible. `RouteSummary.visibleGapCount` is 0 and the map draws no gap
  markers.
- **Quality runs:** none. `RouteSummary.qualityEventCount` and
  `stopEvidenceRunCount` are 0.
- **Motion evidence and diagnostic health events:** none. Events that prove a
  lifecycle boundary, such as an interruption, are kept.
- **Journaled activity readings:** cleared once the route is completed or
  failed. Only a restart of a live route decides from them.

Clean detail also changes what the package reports:

- **Exports** of a clean route leave out `qualityEventCount`,
  `visibleGapCount`, `gapCount`, `rejectedPointCount` and GPX `fbl:gap`
  elements. Stops are still exported.
- **Ignored export options:** a clean client ignores `includeRejectedPoints`
  and `includeDiagnosticProperties`.
- **Native diagnostics:** native code keeps no step-counter diagnostics, so
  `stepCounterDiagnostics()` returns an empty list. Raw platform error text is
  replaced by a fixed message.

The setup doctor, health snapshots, battery checks and the native journal
integrity check work in every mode.

Each route keeps the detail it started with (`Track.recordingDetail`). A route
recorded by a debug build stays full after you install a release build, and
the reverse holds too. Routes recorded before this setting existed are full.
To force a mode, for example to collect full diagnostics in a release field
test, set it explicitly. Read the resolved mode with
`TrackingClient.recordsDiagnostics`, or with
`TrackingClient.resolveRecordingDetail(configuration.recordingDetail)`, to
show debug views on the same switch.

```dart
const TrackingConfiguration(recordingDetail: RouteRecordingDetail.full);
```

