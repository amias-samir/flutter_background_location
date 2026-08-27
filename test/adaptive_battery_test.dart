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
    expect(decision.proposedConfig.locationAccuracy, TrackingAccuracy.high);
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
        presetDefinitionVersion: 1,
        qualityPolicyVersion: 1,
        createdAt: now,
        activationSequence: configs.length + 1,
        activatedAt: now,
      ),
      resumedCapture: true,
    );
  }
}
