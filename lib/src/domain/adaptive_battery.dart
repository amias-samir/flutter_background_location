import 'dart:collection';

import 'activity_snapshot.dart';
import 'tracking_config.dart';
import 'tracking_configuration_epoch.dart';

enum AdaptiveBatteryMode { disabled, shadow, apply }

enum AdaptiveThermalState { nominal, fair, serious, critical, unavailable }

/// Host-owned lower bounds. Adaptive policy can be more accurate than these
/// limits, never less accurate.
final class AdaptiveFidelityBounds {
  const AdaptiveFidelityBounds({
    required this.leastAccurateProfile,
    required this.maximumMovingInterval,
    required this.maximumMovingDistanceFilterMeters,
    required this.maximumStationaryInterval,
    required this.maximumStationaryDistanceFilterMeters,
  });

  factory AdaptiveFidelityBounds.fromStaticConfig(TrackingConfig config) =>
      AdaptiveFidelityBounds(
        leastAccurateProfile: config.locationAccuracy,
        maximumMovingInterval: config.movingInterval,
        maximumMovingDistanceFilterMeters: config.movingDistanceFilterMeters,
        maximumStationaryInterval: config.stationaryInterval,
        maximumStationaryDistanceFilterMeters:
            config.stationaryDistanceFilterMeters,
      );

  final TrackingAccuracy leastAccurateProfile;
  final Duration maximumMovingInterval;
  final int maximumMovingDistanceFilterMeters;
  final Duration maximumStationaryInterval;
  final int maximumStationaryDistanceFilterMeters;
}

/// Versioned host policy for bounded, local-only adaptive sampling.
final class AdaptiveBatteryPolicy {
  const AdaptiveBatteryPolicy({
    required this.version,
    required this.bounds,
    this.mode = AdaptiveBatteryMode.shadow,
    this.lowBatteryPercent = 20,
    this.minimumStationaryDwell = const Duration(minutes: 5),
    this.minimumResidenceTime = const Duration(minutes: 3),
    this.maximumTransitionsPerHour = 4,
    this.minimumActivityConfidence = 70,
    this.queuePressurePointCount = 8000,
  })  : assert(version > 0),
        assert(lowBatteryPercent >= 0 && lowBatteryPercent <= 100),
        assert(maximumTransitionsPerHour > 0),
        assert(
            minimumActivityConfidence >= 0 && minimumActivityConfidence <= 100),
        assert(queuePressurePointCount > 0);

  final int version;
  final AdaptiveBatteryMode mode;
  final AdaptiveFidelityBounds bounds;
  final int lowBatteryPercent;
  final Duration minimumStationaryDwell;
  final Duration minimumResidenceTime;
  final int maximumTransitionsPerHour;
  final int minimumActivityConfidence;
  final int queuePressurePointCount;
}

/// Coordinate-free inputs supplied by the host/platform integration.
final class AdaptiveBatteryObservation {
  const AdaptiveBatteryObservation({
    required this.observedAt,
    this.batteryPercent,
    this.charging,
    this.lowPowerMode = false,
    this.thermalState = AdaptiveThermalState.unavailable,
    this.activityType = TrackingActivityType.unknown,
    this.activityConfidence = 0,
    this.stationaryDwell = Duration.zero,
    this.recentFixAccuracyMeters,
    this.pendingNativeEvents,
  });

  final DateTime observedAt;
  final int? batteryPercent;
  final bool? charging;
  final bool lowPowerMode;
  final AdaptiveThermalState thermalState;
  final TrackingActivityType activityType;
  final int activityConfidence;
  final Duration stationaryDwell;
  final double? recentFixAccuracyMeters;
  final int? pendingNativeEvents;
}

enum AdaptiveBatteryDecisionKind { unchanged, shadow, apply, rateLimited }

final class AdaptiveBatteryDecision {
  const AdaptiveBatteryDecision({
    required this.kind,
    required this.policyVersion,
    required this.reasonCode,
    required this.previousConfig,
    required this.proposedConfig,
    required this.observedAt,
  });

  final AdaptiveBatteryDecisionKind kind;
  final int policyVersion;
  final String reasonCode;
  final TrackingConfig previousConfig;
  final TrackingConfig proposedConfig;
  final DateTime observedAt;

  bool get changesConfiguration =>
      previousConfig.toJson() != proposedConfig.toJson();
  bool get shouldApply => kind == AdaptiveBatteryDecisionKind.apply;

  Map<String, Object?> toRedactedMap() => <String, Object?>{
        'kind': kind.name,
        'policyVersion': policyVersion,
        'reasonCode': reasonCode,
        'observedAt': observedAt.toUtc().toIso8601String(),
        'previousAccuracy': previousConfig.accuracy.name,
        'proposedAccuracy': proposedConfig.accuracy.name,
      };
}

/// Deterministic adaptive policy with residence-time and transition-rate
/// hysteresis. It performs no I/O and never changes configuration by itself.
final class AdaptiveBatteryPolicyEngine {
  AdaptiveBatteryPolicyEngine({
    required this.staticConfig,
    required this.policy,
  }) : _currentConfig = staticConfig {
    staticConfig.validate(context: 'Adaptive static TrackingConfig');
    _validateBounds(policy.bounds);
  }

  final TrackingConfig staticConfig;
  AdaptiveBatteryPolicy policy;
  TrackingConfig _currentConfig;
  DateTime? _lastTransitionAt;
  final List<DateTime> _transitions = <DateTime>[];
  AdaptiveBatteryDecision? _lastDecision;

  TrackingConfig get currentConfig => _currentConfig;
  AdaptiveBatteryDecision? get lastDecision => _lastDecision;
  UnmodifiableListView<DateTime> get transitionTimes =>
      UnmodifiableListView<DateTime>(_transitions);

  AdaptiveBatteryDecision evaluate(AdaptiveBatteryObservation observation) {
    final observedAt = observation.observedAt.toUtc();
    _transitions.removeWhere(
      (value) => observedAt.difference(value) >= const Duration(hours: 1),
    );
    final target = _target(observation);
    final proposed = _boundedConfig(target.$1);
    var kind = AdaptiveBatteryDecisionKind.unchanged;
    var reason = target.$2;
    if (policy.mode == AdaptiveBatteryMode.disabled) {
      reason = 'adaptive_disabled';
    } else if (proposed.toJson() != _currentConfig.toJson()) {
      final residenceBlocked = _lastTransitionAt != null &&
          observedAt.difference(_lastTransitionAt!) <
              policy.minimumResidenceTime;
      final rateBlocked =
          _transitions.length >= policy.maximumTransitionsPerHour;
      if (residenceBlocked || rateBlocked) {
        kind = AdaptiveBatteryDecisionKind.rateLimited;
        reason = residenceBlocked
            ? 'minimum_residence_time'
            : 'maximum_transition_rate';
      } else {
        kind = policy.mode == AdaptiveBatteryMode.apply
            ? AdaptiveBatteryDecisionKind.apply
            : AdaptiveBatteryDecisionKind.shadow;
      }
    }
    return _lastDecision = AdaptiveBatteryDecision(
      kind: kind,
      policyVersion: policy.version,
      reasonCode: reason,
      previousConfig: _currentConfig,
      proposedConfig: proposed,
      observedAt: observedAt,
    );
  }

  void markApplied(AdaptiveBatteryDecision decision) {
    if (!decision.shouldApply) {
      throw StateError('Only an apply decision can be committed.');
    }
    _currentConfig = decision.proposedConfig;
    _lastTransitionAt = decision.observedAt;
    _transitions.add(decision.observedAt);
  }

  void markStaticRestored(DateTime observedAt) {
    _currentConfig = staticConfig;
    _lastTransitionAt = observedAt.toUtc();
    _transitions.add(observedAt.toUtc());
  }

  (TrackingAccuracy, String) _target(
    AdaptiveBatteryObservation observation,
  ) {
    if (policy.mode == AdaptiveBatteryMode.disabled) {
      return (staticConfig.accuracy, 'adaptive_disabled');
    }
    final batteryConstrained = observation.lowPowerMode ||
        (observation.batteryPercent != null &&
            observation.batteryPercent! <= policy.lowBatteryPercent &&
            observation.charging != true);
    if (observation.thermalState == AdaptiveThermalState.critical ||
        observation.thermalState == AdaptiveThermalState.serious) {
      return (TrackingAccuracy.low, 'thermal_pressure');
    }
    if ((observation.pendingNativeEvents ?? 0) >=
        policy.queuePressurePointCount) {
      return (TrackingAccuracy.low, 'journal_pressure');
    }
    if (batteryConstrained) return (TrackingAccuracy.low, 'power_constraint');
    if (observation.activityType == TrackingActivityType.stationary &&
        observation.activityConfidence >= policy.minimumActivityConfidence &&
        observation.stationaryDwell >= policy.minimumStationaryDwell) {
      return (TrackingAccuracy.medium, 'stationary_dwell');
    }
    final poorFix = observation.recentFixAccuracyMeters;
    if (poorFix != null &&
        poorFix.isFinite &&
        poorFix > staticConfig.maximumAcceptedAccuracyMeters) {
      return (TrackingAccuracy.high, 'poor_fix_quality');
    }
    return (staticConfig.accuracy, 'static_profile');
  }

  TrackingConfig _boundedConfig(TrackingAccuracy requested) {
    final least = _moreAccurate(requested, policy.bounds.leastAccurateProfile);
    final preset = TrackingConfig(accuracy: least);
    Duration capDuration(Duration value, Duration maximum) =>
        value > maximum ? maximum : value;
    int capInt(int value, int maximum) => value > maximum ? maximum : value;
    return TrackingConfig(
      accuracy: least,
      locationAccuracy: least,
      movingInterval: capDuration(
          preset.movingInterval, policy.bounds.maximumMovingInterval),
      movingDistanceFilterMeters: capInt(
        preset.movingDistanceFilterMeters,
        policy.bounds.maximumMovingDistanceFilterMeters,
      ),
      stationaryInterval: capDuration(
        preset.stationaryInterval,
        policy.bounds.maximumStationaryInterval,
      ),
      stationaryDistanceFilterMeters: capInt(
        preset.stationaryDistanceFilterMeters,
        policy.bounds.maximumStationaryDistanceFilterMeters,
      ),
      maximumAcceptedAccuracyMeters: staticConfig.maximumAcceptedAccuracyMeters,
      maximumPlausibleSpeedMetersPerSecond:
          staticConfig.maximumPlausibleSpeedMetersPerSecond,
      stationaryConfirmationDuration:
          staticConfig.stationaryConfirmationDuration,
      stationaryProbeDisplacementMeters:
          staticConfig.stationaryProbeDisplacementMeters,
      stationaryConfidenceThreshold: staticConfig.stationaryConfidenceThreshold,
      movingConfidenceThreshold: staticConfig.movingConfidenceThreshold,
      movingConfirmationCount: staticConfig.movingConfirmationCount,
      activityRecognitionInterval: staticConfig.activityRecognitionInterval,
      mockLocationPolicy: staticConfig.mockLocationPolicy,
      batchPointCount: staticConfig.batchPointCount,
      batchMaxAge: staticConfig.batchMaxAge,
      largeGapThreshold: staticConfig.largeGapThreshold,
      firstFixTimeout: staticConfig.firstFixTimeout,
      androidNotificationTitle: staticConfig.androidNotificationTitle,
      androidNotificationText: staticConfig.androidNotificationText,
    );
  }

  static TrackingAccuracy _moreAccurate(
    TrackingAccuracy first,
    TrackingAccuracy second,
  ) =>
      _rank(first) >= _rank(second) ? first : second;

  static int _rank(TrackingAccuracy value) => switch (value) {
        TrackingAccuracy.low => 0,
        TrackingAccuracy.medium => 1,
        TrackingAccuracy.high => 2,
        TrackingAccuracy.precised => 3,
      };

  static void _validateBounds(AdaptiveFidelityBounds bounds) {
    if (bounds.maximumMovingInterval <= Duration.zero ||
        bounds.maximumStationaryInterval <= Duration.zero ||
        bounds.maximumMovingDistanceFilterMeters < 0 ||
        bounds.maximumStationaryDistanceFilterMeters < 0) {
      throw ArgumentError('Adaptive fidelity bounds are invalid.');
    }
  }
}

/// Applies eligible decisions through the atomic configuration-epoch
/// capability and rolls back through that same durable path.
final class AdaptiveTrackingCoordinator {
  const AdaptiveTrackingCoordinator({
    required this.controller,
    required this.engine,
  });

  final TrackingConfigurationController controller;
  final AdaptiveBatteryPolicyEngine engine;

  Future<AdaptiveBatteryDecision> observe(
    AdaptiveBatteryObservation observation,
  ) async {
    final decision = engine.evaluate(observation);
    if (decision.shouldApply) {
      await controller.updateTrackingConfig(decision.proposedConfig);
      engine.markApplied(decision);
    }
    return decision;
  }

  Future<void> disableAndRestore({required DateTime observedAt}) async {
    engine.policy = AdaptiveBatteryPolicy(
      version: engine.policy.version,
      bounds: engine.policy.bounds,
      mode: AdaptiveBatteryMode.disabled,
      lowBatteryPercent: engine.policy.lowBatteryPercent,
      minimumStationaryDwell: engine.policy.minimumStationaryDwell,
      minimumResidenceTime: engine.policy.minimumResidenceTime,
      maximumTransitionsPerHour: engine.policy.maximumTransitionsPerHour,
      minimumActivityConfidence: engine.policy.minimumActivityConfidence,
      queuePressurePointCount: engine.policy.queuePressurePointCount,
    );
    if (engine.currentConfig.toJson() != engine.staticConfig.toJson()) {
      await controller.updateTrackingConfig(engine.staticConfig);
      engine.markStaticRestored(observedAt);
    }
  }
}
