/// Advanced extension contracts for custom storage, native adapters, export
/// writers, and upload integrations.
///
/// Normal applications should import `flutter_background_location_tracker.dart`.
/// This library keeps lower-level contracts discoverable without removing the
/// current main-barrel re-exports during the pre-1.0 compatibility window.
library;

export 'flutter_background_location_tracker.dart';
export 'src/export/track_export_service.dart';
export 'src/platform/tracker_adapter.dart';
export 'src/storage/track_repository.dart';
export 'src/upload/track_uploader.dart';
