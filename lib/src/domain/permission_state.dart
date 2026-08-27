/// Normalized foreground/background location authorization level.
enum LocationPermissionLevel {
  /// Authorization has not been determined or could not be read.
  unknown,

  /// Location authorization is currently denied.
  denied,

  /// Authorization requires a manual change in system settings.
  deniedForever,

  /// Location is allowed only while the app is in use.
  whileInUse,

  /// Location is authorized for background tracking.
  always
}

/// Read-only snapshot of platform prerequisites for background tracking.
final class TrackingPermissionState {
  /// Creates a normalized permission and service snapshot.
  const TrackingPermissionState({
    this.platform = 'unknown',
    required this.location,
    required this.locationServiceEnabled,
    this.preciseLocation = true,
    this.activityRecognitionGranted = false,
    this.notificationGranted = true,
    this.requiresSettings = false,
    this.canRequestBackground = false,
    this.message,
  });

  /// Native platform identifier, such as `android` or `ios`.
  final String platform;

  /// Current location authorization level.
  final LocationPermissionLevel location;

  /// Whether the device's system-wide location service is enabled.
  final bool locationServiceEnabled;

  /// Whether full/precise rather than approximate location is enabled.
  final bool preciseLocation;

  /// Whether motion/activity recognition is authorized.
  final bool activityRecognitionGranted;

  /// Whether the tracking notification can be displayed when required.
  final bool notificationGranted;

  /// Whether the next permission step must be completed in Settings.
  final bool requiresSettings;

  /// Whether the platform can still show a background-location prompt.
  final bool canRequestBackground;

  /// Optional platform guidance suitable for display to the user.
  final String? message;

  /// Whether mandatory background-capture prerequisites are currently met.
  bool get canTrackInBackground =>
      location == LocationPermissionLevel.always &&
      locationServiceEnabled &&
      preciseLocation &&
      notificationGranted;

  /// Decodes a native permission-state payload.
  factory TrackingPermissionState.fromMap(Map<Object?, Object?> map) {
    final raw = (map['location'] ?? map['locationPermission'] ?? 'unknown')
        .toString()
        .toLowerCase()
        .replaceAll('_', '');
    final location = switch (raw) {
      'always' ||
      'authorizedalways' ||
      'granted' =>
        LocationPermissionLevel.always,
      'whileinuse' ||
      'wheninuse' ||
      'authorizedwheninuse' =>
        LocationPermissionLevel.whileInUse,
      'deniedforever' || 'restricted' => LocationPermissionLevel.deniedForever,
      'denied' => LocationPermissionLevel.denied,
      _ => LocationPermissionLevel.unknown,
    };
    return TrackingPermissionState(
      platform: map['platform'] as String? ?? 'unknown',
      location: location,
      locationServiceEnabled: map['locationServiceEnabled'] as bool? ??
          map['serviceEnabled'] as bool? ??
          true,
      preciseLocation: map['preciseLocation'] as bool? ?? true,
      activityRecognitionGranted:
          map['activityRecognitionGranted'] as bool? ?? false,
      notificationGranted: map['notificationGranted'] as bool? ?? true,
      requiresSettings: map['requiresSettings'] as bool? ?? false,
      canRequestBackground: map['canRequestBackground'] as bool? ?? false,
      message: map['message'] as String?,
    );
  }
}

/// Error raised when a tracking command lacks required authorization.
final class TrackingPermissionException implements Exception {
  /// Creates an exception containing the state that blocked tracking.
  const TrackingPermissionException(this.state);

  /// Permission snapshot observed when the command was rejected.
  final TrackingPermissionState state;

  /// Returns concise user-facing guidance for the blocking prerequisite.
  @override
  String toString() {
    if (state.message != null) return state.message!;
    if (!state.locationServiceEnabled) return 'Location services are disabled.';
    if (!state.preciseLocation) return 'Precise location is required.';
    if (!state.notificationGranted) {
      return 'Notification permission is required for background tracking.';
    }
    if (state.location == LocationPermissionLevel.whileInUse) {
      return 'Always/background location permission is required.';
    }
    return 'Background location permission is not ready.';
  }
}
