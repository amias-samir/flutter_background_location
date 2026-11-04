# Export

Export recorded routes as GeoJSON, KML or GPX, convert between those formats,
and remove routes. Back to the [README](../README.md).

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
default and is labeled `raw`. The controllers' `exportTrack` accepts the same
option. Derived exports intentionally reject `includeRejectedPoints`, because
rejected points have no derived coordinates.

On Android 10+, `contentUri` is the reopenable MediaStore handle and
`displayPath` is informational only. On iOS and pre-scoped-storage Android,
`localFilePath` is present instead. Exactly one of those two access handles is
set. The package adds no sharing dependency.

The compatibility exporter below materializes a complete route and returns its
legacy required `path`. Keep it for existing integrations and bounded routes.

Without a filename, track and trip exports use their route identifier. An
explicit `fileName` overrides it; the correct extension is added or repaired
automatically, and destinations may add a suffix to avoid collisions.

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

## Export geometry

- `TrackExportOptions.geometryContinuity` selects raw evidence, proven
  automatic-gap merging, or explicit connect-all presentation.
- GeoJSON uses a `LineString` for one presentation part and a
  `MultiLineString` for multiple parts.
- GeoJSON segments with fewer than two accepted coordinates are omitted from
  line geometry. Optional point features can preserve them for diagnostics.
- KML writes a line per multi-point segment and a point for a one-fix segment.
  Heights are written as recorded, with 0 for unknown and no `altitudeMode`,
  so KML clients clamp the route to the ground. Android heights are above the
  WGS 84 ellipsoid and iOS heights above mean sea level.
- GPX writes one `<trkseg>` per stored segment, including one-fix segments.
- Rejected points can be included as diagnostics but never enter route
  geometry when their coordinates are invalid or non-finite.
- Recorded stops are exported by default: a GeoJSON Point feature with
  `featureType: stop`, `startedAt`, `endedAt`, `durationSeconds`, `kind`,
  `evidenceCount` and `radiusMeters`; a GPX `<wpt>` of type `stop`, before the
  track, with those values as `fbl:` extensions; and a KML Placemark with a
  `TimeSpan`. Set `TrackExportOptions.includeStops` to false to leave them
  out. Routes without stop records export as before.
- The route's summary is exported with it: GeoJSON route properties, GPX
  `fbl:` metadata extensions and KML `ExtendedData` carry `recordingSeconds`,
  `movingSeconds`, `stoppedSeconds`, `pausedSeconds`, `stopCount`,
  `qualityEventCount` and `visibleGapCount`, plus `maxSpeedMetersPerSecond`,
  `averageMovingSpeedMetersPerSecond`, `stepCount` and
  `cleanedDistanceMeters` when known.
- A derived-geometry export reports the derived line's distance and
  `geometrySource: derived:<run id>`.
- `TrackExportOptions.includeDiagnosticProperties` adds coordinate-free
  per-fix evidence to GeoJSON point features and GPX `fbl:` extensions:
  vertical accuracy, Doppler speed and heading with their accuracies,
  provider, native sampling profile, activity source, raw type, evidence state
  and age, receipt delay, and quality policy version. It is off by default.

## Converting route file formats

`RouteFormatConverter` converts existing route content directly between
GeoJSON, GPX, and KML. It works in memory, so the host application remains in
control of file selection and storage.

```dart
const converter = RouteFormatConverter();

final gpx = converter.geoJsonToGpx(geoJsonContents);
final kml = converter.gpxToKml(gpxContents);
final geoJson = converter.kmlToGeoJson(kmlContents);
```

For a format chosen at runtime, use `convert`:

```dart
final converted = converter.convert(
  contents: sourceContents,
  sourceFormat: TrackExportFormat.gpx,
  targetFormat: TrackExportFormat.geoJson,
);
```

All six directions are supported. The converter preserves route parts,
elevation, route names, and coordinate timestamps when those values are
available. Format-specific metadata that has no equivalent in the destination
may not be retained. Invalid input or input without usable coordinates throws a
`FormatException`.

## Abort, delete, and erase are different operations

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

## Deleting a selected recorded route

Delete an individual completed or failed route with:

```dart
await tracking.deleteTrack(trackId);
```

The SQLite foreign-key relationships cascade the deletion to the route's
segments, points, health events, lifecycle operations, pending commands, and
upload-outbox rows. Active, paused, interrupted, starting, and stopping tracks
are rejected because they may still be running or resumable. This operation is
permanent, so export or upload the route first when another copy is required.

