/// Version and capability information negotiated with the native tracker.
///
/// The package uses this read-only description before calling newer platform
/// methods. Unknown capability strings are preserved so newer native binaries
/// remain inspectable by older Dart code.
final class NativeTrackingProtocol {
  NativeTrackingProtocol({
    required this.version,
    required Iterable<String> capabilityCodes,
  }) : capabilityCodes = Set<String>.unmodifiable(
          capabilityCodes
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty),
        );

  /// Legacy native implementations predate the protocol-info method.
  NativeTrackingProtocol.legacy()
      : version = 1,
        capabilityCodes = const <String>{};

  /// Monotonic method-channel protocol version reported by native code.
  final int version;

  /// Stable native capability identifiers.
  ///
  /// This set may contain strings unknown to the current Dart package.
  final Set<String> capabilityCodes;

  /// Whether the native side advertises [code].
  bool supports(String code) => capabilityCodes.contains(code);

  factory NativeTrackingProtocol.fromMap(Map<Object?, Object?> map) {
    final rawVersion = map['version'];
    final version = rawVersion is num ? rawVersion.toInt() : 1;
    final rawCapabilities = map['capabilityCodes'] ?? map['capabilities'];
    final capabilityCodes = switch (rawCapabilities) {
      Iterable<Object?> values => values.whereType<String>(),
      String value => <String>[value],
      _ => const <String>[],
    };
    return NativeTrackingProtocol(
      version: version,
      capabilityCodes: capabilityCodes,
    );
  }
}

/// Known native capability identifiers.
///
/// These constants are conveniences only. The negotiated protocol can contain
/// additional capability strings that this package version does not know yet.
abstract final class NativeTrackingCapabilities {
  static const pagedJournal = 'paged_journal';
  static const byteBoundedJournal = 'byte_bounded_journal';
  static const typedExportDestination = 'typed_export_destination';
  static const locationSettings = 'location_settings';
  static const batteryOptimizationSettings = 'battery_optimization_settings';
  static const commandLease = 'command_lease';
  static const healthSnapshot = 'health_snapshot';
  static const stagedPermissionRequests = 'staged_permission_requests';
  static const activePrerequisiteMonitor = 'active_prerequisite_monitor';
  static const iosSerialJournalQueue = 'ios_serial_journal_queue';
  static const nativeJournalDiagnostics = 'native_journal_diagnostics';
  static const sharedPendingLocationCoordinator =
      'shared_pending_location_coordinator';
  static const checkedLifecyclePersistence = 'checked_lifecycle_persistence';
  static const pausedStopExpectedTrack = 'paused_stop_expected_track';
  static const legacyPublicExportPermissionGate =
      'legacy_public_export_permission_gate';
  static const streamingExportV2 = 'streaming_export_v2';
  static const trackScopedNativeClear = 'track_scoped_native_clear';
  static const iosSignificantChangeRecovery = 'ios_significant_change_recovery';
}
