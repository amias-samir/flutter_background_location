## Unreleased

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
  optional-sensor teardown without treating simulator runs as accuracy or
  battery evidence.

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
- Retuned all accuracy presets toward higher fidelity: `low` now matches the
  former medium profile, `medium` matches the former high profile, default
  `high` uses navigation accuracy with a 10-second moving interval, and
  `precised` accepts 15 m accuracy with a 15 m stationary filter. The example
  now explains the battery cost and can open Android battery settings from an
  explicit user action. New epochs record preset-definition version 3.
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
