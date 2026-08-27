import 'tracking_config.dart';

/// Versions attached to each immutable policy epoch.
abstract final class TrackingPolicyVersions {
  /// Version of the predefined [TrackingAccuracy] values.
  static const int presetDefinition = 2;

  /// Version of the point acceptance/rejection policy.
  static const int qualityPolicy = 1;
}

/// Immutable configuration and policy provenance for a sequence range.
///
/// Epoch 1 is created with each route. Runtime configuration changes are not
/// part of this foundation; a later capability may append higher-numbered
/// epochs but must never edit an existing row.
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
  });

  final String id;
  final String trackId;
  final int epochNumber;
  final TrackingConfig resolvedConfig;
  final int presetDefinitionVersion;
  final int qualityPolicyVersion;
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
