import 'persisted_tracking_config.dart';
import 'tracking_config.dart';

/// Versions attached to each immutable policy epoch.
abstract final class TrackingPolicyVersions {
  /// Version of the predefined [TrackingAccuracy] values.
  ///
  /// Version 5 adds turn capture at 45° to the High and Precised presets
  /// ([TrackingConfig.turnCaptureDegrees]).
  ///
  /// Version 6 samples every preset under [samplingPolicy] 2
  /// ([TrackingConfig.samplingPolicyVersion]): High and Precised record one
  /// fix per moving interval or a turn on both platforms.
  static const int presetDefinition = 6;

  /// Version of the point acceptance/rejection policy.
  ///
  /// Version 2 adds the canonical stop hold for adaptive capture: while a still
  /// episode is current, fixes inside the hold radius are stored as rejected
  /// `stationary_hold` evidence and outliers as `stationary_outlier`. Other
  /// capture intents are evaluated exactly as in version 1.
  ///
  /// Version 3 makes a stop a stay at a place: it also starts after two
  /// minutes within the hold radius with no net progress and no moving
  /// evidence, walking inside the radius stays part of it, and it ends only
  /// when a fix leaves the radius with moving evidence, a Doppler speed or
  /// sustained displacement.
  ///
  /// Version 4 is version 3, and a riding fix of an adaptive route is
  /// accepted up to the vehicle accuracy envelope (see
  /// `FixQualityPolicy.ridingSpeedMetersPerSecond`).
  ///
  /// Version 5 decides the same on every chipset: the first far fix after a
  /// silence must prove itself with a precise Doppler speed, a fix the route
  /// could not have reached is held back until a later fix agrees with it,
  /// nothing inside the hold radius ends a stay, the radius comes from
  /// effective uncertainty and is clamped, and the riding envelope needs a
  /// credible Doppler speed. Decisions come only from evidence stored with
  /// each fix (`RouteDecisionEngine`), so a route decided live, after a
  /// restart or offline gets the same answers.
  static const int qualityPolicy = 5;

  /// Version of accepted-gap classification and topology semantics.
  ///
  /// Version 3 keeps a route's segment across the provider restart that
  /// applies a runtime configuration update.
  ///
  /// Version 4 ignores the native sampling-profile stamp: a gap is expected
  /// stationary suppression only when a stay explains it, and every accepted
  /// gap of at least `TrackingContinuityGap.visibleProviderGap` is decided.
  static const int continuityPolicy = 4;

  /// Version of the moving/stationary motion state machine, carried in the
  /// resolved configuration as `motionPolicyVersion` for native code.
  ///
  /// Version 2 keeps an adaptive still episode through unknown, tilting,
  /// low-confidence and missing activity readings, and ends it only on
  /// positive moving evidence, valid Doppler speed or sustained displacement.
  static const int motionPolicy = 2;

  /// Version of how native capture picks the fixes it records, carried in the
  /// resolved configuration as `samplingPolicyVersion`.
  ///
  /// Version 2 records one fix per moving interval or a turn from an
  /// unfiltered 1 Hz stream in the High and Precised moving profile.
  static const int samplingPolicy = 2;

  /// Preset label for routes recorded before epochs stored policy versions.
  ///
  /// Those builds did not record which definitions applied. The labels name
  /// the oldest definitions this package resolves and never change, so a
  /// repaired epoch keeps its label across later version bumps.
  static const int legacyPresetDefinition = 4;

  /// Quality label for routes recorded before epochs stored policy versions;
  /// see [legacyPresetDefinition].
  static const int legacyQualityPolicy = 1;

  /// Continuity version of epochs written before epochs recorded one.
  ///
  /// Version 2 was the only classifier in use when the epoch gained its
  /// continuity column, so a missing value replays exactly that behavior.
  static const int legacyContinuityPolicy = 2;

  /// Motion policy of configurations persisted before they recorded one.
  ///
  /// A route that was recording across a package upgrade keeps the state
  /// machine it started with.
  static const int legacyMotionPolicy = 1;

  /// Sampling policy of configurations persisted before they recorded one.
  static const int legacySamplingPolicy = 1;

  /// Quality policy versions this build can evaluate, oldest first.
  static const List<int> supportedQualityPolicies = <int>[1, 2, 3, 4, 5];

  /// Continuity policy versions this build can evaluate, oldest first.
  static const List<int> supportedContinuityPolicies = <int>[2, 3, 4];

  /// Motion policy versions this build can apply, oldest first.
  static const List<int> supportedMotionPolicies = <int>[1, 2];

  /// Sampling policy versions this build can apply, oldest first.
  static const List<int> supportedSamplingPolicies = <int>[1, 2];

  /// The quality policy that evaluates points recorded under [recorded].
  ///
  /// A supported version is applied as recorded, so upgrading the package
  /// never reinterprets a route that is already recording. An unsupported
  /// version, such as one written by a newer package, falls back to the
  /// newest supported version; decisions store the version actually applied.
  static int resolveQualityPolicy(int recorded) =>
      _resolve(recorded, supportedQualityPolicies);

  /// The continuity policy for [recorded]; see [resolveQualityPolicy].
  static int resolveContinuityPolicy(int recorded) =>
      _resolve(recorded, supportedContinuityPolicies);

  /// The motion policy for [recorded]; see [resolveQualityPolicy].
  static int resolveMotionPolicy(int recorded) =>
      _resolve(recorded, supportedMotionPolicies);

  /// The sampling policy for [recorded]; see [resolveQualityPolicy].
  static int resolveSamplingPolicy(int recorded) =>
      _resolve(recorded, supportedSamplingPolicies);

  static int _resolve(int recorded, List<int> supported) =>
      supported.contains(recorded) ? recorded : supported.last;
}

/// Immutable configuration and policy provenance for a sequence range.
///
/// Epoch 1 is created with each route. Each runtime configuration update
/// appends the next epoch, active from the next point sequence. Rows are
/// never edited; points are evaluated under the policy versions their epoch
/// recorded.
final class TrackingConfigurationEpoch {
  const TrackingConfigurationEpoch({
    required this.id,
    required this.trackId,
    required this.epochNumber,
    required this.resolvedConfig,
    required this.presetDefinitionVersion,
    required this.qualityPolicyVersion,
    required this.createdAt,
    required this.activationSequence,
    required this.activatedAt,
    this.continuityPolicyVersion =
        TrackingPolicyVersions.legacyContinuityPolicy,
  });

  final String id;
  final String trackId;
  final int epochNumber;
  final TrackingConfig resolvedConfig;
  final int presetDefinitionVersion;
  final int qualityPolicyVersion;

  /// Continuity classifier version for points in this epoch.
  ///
  /// Epochs written before this was recorded report
  /// [TrackingPolicyVersions.legacyContinuityPolicy].
  final int continuityPolicyVersion;
  final DateTime createdAt;

  /// First route-global point sequence evaluated by this epoch.
  final int activationSequence;

  /// Wall-clock evidence recorded when the epoch became active.
  final DateTime activatedAt;

  factory TrackingConfigurationEpoch.fromDatabase(
    Map<String, Object?> row,
  ) =>
      TrackingConfigurationEpoch(
        id: row['id']! as String,
        trackId: row['track_id']! as String,
        epochNumber: (row['epoch_number']! as num).toInt(),
        resolvedConfig: decodePersistedTrackingConfig(
          row['resolved_configuration_json']! as String,
        ),
        presetDefinitionVersion:
            (row['preset_definition_version']! as num).toInt(),
        qualityPolicyVersion: (row['quality_policy_version']! as num).toInt(),
        continuityPolicyVersion:
            (row['continuity_policy_version'] as num?)?.toInt() ??
                TrackingPolicyVersions.legacyContinuityPolicy,
        createdAt: DateTime.parse(row['created_at']! as String).toUtc(),
        activationSequence: (row['activation_sequence']! as num).toInt(),
        activatedAt: DateTime.parse(row['activated_at']! as String).toUtc(),
      );
}

enum TrackingConfigurationUpdateStage {
  pending,
  producerFenced,
  nativeApplied,
}

/// Durable state used to reconcile a configuration switch after process death.
final class TrackingConfigurationUpdateOperation {
  const TrackingConfigurationUpdateOperation({
    required this.id,
    required this.trackId,
    required this.epochNumber,
    required this.proposedConfig,
    required this.previousConfig,
    required this.stage,
    required this.createdAt,
  });

  final String id;
  final String trackId;
  final int epochNumber;
  final TrackingConfig proposedConfig;
  final TrackingConfig previousConfig;
  final TrackingConfigurationUpdateStage stage;
  final DateTime createdAt;

  factory TrackingConfigurationUpdateOperation.fromDatabase(
    Map<String, Object?> row,
  ) =>
      TrackingConfigurationUpdateOperation(
        id: row['id']! as String,
        trackId: row['track_id']! as String,
        epochNumber: (row['epoch_number']! as num).toInt(),
        proposedConfig: decodePersistedTrackingConfig(
          row['proposed_configuration_json']! as String,
        ),
        previousConfig: decodePersistedTrackingConfig(
          row['previous_configuration_json']! as String,
        ),
        stage: TrackingConfigurationUpdateStage.values.byName(
          row['stage']! as String,
        ),
        createdAt: DateTime.parse(row['created_at']! as String).toUtc(),
      );
}

/// Result of an atomic, producer-fenced runtime configuration update.
final class TrackingConfigurationUpdateResult {
  const TrackingConfigurationUpdateResult({
    required this.trackId,
    required this.epoch,
    required this.resumedCapture,
  });

  final String trackId;
  final TrackingConfigurationEpoch epoch;
  final bool resumedCapture;
}

/// Additive capability for changing a live route's resolved policy.
abstract interface class TrackingConfigurationController {
  Future<TrackingConfigurationUpdateResult> updateTrackingConfig(
    TrackingConfig config,
  );
}
