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

  /// Native omits unknown kinematics and invalid altitudes instead of sending
  /// sentinel values. Dart normalizes payloads either way.
  static const normalizedLocationValidity = 'normalized_location_validity';

  /// Nested payload values such as motion evidence survive journal replay.
  static const journalNestedJsonPayload = 'journal_nested_json_payload';

  /// The location stream honors `replayOnListen: none`; other listeners get
  /// the backlog replayed in pages.
  static const listenReplayControl = 'listen_replay_control';

  /// iOS acquires fresh fixes with a bounded in-place accuracy burst instead
  /// of `requestLocation()`, which does nothing while updates run.
  static const iosProbeBurst = 'ios_probe_burst';

  /// Native status is a liveness tick on the fix path instead of an echo of
  /// every fix; Dart publishes status after each commit.
  static const statusFixEchoControl = 'status_fix_echo_control';

  /// Native code applies motion policy 2 to adaptive capture: the stationary
  /// profile survives unknown, tilting, low-confidence and missing activity
  /// readings and ends only on positive moving evidence, Doppler speed or
  /// sustained displacement.
  static const stationaryPolicyV2 = 'stationary_policy_v2';

  /// Native code counts steps in every capture generation with the device's
  /// step counter, when it has one and the activity permission is granted,
  /// and reports them as `stepCount` on location events and status.
  static const stepCount = 'step_count';

  /// Native code reports how completely the step counter counted
  /// (`stepCoverage` on location events and status), repairs a counter that
  /// falls silent while the device walks, and reports each stopped
  /// generation's final count (`stepFinal` in status).
  static const stepCountCoverage = 'step_count_coverage';

  /// Native code keeps a ring of count-free step counter events, read with
  /// `getStepCounterDiagnostics`.
  static const stepCounterDiagnostics = 'step_counter_diagnostics';

  /// Each journaled fix carries the activity readings and profile switches
  /// received since the previous one (`activityReadings`,
  /// `profileTransitions`), so a route drained from the journal decides as
  /// it did live.
  static const journaledDecisionInputs = 'journaled_decision_inputs';

  /// A fix's sampling profile is the one in effect when it was captured, on
  /// both platforms.
  static const profileStampAtCapture = 'profile_stamp_at_capture';

  /// Native code applies `samplingPolicyVersion` 2: one fix per moving
  /// interval or a turn from an unfiltered 1 Hz stream.
  static const fixSamplingV2 = 'fix_sampling_v2';
}
