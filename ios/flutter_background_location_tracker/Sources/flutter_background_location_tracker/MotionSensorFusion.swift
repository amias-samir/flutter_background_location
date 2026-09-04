import CoreMotion
import Foundation

/// Active-capture-only, coordinate-free motion collector.
///
/// Raw device-motion samples are reduced on a private queue and are never
/// emitted to Flutter or persisted.
final class MotionSensorFusion {
  private let pedometer = CMPedometer()
  private let motion = CMMotionManager()
  private let queue: OperationQueue = {
    let value = OperationQueue()
    value.name = "flutter-background-location-motion-fusion"
    value.maxConcurrentOperationCount = 1
    value.qualityOfService = .utility
    return value
  }()
  private let onDecision: ([String: Any]) -> Void

  private var configuration = TrackingConfiguration.defaults
  private var active = false
  private var generation: Int64 = 0
  private var probeActive = false
  private var probeStartedAt = Date.distantPast
  private var lastProbeCompletedAt = Date.distantPast
  private var dutyWindowStartedAt = Date.distantPast
  private var probeDurationUsedMs = 0.0
  private var accelerationSamples = 0
  private var accelerationSquaredSum = 0.0
  private var rotationSamples = 0
  private var rotationSquaredSum = 0.0
  private var stationaryCandidate = false

  init(onDecision: @escaping ([String: Any]) -> Void) {
    self.onDecision = onDecision
  }

  func start(configuration: TrackingConfiguration) {
    stop()
    self.configuration = configuration
    active = true
    generation += 1
    guard configuration.motionFusionMode != "platformActivityOnly" else {
      emit(state: "unknown", confidence: 0, reason: "sensor_fusion_disabled")
      return
    }
    guard CMPedometer.isStepCountingAvailable() else {
      emit(state: "unknown", confidence: 0, reason: "pedometer_unavailable")
      return
    }
    let currentGeneration = generation
    pedometer.startUpdates(from: Date()) { [weak self] data, _ in
      guard let self, self.active, self.generation == currentGeneration,
        let steps = data?.numberOfSteps.intValue, steps > 0
      else {
        return
      }
      self.emit(
        state: "moving",
        confidence: 95,
        reason: "fresh_step",
        supporting: ["step"],
        stepDetected: true
      )
    }
    emit(state: "unknown", confidence: 0, reason: "sensor_fusion_ready")
  }

  func stop() {
    active = false
    generation += 1
    pedometer.stopUpdates()
    motion.stopDeviceMotionUpdates()
    probeActive = false
    resetProbeFeatures()
  }

  @discardableResult
  func requestAmbiguityProbe(stationaryCandidate: Bool = false) -> Bool {
    guard active,
      configuration.motionFusionMode == "enhancedSensorFusion",
      !probeActive,
      motion.isDeviceMotionAvailable
    else {
      return false
    }
    let now = Date()
    guard now.timeIntervalSince(lastProbeCompletedAt) * 1_000
      >= configuration.sensorProbeCooldownMs
    else {
      return false
    }
    if now.timeIntervalSince(dutyWindowStartedAt) >= 3_600 {
      dutyWindowStartedAt = now
      probeDurationUsedMs = 0
    }
    guard probeDurationUsedMs + configuration.sensorProbeDurationMs
      <= configuration.sensorProbeMaximumDurationPerHourMs
    else {
      return false
    }

    resetProbeFeatures()
    self.stationaryCandidate = stationaryCandidate
    probeActive = true
    probeStartedAt = now
    motion.deviceMotionUpdateInterval = 0.05
    let currentGeneration = generation
    motion.startDeviceMotionUpdates(to: queue) { [weak self] sample, _ in
      guard let self, self.active, self.probeActive,
        self.generation == currentGeneration, let sample
      else {
        return
      }
      let acceleration = sqrt(
        sample.userAcceleration.x * sample.userAcceleration.x
          + sample.userAcceleration.y * sample.userAcceleration.y
          + sample.userAcceleration.z * sample.userAcceleration.z
      )
      let rotation = sqrt(
        sample.rotationRate.x * sample.rotationRate.x
          + sample.rotationRate.y * sample.rotationRate.y
          + sample.rotationRate.z * sample.rotationRate.z
      )
      self.accelerationSamples += 1
      self.accelerationSquaredSum += acceleration * acceleration
      self.rotationSamples += 1
      self.rotationSquaredSum += rotation * rotation
    }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + configuration.sensorProbeDurationMs / 1_000
    ) { [weak self] in
      self?.queue.addOperation { [weak self] in self?.finishProbe(generation: currentGeneration) }
    }
    return true
  }

  private func finishProbe(generation expectedGeneration: Int64) {
    guard active, probeActive, generation == expectedGeneration else { return }
    probeActive = false
    motion.stopDeviceMotionUpdates()
    let now = Date()
    let durationMs = max(0, now.timeIntervalSince(probeStartedAt) * 1_000)
    probeDurationUsedMs += durationMs
    lastProbeCompletedAt = now
    let accelerationEnergy = rms(accelerationSquaredSum, accelerationSamples)
    let rotationEnergy = rms(rotationSquaredSum, rotationSamples)
    let quiet = stationaryCandidate && accelerationSamples > 0
      && accelerationEnergy < 0.02 && rotationEnergy < 0.20
    var conflicts: [String] = []
    if accelerationEnergy >= 0.10 { conflicts.append("accelerometer") }
    if rotationEnergy >= 0.50 { conflicts.append("gyroscope") }
    emit(
      state: quiet ? "stationary" : "unknown",
      confidence: quiet ? 80 : 0,
      reason: quiet ? "bounded_probe_quiet" : "bounded_probe_ambiguous",
      supporting: quiet ? ["accelerometer", "gyroscope"] : [],
      conflicting: conflicts,
      sensorProbeUsed: true,
      extra: [
        "probeDurationMs": durationMs,
        "accelerometerSampleCount": accelerationSamples,
        "accelerationMotionEnergy": accelerationEnergy,
        "gyroscopeSampleCount": rotationSamples,
        "rotationEnergy": rotationEnergy,
        "probeDutyUsedMs": probeDurationUsedMs,
      ]
    )
    resetProbeFeatures()
  }

  private func emit(
    state: String,
    confidence: Int,
    reason: String,
    supporting: [String] = [],
    conflicting: [String] = [],
    stepDetected: Bool = false,
    sensorProbeUsed: Bool = false,
    extra: [String: Any] = [:]
  ) {
    guard active else { return }
    var event: [String: Any] = [
      "state": state,
      "confidence": min(max(confidence, 0), 100),
      "observedAt": Int64(Date().timeIntervalSince1970 * 1_000),
      "supportingSources": supporting,
      "conflictingSources": conflicting,
      "stepDetected": stepDetected,
      "significantMotionDetected": false,
      "sensorProbeUsed": sensorProbeUsed,
      "policyVersion": 1,
      "reason": reason,
      "generation": generation,
      "pedometerAvailable": CMPedometer.isStepCountingAvailable(),
      "deviceMotionAvailable": motion.isDeviceMotionAvailable,
    ]
    extra.forEach { event[$0.key] = $0.value }
    onDecision(event)
  }

  private func resetProbeFeatures() {
    accelerationSamples = 0
    accelerationSquaredSum = 0
    rotationSamples = 0
    rotationSquaredSum = 0
    stationaryCandidate = false
  }

  private func rms(_ sum: Double, _ count: Int) -> Double {
    count > 0 ? sqrt(sum / Double(count)) : 0
  }
}
