/// Native feature availability reported by the active platform implementation.
final class TrackingCapabilityReport {
  /// Creates an immutable capability snapshot.
  const TrackingCapabilityReport({
    required this.platform,
    required this.backgroundTracking,
    required this.activityRecognition,
    required this.mockDetection,
    required this.pauseResume,
    required this.adaptiveSampling,
    required this.terminatedRecovery,
    this.rebootRestartBestEffort = false,
    this.terminationRecoveryModes = const <String>[],
  });

  /// Native platform identifier, such as `android` or `ios`.
  final String platform;

  /// Whether active routes can continue while the app is backgrounded.
  final bool backgroundTracking;

  /// Whether native activity classification is available.
  final bool activityRecognition;

  /// Whether the platform exposes mock-location evidence.
  final bool mockDetection;

  /// Whether native capture supports explicit pause and resume.
  final bool pauseResume;

  /// Whether native moving/stationary sampling changes are supported.
  final bool adaptiveSampling;

  /// Whether the platform can automatically rebuild a terminated tracker.
  /// This remains OS/OEM controlled even when true.
  final bool terminatedRecovery;

  /// Whether an active Android session may restart after device reboot.
  final bool rebootRestartBestEffort;

  /// Stable identifiers for supported termination-recovery strategies.
  final List<String> terminationRecoveryModes;

  /// Decodes a native capabilities payload with conservative defaults.
  factory TrackingCapabilityReport.fromMap(Map<Object?, Object?> map) =>
      TrackingCapabilityReport(
        platform: map['platform'] as String? ?? 'unknown',
        backgroundTracking: map['backgroundTracking'] as bool? ?? true,
        activityRecognition: map['activityRecognition'] as bool? ?? false,
        mockDetection: map['mockDetection'] as bool? ?? false,
        pauseResume: map['pauseResume'] as bool? ?? true,
        adaptiveSampling: map['adaptiveSampling'] as bool? ?? false,
        terminatedRecovery: map['terminatedRecovery'] as bool? ?? false,
        rebootRestartBestEffort:
            map['rebootRestartBestEffort'] as bool? ?? false,
        terminationRecoveryModes: List<String>.unmodifiable(
          (map['terminationRecoveryModes'] as List?)?.whereType<String>() ??
              const <String>[],
        ),
      );
}
