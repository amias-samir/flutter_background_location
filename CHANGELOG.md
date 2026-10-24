## Unreleased

- Adaptive capture now holds stops (motion policy 2 and quality policy 2). A
  field test recorded about 1.1 km of phantom distance and a dense scribble
  of fixes while a phone sat in a pocket indoors for three hours. Activity
  Recognition had reported still most of the time, but the stationary
  profile never engaged and every fix within the accuracy limit counted.
  - The native state machine on Android and iOS keeps a still episode
    through unknown, tilting and low-confidence readings, and through
    Activity Recognition silence (Google pauses reports while a device stays
    still). The episode ends only on positive moving evidence: an activity
    transition, two consecutive moving readings, an in-vehicle reading of at
    least 75, a measured Doppler speed, or sustained displacement. Entry
    tests fixes against their own uncertainty instead of an all-pairs budget
    two indoor fixes could never meet.
  - While a still episode is current, fixes within an uncertainty-scaled
    radius of the stop (at least 25 m) are stored as rejected
    `stationary_hold` points, and outliers as `stationary_outlier`. Neither
    adds distance, and the stop-to-departure chord still counts. Movement
    within a site smaller than the radius is deliberately not measured.
    Held runs are informational quality runs, and their gaps classify as
    expected stationary suppression.
  - This applies only to new routes with the adaptive capture intent.
    Walking, cycling and vehicle intents are unchanged. Routes that were
    recording before the upgrade resume under their recorded policies.
    `TrackingConfig` carries the new `motionPolicyVersion` key, set by the
    package (configurations persisted without it stay on version 1), and
    native code advertises the `stationary_policy_v2` capability.
- Adaptive capture now records a clean route and the stops along it (quality
  policy 3, the default for new adaptive routes). A second field test still
  drew scribbles at a temple, at home and at a roadside motorbike stop: with
  the phone in a pocket, Activity Recognition reported unknown, tilting or on
  foot instead of still, so no stop started, and walking between rooms ended
  one.
  - A stay starts at the first quiet fix: one with no moving reading in the
    last 30 s and no measured walking-pace Doppler speed. Its fixes are held
    from then on. A moving fix ends a pause at once, so walking on keeps its
    distance.
  - Once a stay lasts two minutes with no net progress (least-squares
    velocity less twice its standard error, at most 0.15 m/s), or with still
    evidence, it is a stop and the hold centres on its fixes. Walking inside
    the radius stays part of the stop. It ends when a fix leaves the radius
    with a measured Doppler speed, with current moving evidence on the second
    outside fix, or for good.
  - A stay the provider sent no fixes in is a stop when the first fix
    afterwards is still at the place.
  - Rejections during a stay, including poor-accuracy indoor fixes, carry the
    new `TrackPointQualityFlag.duringStop` bit and no longer mark visible gaps.
  - With no activity readings at all (iOS reports only changes, and some
    Android devices have no Activity Recognition) and no precise Doppler
    speed, a fix is neither moving nor quiet: only two minutes of accepted
    fixes confined with no net progress start a stop.
  - Routes recorded under quality policies 1 and 2 decide exactly as before.
- A two-phone motorbike test (one phone in the rider's jacket pocket, one in
  the passenger's bag, same build and settings) recorded 58.98 and 60.46 km,
  10 and 12 stops, and 17 and 0 visible gaps. The pocketed phone's fixes were
  shielded by the rider's body (median accuracy 10 m against 2 m), and for
  about 15 minutes after a long stop in a valley it had only network-quality
  positions. Four changes make the results consistent where the package can:
  - **One place, one stop.** A stay that begins within three minutes of the
    previous stop's end, centred within 75 m of it, extends that stop:
    walking between a temple's shrines no longer splits a two-hour visit on a
    precise phone. The route database stores one row per visit (schema 17),
    and the upgrade consolidates the rows stored per stay.
  - **Visible gaps mark holes in the route.** Under quality policy 3 and
    later, a single dropped fix is never a visible gap on its own, and
    rejected fixes that don't show travel and arrive while the device is at a
    recorded stop (from five minutes before it) are stop evidence. Stored run
    severities are unchanged.
  - **Stop holds are not quality events.** `TrackingQualitySummary` gains
    `stopEvidenceRunCount`, the rejected-fix runs made only of stop evidence;
    the example's Trip card and map header leave them out.
  - **Riding fixes up to the vehicle envelope (quality policy 4, the default
    for new adaptive routes).** A fix whose Doppler speed is at least 5 m/s,
    or at least 2 m/s with a fresh in-vehicle or on-bicycle reading, is
    accepted up to the accuracy the vehicle intent allows (35 m at High,
    25 m at Precised) unless the host set its own limit. Routes recorded
    under quality policy 3 decide as before. On the test data this recovers
    about 0.5 km of the 1.5 km difference; the rest had no usable fixes.
- Moving routes capture turns. At riding speed a fix every 5 s lies tens of
  metres from the last, so a junction or hairpin between them was cut across.
  The new `TrackingConfig.turnCaptureDegrees` (45° for the High and Precised
  presets, off for Medium and Low; preset definition 5) records a fix moving
  at least 3 m/s with a reliable course as soon as it has turned that far
  since the last recorded fix. On Android the moving high-accuracy profile
  requests 1-second fixes, batched up to the moving interval where supported,
  and records only the regular and turning ones; iOS gains the same rule on
  top of recording every fix that moved the distance filter. Kotlin and Swift
  share the `turn_capture_v1` fixture. Configurations stored without the key
  keep sampling without turn capture.
- Routes now keep a record of each stop: where it was and how long it lasted
  (route database schema 16, table `track_stops`). A record is written in the
  same transaction as the fix that opens, extends or ends it, survives
  restarts, and ends at the departure fix or, when the route pauses or
  completes during a stop, at its last fix. Fixes held at a stop stay on the
  device as rejected evidence and never enter the route, its distance or
  default exports.
  - `TrackStop`, `TrackStopKind` and the optional `TrackingStopController`
    capability (`listTrackStops`, `listTripStops`) are exported, and
    `TrackBundle.stops` carries a route's stops. Custom repositories can
    implement the optional `TrackStopRepository`; without it, stops are not
    recorded.
  - GeoJSON, GPX and KML exports include stops by default
    (`TrackExportOptions.includeStops`): a Point feature with
    `featureType: stop`, a GPX `<wpt>` with `fbl:` extensions before the
    track, and a timed KML Placemark, in single-route, streamed and Trip
    exports. Routes without stop records export byte for byte as before.
    Uploads are unchanged.
  - The example map draws recorded stops in both views (tap one for its
    times), and the Trip list shows the number of stops and the time stopped.
- Every route detail is kept in the route database (schema 17), so hosts show
  or upload it without computing anything.
  - `RouteSummary` and `TripSummary` carry recording, moving, stopped and
    paused time, the stop count, maximum and average moving speed, steps,
    quality events, visible gaps and the cleaned distance. The owner-scoped
    controllers implement the optional `TrackingSummaryController`
    (`routeSummary`, `tripSummary`, `currentCleanedGeometry`), and
    `TrackBundle.summary` and `TripBundle.summary` carry them. The new
    `track_summaries` and `trip_summaries` tables are kept in the
    transactions that change them and equal a full recompute. Custom
    repositories can implement the optional `RouteSummaryRepository`.
  - Ending a day or completing a Trip now closes a current stop; it stayed
    open before.
  - Completed routes recorded without live stop records (quality policies 1
    and 2, or an explicit travel intent) get their stops once, derived from
    the stored points with the cleaned view's stay rule, in the background
    after the client opens and on first read (`RouteSummary.stopsSource`).
  - Each stored gap keeps its visible decision: lifecycle breaks, or gaps of
    at least 60 s or 150 m between accepted fixes, never a stop or pause.
    `TrackingContinuityGap.isVisible` applies the same rule, so maps and
    counts agree. Rejected-fix runs keep whether they are only stop evidence.
  - Exports carry the summary: GeoJSON route properties, GPX `fbl:` metadata
    extensions and KML `ExtendedData`. A derived-geometry export now reports
    the derived line's distance and `geometrySource: derived:<run id>`; it
    reported the raw ones.
  - The example app counts nothing itself. Its Trip and route cards and map
    header read the summaries, draw the stored stops and the gaps the
    database marks visible, and show moving and stopped time and steps.
- Steps are counted on every route, in every motion fusion mode: Android uses
  the step counter sensor (batched, non-wake-up) with `ACTIVITY_RECOGNITION`
  on Android 10 and later, and iOS the pedometer with Motion & Fitness. The
  package never prompts for steps on its own; without the permission or a
  step counter, steps stay null. Location events and native status carry
  `stepCount`, the steps since the capture session started
  (`LocationSample.stepCount`, `TrackerStatus.stepCount` with
  `TrackerStatus.captureGenerationId`), each point keeps it
  (`TrackPoint.stepCount`), and segments add each session once. Steps taken
  after the newest fix count when the route pauses or completes. Native code
  advertises the `step_count` capability. Steps are fitness data: a host
  that uploads them must declare that in its own privacy disclosures.
- Two phones recording the same route now report the same results. A test
  with two Xiaomi phones (one Qualcomm, one MediaTek) on four routes found a
  frozen step counter, re-acquisition jumps of up to 286 m, different
  sampling cadences, and stop, quality-event and gap rules that behaved
  differently per chipset, per platform and between live and replayed data.
  - **Quality policy 5** (the default for new adaptive routes). The first far
    fix after a silence is accepted at once only with a precise, consistent
    Doppler speed, and otherwise waits for a fix that agrees with it. A fix
    the route could not have reached is kept as rejected `kinematic_outlier`
    evidence. Speed accuracy never rejects a fix. Reported accuracy may widen
    a tolerance but never narrows it. The stop hold radius is 25–60 m.
    Nothing inside it ends a stop; a pause ends inside it only on walking
    shown by both a Doppler speed and confirmed readings. A precise Doppler
    standstill outranks lagging moving readings. A stay counts its two
    minutes only over evidence, so a provider silence never becomes a stop
    on one phone and nothing on the other. Each fix is decided only from the
    evidence stored with it, so live, restarted, journal-drained and
    offline decisions agree.
  - **Continuity policy 4.** A gap counts as expected stationary suppression
    only when a stay explains it, never because the native profile had
    turned stationary. Every accepted gap of at least 60 s is decided.
  - **Quality events** count only rejected-fix runs that left a visible hole
    in the route. A run on the approach to a stop that opens soon after is
    informational (summary version 2).
  - **Recorded routes are corrected without being rewritten** (route database
    schema 18). A completed route recorded under older rules is decided again
    under the current ones, in the background and on first read. The review
    is stored beside what the route recorded and is removable. Its stops,
    gaps, quality runs and step decisions are what readers, summaries and
    exports use. `RouteSummary` and `TripSummary` add `correctedDistanceMeters`
    and `displayDistanceMeters`. `distanceMeters`, points, their acceptance
    and uploads never change. The reviewed route is a derived run
    (`DerivedGeometryAlgorithm.routeQualityReview`). The optional
    `RouteReviewRepository` and `KeyedHealthEventRepository` capabilities
    back this.
  - **Steps never stall silently.** Android prefers the wake-up step counter,
    flushes it every minute and repairs one that stays silent while the
    person walks. Every way native capture stops reads a final count first,
    and iOS reads the pedometer before pausing and stopping. Fixes and status
    carry `stepCoverage`, and status carries `stepFinal` (capabilities
    `step_count_coverage` and `step_counter_diagnostics`). A count that
    stopped keeps the steps counted so far and sets
    `RouteSummary.stepCountStoppedAt`; nothing is estimated. Each capture
    generation counts once at its highest count. Coverage changes are
    count-free health events, and `StepCounterDiagnosticsController` returns
    the counter's count-free event history.
  - **One sampling cadence** (sampling policy 2, preset definition 6). The
    High and Precised moving profile records one fix per moving interval or
    a turn, from an unfiltered stream, on Android and iOS alike.
    `TrackingConfig.samplingPolicyVersion` is set by the package.
    Configurations persisted without it keep sampling policy 1. Native code
    advertises `fix_sampling_v2`.
  - **Decision inputs are journaled.** Each journaled fix carries the
    activity readings and profile switches since the previous one
    (`LocationSample.activityReadings`, `profileTransitions`; capability
    `journaled_decision_inputs`), stored with the point. Its profile stamp is
    the profile at capture on both platforms (`profile_stamp_at_capture`).
    Profile-switch health events are rebuilt from the journal once each.
  - New routes only. Routes recording across the upgrade keep their
    recorded policies, and the review corrects them once they complete.
- `exportTrack` on the owner-scoped controllers now accepts
  `TrackGeometrySelection.derived` and writes the derived coordinates. It
  previously failed with `derived_geometry_requires_v2_export`.
- Native stationary capture no longer anchors a stop on the first fix after a
  long silence. A still phone delivers no fix, so the stop is entered without
  one, and the first fix afterwards is often a re-acquisition outlier tens of
  metres off; two fixes must now agree first. Native status reports
  `profileTransitionReason` (exposed as `TrackerStatus.profileTransitionReason`)
  and each moving/stationary switch of a route is recorded as a coordinate-free
  `sampling_profile_changed` health event.
- Added `DerivedGeometryAlgorithm.stopAwareRouteCleaning`, a derived "cleaned"
  route view. Each stop collapses to one point, and spikes elsewhere are
  projected away. It works on routes recorded under any policy, including
  existing ones; canonical points never change. The example map shows it by
  default, with raw evidence one tap away, stop markers with durations, and
  low-confidence zig-zag stretches drawn in a lighter colour. Its version 2
  (`DerivedGeometryAlgorithm.stopAwareRouteCleaningVersion`) applies the stay
  rule above, reads held fixes as stop evidence, and also covers a stop's
  first minutes and the arrival inside its radius; runs of version 1 should
  be derived again. The example exports the cleaned view as GPX.
- Added `TrackExportOptions.includeDiagnosticProperties` (off by default) for
  field tests. GeoJSON point features and GPX `fbl:` extensions gain vertical
  accuracy, Doppler speed and heading with their accuracies, provider,
  native sampling profile, activity source, raw type, evidence state and
  age, native receipt delay, and quality policy version. Default exports are
  byte-for-byte unchanged. `tool/quality/analyze_stop_jitter.dart` turns
  such an export into a coordinate-free stop report, finding stops with the
  same stay rule and listing the recorded ones.
- Added seeded field-test replicas to the testing library:
  `SyntheticTrackingRoute.indoorStop`, `reacquisitionBurst`, `slowLaneRide`,
  `pocketStop`, `placeWander`, `roadsideStop` and `slowStrollWithPauses`,
  plus `followedBy` and `emitChronologicallyTo`.

- Native error envelopes on Android and iOS no longer attach the full native
  status map as details (it can hold the last fix coordinates and track
  identity) or echo platform exception text (which can hold file paths,
  content URIs, or journal payload fragments). `TrackingNativeException.cause`
  now carries only the redacted command state (`state`, `isTracking`,
  `isPaused`, `commandRevision`), and messages name the exception type or
  error domain instead. The Android `tracking_already_active` message no
  longer includes the active track ID.
- Route database schema 15 records the continuity classifier version on each
  configuration epoch (existing epochs read as version 2). Fixes are now
  evaluated under the quality and continuity versions recorded by the epoch
  that covers them, so upgrading the package never reinterprets a route that is
  already recording. Points and gaps store the version actually applied: an
  unknown version from a newer package falls back to the newest supported one.
- Added the optional `ActiveConfigurationEpochRepository` capability and an
  optional `PointWriteRequest.qualityPolicyVersion`. Custom repositories that
  implement neither keep today's behavior.
- Continuity policy 3: a runtime configuration update no longer splits the
  route. Applying an update restarts the native provider, and version 2
  treated the new capture generation as a native interruption and started a
  new segment. Version 3 keeps the segment, counting the edge toward
  distance, when nothing else (process restart, explicit boundary, lost
  permission or service, or an over-threshold gap) explains the gap. It
  applies only to epochs created under version 3; existing routes keep
  version 2.
- Derived geometry now works across the ±180° meridian. The moving average
  blended raw longitude degrees, so a segment crossing the antimeridian swung
  around the globe; the spike projector had the same problem. Both now
  interpolate the short way and wrap back, leaving every other route
  bit-for-bit unchanged. Uncertainty-smoothing runs record the classifier
  thresholds they applied in their configuration.
- Consolidated five copies of the route distance formula into one internal
  implementation (`spherical_haversine_r6371008_8_v1`). Android's stationary
  displacement window and the physical-device harness now use the same
  6 371 008.8 m mean radius instead of 6 371 000 m.
- Health events no longer grow without bound. The newest 500 diagnostic
  events are kept per route (pruned every 50 inserts). Lifecycle evidence
  events (interruptions, failures, previous-session and termination-recovery
  gaps, authorization changes) are always kept, because legacy gap
  classification reads them.
- Android's native journal no longer rescans every pending row for each fix
  and acknowledgement. Row, payload, and sequence counters are loaded once and
  updated after each commit; page counts are read only near the size bound;
  the duplicate check runs only at capacity (the `IGNORE` insert already
  reports duplicates); and acknowledgements no longer run `COUNT(*)` plus a
  `wal_checkpoint(TRUNCATE)` each time the queue drains. A passive checkpoint
  runs once the WAL passes 4 MiB, and truncation is left to maintenance and
  close. Journal sequences no longer restart at 1 when the queue empties.
- Android no longer decodes the whole native journal and posts every event
  from the main thread each time the location stream is subscribed. The
  package's Dart client already drains the journal by pages and now subscribes
  with `replayOnListen: none` (capability `listen_replay_control`). Other
  listeners still get the backlog, replayed 100 events per main-thread post.
- iOS writes less per location callback: continuity-health timestamps are
  persisted to `UserDefaults` at most every 15 s (profile transitions and probe
  outcomes still persist immediately), and all fixes of one Core Location
  callback are journaled in a single transaction with one prepared insert
  instead of one fully synced transaction per fix. Invalid events, duplicates,
  and a full journal still affect only the events concerned.
- iOS start, resume, and stationary-exit probes now acquire fresh fixes.
  They called `requestLocation()`, which Core Location ignores while updates
  run, and counted the next ordinary (possibly cached) callback as success. A
  bounded in-place burst now runs instead: at least Best accuracy with no
  distance filter, every fix emitted, until three converged fixes or 15 s,
  then the profile request is restored. Only a fix captured after the request
  completes the probe. Fixes carry `captureOrigin` (`probeBurst` /
  `providerStream`).
- Android stationary-exit probes now flush batched fixes first and request the
  fresh fix when the flush completes (or after 2 s). The request uses
  `maxUpdateAge` 0, fine granularity, and a bounded duration, and each delivery
  is journaled in capture order. Previously a fresh probe fix could be
  journaled ahead of older flushed fixes, which Dart rejected as
  non-monotonic. Probe fixes carry `captureOrigin: exitProbe`.
- Sensor fusion (opt-in `lowPowerSensorFusion` / `enhancedSensorFusion`) now
  needs a walking cadence before reporting steps as movement: at least 6 steps
  within 30 s, reported at most every 10 s. iOS treated the cumulative
  pedometer total as "a fresh step" for the rest of the session, and Android
  reported every single step (and woke the service each time). Probe duty is
  a sliding 60-minute budget instead of a fixed hourly window that could spend
  twice the budget across a boundary. All fusion state is now confined to one
  worker thread (Android) or serial queue (iOS); it was mutated from several.
- Android replaces its location request in place on moving/stationary
  switches instead of removing and re-adding it, which left a gap that could
  restart the location engine. Fixes that arrive behind a newer fix of the
  same capture generation are still journaled and now carry
  `deliveryOrder: late` (`inOrder` otherwise).
- Fewer background wakeups from Dart timers. The health watchdog no longer
  takes a full health snapshot (several native calls) every 30–60 s while
  tracking; it runs only after an interval passes without a committed fix.
  Upload recovery no longer polls every 30 s for the client's lifetime: it
  checks while leftover uploads exist, backing off from
  `uploadRecoveryInterval` toward 15 minutes, and stops when the outbox is
  empty until an upload fails again.
- A phone that dies or shuts down mid-route keeps its captured fixes. Android
  listens for shutdown (including OEM fast-boot power-off) while capturing,
  flushes the provider, and waits up to 4 s for the native journal to commit
  everything queued before shutdown. It records `lastShutdownObservedAt` and
  turns provider batching off while the battery is low. iOS, which has no
  shutdown signal, persists capture health on every callback at or below 5 %
  unplugged.
- Android Activity Recognition results are handed to the running capture
  service in process. Before, every result (up to every 5 s) restarted the
  service, rebuilding the notification twice and re-reading the
  configuration. Every transition event of a result is now handled, oldest
  first, not just the last. Transitions are fresh at delivery and keep the
  transition time as `episodeStartedAt`; the back-dated transition time had
  made them lose to the newest periodic sample. Periodic samples and
  transitions are no longer ordered against each other.
- Android does less work per fix. The native status is no longer
  re-broadcast after every fix, which cost several binder calls and a channel
  message each time; on the fix path it is a 10 s liveness tick, since Dart
  publishes its own status after each commit (capability
  `status_fix_echo_control`). The permission and location-services check
  that ran per fix is reused for 30 s once it passes; the 60 s prerequisite
  monitor still watches for revocation.
- Fewer database round trips per fix (on Android, each is a platform-channel
  call). The native protocol is fetched once per adapter instead of before
  most native calls, session snapshots reuse the track the repository just
  emitted, and the rejected-run scan is skipped when no fix was rejected since
  the previous accepted one. In a measured append path, one fix dropped from
  21 to 19 SQLite invocations.
- Registered every error code raised by Dart, Kotlin, and Swift in
  `tool/quality/error_codes.yaml`. The ledger validator now cross-checks the
  compatibility versions against the shipped constants and fails on
  unregistered codes or unredacted native error envelopes.
- Declared the iOS `SystemBootTime` required-reason API (35F9.1) in the
  privacy manifest; `ProcessInfo.systemUptime` timestamps fix receipt for
  on-device gap measurement. The ledger validator now fails when package Swift
  uses a required-reason API the manifest does not declare.
- The route database now sets `PRAGMA synchronous = FULL`, so a commit that
  acknowledged native fixes survives power loss even where Android defaults
  WAL databases to `NORMAL`.
- Synced the podspec version and the README install snippet with the package
  version (1.0.0). The validator now checks pubspec, podspec, Package.swift
  (name, minimum iOS, privacy manifest), and the README snippet together.
- Fixed lost motion evidence on Android replay. The native journal stored
  nested maps through `toString()`, so a fix replayed after the Flutter engine
  restarted lost its motion evidence and activity probabilities. Journal
  payload format 2 stores nested values as JSON text with a marker key and
  inflates them on read; older plugin builds read the text harmlessly after a
  rollback. Format-1 rows still decode, without the unrecoverable nested data.
- Unknown kinematics are no longer stored as values. iOS reported `-1` for
  unknown speed, course and their accuracies and sent altitude even when a
  negative vertical accuracy marked it invalid; iOS now omits those values and
  Dart drops negative sentinels from any native, drops an altitude whose
  vertical accuracy is negative, and normalizes heading into [0, 360). New
  capability codes: `normalized_location_validity`, `journal_nested_json_payload`.
- A failed native acknowledgement after a successful commit no longer marks
  the route `failed` with "Could not persist a location fix" or hides the
  committed point from `pointStream`. The fix is durable, so its event ID is
  retried with the next commit (up to 2,000 deferred IDs; older ones are
  acknowledged when journal replay finds them committed), and
  `native_acknowledgement_deferred` / `_recovered` health events record it.
- Added `TrackingConfig.withPreset(accuracy)`, which applies an accuracy
  preset's derived values for the configuration's capture intent and keeps
  every other field. The adaptive battery engine now builds its proposals with
  it; before, proposals silently reset capture intent, motion fusion mode,
  activity/motion freshness and fallbacks, and the sensor-probe budgets to
  their defaults, and used adaptive sampling for explicit walking, cycling, and
  vehicle routes.
- Fixed activity evidence attached to native fixes. Dart decoded the fix time
  as the activity time, so every reading looked fresh, and Android's empty
  activity keys became an "unknown, fresh" reading that blocked the fallback to
  the activity stream. Location payloads now decode only `activity*` keys; a
  payload without activity evidence falls back to the recent stream reading,
  and a reading without a time is `unavailable`.
- iOS now measures activity freshness from when Core Motion delivered the
  reading, not from `CMMotionActivity.startDate` (the start of the activity
  episode, which can be hours old during a long stop and made stationary
  readings look stale). Both platforms age the latest reading at each fix, so
  stored activity age and evidence state are honest. iOS adds a diagnostic
  `activityEpisodeStartedAt` key.
- `TrackerStatus.lastPointAt` no longer reports the status time as a fix time
  before the first fix; iOS now always sends the key (null until a fix).
- Android's capability report now derives `activityRecognition` from Google
  Play services availability instead of always reporting true, so readiness no
  longer recommends the permission on devices that cannot classify activity.
- Upload batches now trigger when a commit crosses a `batchPointCount`
  multiple instead of only landing on one exactly, and replayed duplicates no
  longer trigger uploads.
- `TrackingConfig.fromMap` now resolves a missing `firstFixTimeoutMs` like
  the constructor. It used the pre-v4 timeouts (for example 60 s instead of
  45 s for `high`), so a partial map and `TrackingConfig(...)` with the same
  fields differed. A frozen preset-definition-4 fixture now fails tests if any
  preset value changes without a version bump.
- Startup epoch repair now reads only routes that lack epoch 1, labels them
  with fixed legacy versions (preset 4, quality 1) instead of the current
  constants, and links only their own points inside one transaction.
- Corrected the record on Android `WAKE_LOCK`: the 1.0.0 notes say the
  permission was removed, but it is declared and held while capture is
  active.

## 1.0.0

- Added `RouteFormatConverter` for in-memory GeoJSON, GPX, and KML route
  conversion in every supported direction, with multi-segment geometry,
  elevation, timestamp, and route-name preservation where the source format
  provides them.
- Added schema 14 distance repair so same-segment accepted geometry is counted
  even when rejected callbacks occurred between anchors; inferred lifecycle
  and multi-day connectors remain excluded.
- Increased preset-definition version 4 sampling density across all accuracy
  modes, made explicit walking/cycling/vehicle capture stay in the moving
  profile, and reduced activity/motion recovery latency.
- Increased vehicle capture to a 3-second/3 m request and added bounded 35 m
  (`high`) and 25 m (`precised`) urban acceptance envelopes while preserving
  explicit per-field overrides.
- Reduced duplicate gap evidence for rejected callbacks and limited map gap
  markers to severe automatic gaps or genuine lifecycle boundaries.

- Added schema 13 activity provenance/freshness, bounded coordinate-free
  motion-evidence persistence, severity-rated rejected-fix quality runs, and
  privacy-safe quality summaries.
- Added opt-in low-power and enhanced sensor fusion on Android/iOS using
  steps/pedometer, significant motion, and bounded ambiguity probes; compass
  and gyro never generate coordinates, and all listeners stop with capture.
- Added Android Activity Transition input, probable-activity distributions,
  fresh high-fidelity requests, and stale/unknown moving-profile fallback;
  added equivalent iOS freshness, pedometer, and immediate-fix behavior.
- Added `RouteCaptureIntent` and walking/cycling/vehicle sampling defaults while
  preserving individual configuration overrides.
- Added persisted `MultiDayRoutePresentation` modes and shared
  `connectDailyLegs` topology across maps and GeoJSON/KML/GPX Trip exports.
- Added deterministic uncertainty-aware spike smoothing plus a bounded,
  vendor-neutral `RouteGeometryProcessor` adapter with raw fallback and
  immutable processor provenance.
- Updated the example with start-time capture/fusion/presentation controls,
  distinct activity confidence and GPS uncertainty, fused-motion sources,
  quality/visible-gap counts, filtered markers, and stored Trip map defaults.
- Added a coordinate-free physical-qualification template generator and
  strengthened its validator to enforce fusion, capture-intent, carry-state,
  power-state, metric-range, and zero-raw-sensor-persistence coverage.
- Added a physical-device lifecycle harness with a bounded post-install
  permission window for checking active/pause/resume/complete service and
  optional-sensor teardown, plus privacy-safe accepted/rejected/segment and
  stored-versus-geometry distance aggregates, without treating stationary or
  simulator runs as route-accuracy or battery evidence.

- Added schema 12 continuity evidence and atomic point/topology persistence so
  a healthy stationary or rejected-fix run no longer creates an artificial
  route break solely because the accepted-point gap exceeded five minutes.
- Added stable Android/iOS capture generations, coordinate-free continuity
  health, and journal-deduplicated stationary-exit location probes.
- Added owner-scoped multi-day `Trip` models, migration-backed implicit Trips,
  crash-recoverable/idempotent Start/End day/Continue/Complete operations,
  revisioned optional completion upload, Trip-level retention, and cascading
  terminal deletion.
- Added shared three-mode route geometry used by maps plus legacy/streaming
  exports, typed inferred connectors excluded from measured distance, and
  combined chronological GeoJSON/KML/GPX Trip export.
- Updated the example to show one Trip with daily leg/segment/gap counts,
  End day and confirmed completion/continuation controls, whole-Trip MapLibre
  rendering, gap indicators, connect-all disclosure, export, and deletion.
- Added red Start and green Destination indicators to the example route map.
- Refreshed the example with clearer session, lifecycle, configuration, and
  recorded-route cards, plus a confirmed owner-conflict recovery prompt.
- Expanded integration-focused Dartdoc coverage and simplified the README's
  setup flow and core API reference.
- Added the awaited owner-bound `TrackingClient.open`/`TrackingController`
  facade, owner-scoped history/upload behavior, opaque foreign-capture recovery,
  and durable native command leases on Android and iOS.
- Added schema versions 8–11 for durable session tokens, wall/monotonic fix
  evidence, recoverable producer-fenced runtime configuration epochs, and
  immutable provenance-preserving derived geometry.
- Added explicit raw/derived map and V2 export selection with removable,
  versioned post-capture EMA geometry runs.
- Added a versioned adaptive battery-policy engine with shadow/apply modes,
  host fidelity bounds, hysteresis, transition limits, redacted decisions, and
  rollback through atomic configuration epochs.
- Added an opt-in iOS significant-change termination-recovery mode, public
  launch hook, exact capability modes, and honest possible-gap state while
  retaining interrupted/manual recovery as the default.
- Added versioned fix-quality decisions, first-fix timeout health, gap-created
  segments, and uncertainty-aware native motion/stationary transitions.
- Added coordinate-free health/watchdog snapshots, setup doctor, redacted
  support reports, and battery-optimization state.
- Added the public testing library with deterministic controller/adapter fakes,
  wall/monotonic clocks, synthetic routes, permission/recovery fixtures,
  temporary SQLite setup, and faultable native/export doubles.
- Decomposed the example into owner/readiness bootstrap, lifecycle controls,
  paged route actions, editable exports, and MapLibre street-map modules.
- Added migration/contributor guides plus a machine-readable release evidence
  generator and expanded CI matrix.
- Added the first tracked implementation-plan ledger and CI skeleton for
  deterministic package, example, Android, iOS, privacy-manifest, and
  requirements checks.
- Added native method-channel and export golden characterization fixtures for
  the current v1 integration surface.
- Added native protocol negotiation, typed settings/battery diagnostics,
  read-only readiness snapshots, staged permission-step requests, and a
  replaying session/action snapshot.
- Added explicit `startNewTrack`, `startOrRecoverTrack`, and
  `resumeCurrentTrack(owner:)` APIs with owner-aware conflicts and typed start
  dispositions.
- Added bounded `TrackQuery`/`TrackPage` history pagination through
  `TrackingClient.listTrackPage()` and the default SQLite repository.
- Added owner-scoped, snapshot-bounded segment and point cursors, accepted-only
  geometry reads, a one-MiB decoded-page budget, and a typed safety ceiling for
  the legacy all-route bundle materializer.
- Added immutable configuration epochs and point-level epoch references so
  every newly evaluated fix records its resolved preset and quality-policy
  provenance; malformed legacy configuration remains explicitly unknown.
- Added the internal incremental export foundation with paged GeoJSON/KML/GPX
  encoders, atomic filesystem sinks, progress, cancellation, owner-generation
  fencing, and bounded 100,000-point export coverage.
- Added V2 bounded exports with typed content-URI/local-file destinations,
  Android MediaStore streaming, atomic pre-Q publication, owner-scoped managed
  export inventory, and explicitly disposable share-cache copies.
- Added owner-scoped Abort/Delete/Erase privacy commands with explicit
  confirmation, track-scoped native-journal cleanup, non-cascading operation
  recovery records, cancelled-route classification, and managed export
  inventory access/deletion.
- Added runtime configuration validation, resolved accuracy values, an advanced
  extension barrel, and the initial stable error-code ledger.
- Moved Android pending-location journal access behind a shared lazy
  coordinator with a bounded worker queue and worker-looper location callbacks.
- Fenced Android Activity Recognition registration with generation-specific
  PendingIntents so stale broadcasts cannot alter a later route's motion state.
- Added active native prerequisite interruption for Android permission/provider
  loss and iOS Precise/authorization downgrade.
- Moved iOS native location-journal prepare/append/read/ack work onto a
  dedicated serial queue and fenced Pause/Complete until queued journal writes
  are durable.
- Added sequence/cursor-based, record- and byte-bounded native pending-location
  pages on Android and iOS.
- Made Android native-journal capacity checks use live SQLite pages/payload
  bytes with bounded WAL checkpoint maintenance, and made iOS compute its
  SQLite page ceiling from the actual configured page size.
- Added redacted native journal diagnostics and Android Start/service preflight
  so journal initialization failures are surfaced before capture begins.
- Quarantined mismatched native location events as rejected audit points before
  acknowledging them to the native journal.
- Ensured completing a paused route clears matching native paused-session
  metadata on Android and iOS.
- Made Android 9-and-earlier public Downloads export require the legacy storage
  permission at export time instead of attempting an undeclared write.
- Declared the iOS UserDefaults required-reason API in the packaged privacy
  manifest.
- Removed the unused Android `WAKE_LOCK` permission from the plugin manifest and
  setup documentation.

## 0.1.2

- Added low, medium, high (default), and precised tracking-accuracy presets,
  with typed native-accuracy control and per-value sampling overrides.
- Made Android service restart policy active-route-only, with full teardown on
  pause/completion and clean recreation on resume.
- Made the iOS capture manager process-scoped so Flutter engine/scene rebuilds
  do not interrupt an active route.
- Added an iOS 17+ `CLBackgroundActivitySession` for active background capture
  and invalidate it on pause/completion.
- Standardized the public API on `TrackingClient`, `Tracking`, and
  `TrackingConfiguration`.
- Replaced patrol metadata with normalized, timestamp-suffixed route IDs and a
  schema version 3 migration that preserves legacy values.
- Added route-identifier entry to the example Start flow.
- Changed the default route-retention policy and example selection to
  `keepAll`.

## 0.1.1

- Update documentation
- Update dart file conventions
- Added safe selected-route deletion for completed and failed tracks.
- Added recorded-route overflow actions for GeoJSON/KML/GPX export, MapLibre
  viewing, and confirmed deletion in the example app.

## 0.1.0

- Added native Android foreground-service and iOS Core Location tracking.
- Added activity recognition and adaptive moving/stationary sampling profiles.
- Added per-fix mock/simulation evidence with allow, flag, and reject policies.
- Added durable Track, TrackSegment, and TrackPoint SQLite storage.
- Added start, crash-durable pause, next-day resume, completion, and startup
  reconciliation.
- Added acknowledgement-based Android and iOS native fix journals for
  Flutter-engine handoff recovery.
- Added a leased SQLite upload outbox with deterministic idempotency keys,
  encoded-byte limits, persisted retry state, and completion handshakes.
- Added offline GeoJSON, KML, and GPX export with segment preservation.
- Added CocoaPods and Swift Package Manager integration for iOS.
- Added an Android/iOS example app and automated lifecycle/export tests.
