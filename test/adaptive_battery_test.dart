import 'package:flutter_background_location_tracker/flutter_background_location_tracker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const staticConfig = TrackingConfig(accuracy: TrackingAccuracy.high);
  const relaxedBounds = AdaptiveFidelityBounds(
    leastAccurateProfile: TrackingAccuracy.low,
    maximumMovingInterval: Duration(minutes: 1),
    maximumMovingDistanceFilterMeters: 50,
    maximumStationaryInterval: Duration(minutes: 5),
    maximumStationaryDistanceFilterMeters: 200,
  );

  test('B1-04 defaults to shadow and preserves validation/mock guarantees', () {
    final engine = AdaptiveBatteryPolicyEngine(
      staticConfig: staticConfig,
      policy: const AdaptiveBatteryPolicy(
        version: 1,
        bounds: relaxedBounds,
      ),
    );
    final decision = engine.evaluate(AdaptiveBatteryObservation(
      observedAt: DateTime.utc(2026, 8, 26),
      batteryPercent: 10,
      charging: false,
    ));

    expect(decision.kind, AdaptiveBatteryDecisionKind.shadow);
    expect(decision.proposedConfig.accuracy, TrackingAccuracy.low);
    expect(decision.proposedConfig.maximumAcceptedAccuracyMeters,
        staticConfig.maximumAcceptedAccuracyMeters);
    expect(decision.proposedConfig.mockLocationPolicy,
        staticConfig.mockLocationPolicy);
    expect(engine.currentConfig.accuracy, TrackingAccuracy.high);
  });

  test('FIX-04 adaptive proposals keep every non-sampling host field', () {
    const hostConfig = TrackingConfig(
      captureIntent: RouteCaptureIntent.walking,
      motionFusionMode: MotionFusionMode.lowPowerSensorFusion,
      activityFreshnessThreshold: Duration(seconds: 50),
      staleActivityFallback: StaleActivityFallback.preserveCurrentProfile,
      unknownMotionFallback: UnknownMotionFallback.preserveCurrentProfile,
      motionEvidenceFreshness: Duration(seconds: 40),
      sensorProbeDuration: Duration(seconds: 3),
      sensorProbeCooldown: Duration(seconds: 30),
      sensorProbeMaximumDurationPerHour: Duration(minutes: 2),
    );
    final engine = AdaptiveBatteryPolicyEngine(
      staticConfig: hostConfig,
      policy: const AdaptiveBatteryPolicy(version: 1, bounds: relaxedBounds),
    );

    final proposed = engine
        .evaluate(AdaptiveBatteryObservation(
          observedAt: DateTime.utc(2026, 8, 26),
          batteryPercent: 10,
          charging: false,
        ))
        .proposedConfig;

    expect(proposed.accuracy, TrackingAccuracy.low);
    expect(proposed.captureIntent, RouteCaptureIntent.walking);
    expect(proposed.motionFusionMode, MotionFusionMode.lowPowerSensorFusion);
    expect(proposed.activityFreshnessThreshold, const Duration(seconds: 50));
    expect(
      proposed.staleActivityFallback,
      StaleActivityFallback.preserveCurrentProfile,
    );
    expect(
      proposed.unknownMotionFallback,
      UnknownMotionFallback.preserveCurrentProfile,
    );
    expect(proposed.motionEvidenceFreshness, const Duration(seconds: 40));
    expect(proposed.sensorProbeDuration, const Duration(seconds: 3));
    expect(proposed.sensorProbeCooldown, const Duration(seconds: 30));
    expect(
      proposed.sensorProbeMaximumDurationPerHour,
      const Duration(minutes: 2),
    );
    // Walking capture keeps its dense moving sampling under any preset.
    expect(
      proposed.movingInterval,
      TrackingConfig(
        accuracy: TrackingAccuracy.low,
        captureIntent: RouteCaptureIntent.walking,
      ).movingInterval,
    );
    expect(
      proposed.maximumAcceptedAccuracyMeters,
      hostConfig.maximumAcceptedAccuracyMeters,
    );
  });

  test('B1-04 fidelity bounds prevent implicit degradation', () {
    final engine = AdaptiveBatteryPolicyEngine(
      staticConfig: staticConfig,
      policy: AdaptiveBatteryPolicy(
        version: 1,
        bounds: AdaptiveFidelityBounds.fromStaticConfig(staticConfig),
        mode: AdaptiveBatteryMode.apply,
      ),
    );
    final decision = engine.evaluate(AdaptiveBatteryObservation(
      observedAt: DateTime.utc(2026, 8, 26),
      lowPowerMode: true,
    ));

    expect(decision.kind, AdaptiveBatteryDecisionKind.unchanged);
    expect(
      decision.proposedConfig.locationAccuracy,
      TrackingAccuracy.precised,
    );
    expect(decision.proposedConfig.movingInterval, staticConfig.movingInterval);
  });

  test('B1-04 applies via epoch controller, rate limits, and rolls back',
      () async {
    final controller = _FakeConfigurationController();
    final engine = AdaptiveBatteryPolicyEngine(
      staticConfig: staticConfig,
      policy: const AdaptiveBatteryPolicy(
        version: 2,
        bounds: relaxedBounds,
        mode: AdaptiveBatteryMode.apply,
        minimumResidenceTime: Duration(minutes: 10),
      ),
    );
    final coordinator = AdaptiveTrackingCoordinator(
      controller: controller,
      engine: engine,
    );
    final now = DateTime.utc(2026, 8, 26);

    final applied = await coordinator.observe(AdaptiveBatteryObservation(
      observedAt: now,
      batteryPercent: 10,
      charging: false,
    ));
    expect(applied.kind, AdaptiveBatteryDecisionKind.apply);
    expect(controller.configs, hasLength(1));

    final limited = await coordinator.observe(AdaptiveBatteryObservation(
      observedAt: now.add(const Duration(minutes: 1)),
      batteryPercent: 100,
      charging: true,
    ));
    expect(limited.kind, AdaptiveBatteryDecisionKind.rateLimited);

    await coordinator.disableAndRestore(
      observedAt: now.add(const Duration(minutes: 2)),
    );
    expect(controller.configs.last.toJson(), staticConfig.toJson());
    expect(engine.currentConfig.toJson(), staticConfig.toJson());
  });
}

final class _FakeConfigurationController
    implements TrackingConfigurationController {
  final List<TrackingConfig> configs = <TrackingConfig>[];

  @override
  Future<TrackingConfigurationUpdateResult> updateTrackingConfig(
    TrackingConfig config,
  ) async {
    configs.add(config);
    final now = DateTime.utc(2026, 8, 26);
    return TrackingConfigurationUpdateResult(
      trackId: 'track',
      epoch: TrackingConfigurationEpoch(
        id: 'epoch-${configs.length}',
        trackId: 'track',
        epochNumber: configs.length + 1,
        resolvedConfig: config,
        presetDefinitionVersion: TrackingPolicyVersions.presetDefinition,
        qualityPolicyVersion: 1,
        createdAt: now,
        activationSequence: configs.length + 1,
        activatedAt: now,
      ),
      resumedCapture: true,
    );
  }
}
