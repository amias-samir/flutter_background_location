final class TrackingCapabilityReport {
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

  final String platform;
  final bool backgroundTracking;
  final bool activityRecognition;
  final bool mockDetection;
  final bool pauseResume;
  final bool adaptiveSampling;

  /// Whether the platform can automatically rebuild a terminated tracker.
  /// This remains OS/OEM controlled even when true.
  final bool terminatedRecovery;
  final bool rebootRestartBestEffort;
  final List<String> terminationRecoveryModes;

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
