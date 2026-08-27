## Unreleased

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
