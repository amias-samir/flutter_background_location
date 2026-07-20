enum LocationPermissionLevel {
  unknown,
  denied,
  deniedForever,
  whileInUse,
  always
}

final class TrackingPermissionState {
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

  final String platform;
  final LocationPermissionLevel location;
  final bool locationServiceEnabled;
  final bool preciseLocation;
  final bool activityRecognitionGranted;
  final bool notificationGranted;
  final bool requiresSettings;
  final bool canRequestBackground;
  final String? message;

  bool get canTrackInBackground =>
      location == LocationPermissionLevel.always &&
      locationServiceEnabled &&
      preciseLocation &&
      notificationGranted;

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

final class TrackingPermissionException implements Exception {
  const TrackingPermissionException(this.state);

  final TrackingPermissionState state;

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
