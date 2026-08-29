# Contributing

Thank you for improving `flutter_background_location_tracker`.

## Before changing behavior

- Read the architecture, platform, data/export, testing, and detailed plan
  documents in `plugin_documents/` in a source checkout. That directory is
  intentionally excluded from the published package, so public behavior must
  also be documented in README, Dartdoc, tests, and this file.
- Preserve raw location evidence. Derived geometry must be separately
  versioned and removable.
- Keep lifecycle commands idempotent, owner-scoped, and commit-before-ack.
- Never log coordinates, route bodies, owner identifiers, command tokens, or
  export destinations in diagnostic/error messages.
- Additive optional capability interfaces are preferred over growing adapter
  and repository contracts implemented by package users.

## Required local checks

```shell
dart format --output=none --set-exit-if-changed lib test tool example/lib example/test
flutter analyze
flutter test
dart run tool/quality/validate_requirements.dart
dart run tool/quality/generate_release_evidence.dart
(cd example && flutter analyze && flutter test)
(cd example/android && ./gradlew testDebugUnitTest)
```

On macOS also build the unsigned iOS example and Swift package. Changes to
background lifecycle, permissions, activity recognition, export destinations,
or battery presets require physical-device evidence across the supported OS
matrix; simulator results are not GNSS or battery evidence.

Release maintainers validate sanitized aggregate physical evidence kept outside
the public repository with:

```shell
dart run tool/quality/validate_physical_qualification.dart \
  /approved/private/aggregate-evidence.json
```

The validator rejects coordinate/participant keys, missing scenario/preset
coverage, insufficient repetitions, missing variance metrics, unreviewed
greater-than-10% battery regressions, and incorrect force-quit recovery claims.

## Pull requests

Keep each pull request cohesive and reversible. Include its work-package ID,
compatibility classification, migration/rollback notes, automated evidence,
and any remaining physical/manual release gate. Update
`tool/quality/requirements.yaml` and the error-code registry when contracts
change.
