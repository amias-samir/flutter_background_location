import 'tracking_config.dart';

/// Versions attached to each immutable policy epoch.
abstract final class TrackingPolicyVersions {
  /// Version of the predefined [TrackingAccuracy] values.
  static const int presetDefinition = 4;

  /// Version of the point acceptance/rejection policy.
  static const int qualityPolicy = 1;

  /// Version of accepted-gap classification and topology semantics.
  ///
  /// Version 3 keeps a route's segment across the provider restart that
  /// applies a runtime configuration update.
  static const int continuityPolicy = 3;

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

  /// Quality policy versions this build can evaluate, oldest first.
  static const List<int> supportedQualityPolicies = <int>[1];

  /// Continuity policy versions this build can evaluate, oldest first.
  static const List<int> supportedContinuityPolicies = <int>[2, 3];

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
        resolvedConfig: TrackingConfig.fromJson(
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
        proposedConfig: TrackingConfig.fromJson(
          row['proposed_configuration_json']! as String,
        ),
        previousConfig: TrackingConfig.fromJson(
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
