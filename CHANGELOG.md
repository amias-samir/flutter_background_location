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
