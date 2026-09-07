/// Public API for durable route tracking on Android and iOS.
///
/// Import this library from application code:
///
/// ```dart
/// import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
/// ```
///
/// Start with [TrackingClient.open] for normal single-day routes, or
/// [TrackingClient.openWithTrips] when one user-visible journey can continue
/// across multiple days. Both entry points return owner-scoped controllers that
/// expose lifecycle state through [TrackingSessionSnapshot], staged readiness
/// checks through [TrackingReadiness], and route storage/export helpers.
///
/// The main integration flow is:
///
/// 1. Configure Android manifest and iOS `Info.plist` permissions.
/// 2. Open one application-scoped controller for the signed-in [TrackingOwner].
/// 3. Use `checkReadiness()` and `requestNextPermission()` before Start.
/// 4. Drive Start, Pause, Resume, End day, and Complete from
///    `session.allowedActions`.
/// 5. Export completed Tracks or Trips as GeoJSON, KML, or GPX.
///
/// [TrackingConfig] controls accuracy, battery behavior, mock-location policy,
/// capture intent, and optional sensor-fusion evidence. Individual config
/// fields override the selected [TrackingAccuracy] preset.
library;

export 'src/application/tracking_client.dart';
export 'src/application/derived_geometry_service.dart';
export 'src/application/motion_evidence_reducer.dart';
export 'src/application/tracking_privacy_service.dart';
export 'src/application/route_geometry_assembler.dart';
export 'src/application/uncertainty_route_smoother.dart';
export 'src/domain/activity_snapshot.dart';
export 'src/domain/adaptive_battery.dart';
export 'src/domain/capability_report.dart';
export 'src/domain/derived_geometry.dart';
export 'src/domain/export_models.dart';
export 'src/domain/fix_quality.dart';
export 'src/domain/location_sample.dart';
export 'src/domain/motion_evidence.dart';
export 'src/domain/native_tracking_protocol.dart';
export 'src/domain/permission_state.dart';
export 'src/domain/route_geometry.dart';
export 'src/domain/route_geometry_processor.dart';
export 'src/domain/track.dart';
export 'src/domain/track_data_page.dart';
export 'src/domain/track_point.dart';
export 'src/domain/track_query.dart';
export 'src/domain/track_segment.dart';
export 'src/domain/tracker_status.dart';
export 'src/domain/trip.dart';
export 'src/domain/trip_query.dart';
export 'src/domain/tracking_config.dart';
export 'src/domain/tracking_configuration_epoch.dart';
export 'src/domain/tracking_continuity.dart';
export 'src/domain/tracking_error.dart';
export 'src/domain/tracking_health.dart';
export 'src/domain/tracking_privacy.dart';
export 'src/domain/tracking_quality.dart';
export 'src/domain/tracking_readiness.dart';
export 'src/domain/tracking_session_snapshot.dart';
export 'src/domain/tracking_settings.dart';
export 'src/domain/tracking_start.dart';
export 'src/export/track_export_service.dart';
export 'src/export/track_export_v2_service.dart';
export 'src/export/trip_export_service.dart';
export 'src/platform/tracker_adapter.dart';
export 'src/storage/track_repository.dart';
export 'src/storage/trip_repository.dart';
export 'src/upload/track_uploader.dart';
export 'src/upload/trip_completion_uploader.dart';
