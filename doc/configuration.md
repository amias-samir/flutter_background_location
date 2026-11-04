# Configuration

Accuracy presets, every `TrackingConfig` option, history retention, battery
behavior and mock-location evidence. Back to the [README](../README.md).

## Retaining track history

The default `keepAll` policy retains every recorded route so it remains
available in track history:

```dart
const TrackingConfiguration(
  recordRetentionPolicy: TrackRecordRetentionPolicy.keepAll,
);
```

Choose `keepLatestOnly` when the product should discard older routes as soon as
a new route starts:

```dart
const TrackingConfiguration(
  recordRetentionPolicy: TrackRecordRetentionPolicy.keepLatestOnly,
);
```

Retention is selected when the client is created. Do not dispose and recreate
the client while native tracking is active.

## Tracking configuration

Use the `accuracy` preset for a complete battery/precision profile. `high` is
the default and now favors dense, navigation-grade route capture:

```dart
const balanced = TrackingConfig(accuracy: TrackingAccuracy.medium);

const customized = TrackingConfig(
  accuracy: TrackingAccuracy.low,
  locationAccuracy: TrackingAccuracy.high,
  movingInterval: Duration(seconds: 20),
  movingDistanceFilterMeters: 10,
);
```

Individual values take precedence over the preset. In `customized`, the native
provider uses high accuracy and the moving interval/filter use the supplied
values, while stationary values still come from the low profile.

| Preset | Moving interval | Moving filter | Native request | Stationary interval | Stationary filter | Accepted accuracy |
|---|---:|---:|---|---:|---:|---:|
| `low` | 20 seconds | 20 m | Balanced / nearest 10 m | 2 minutes | 75 m | 100 m |
| `medium` | 10 seconds | 10 m | High / best | 1 minute | 50 m | 60 m |
| `high` (default) | 5 seconds | 5 m | High / navigation | 20 seconds | 20 m | 20 m |
| `precised` | 3 seconds | 3 m | High / navigation | 15 seconds | 10 m | 15 m |

Android and iOS translate the native request to the closest platform accuracy;
the table shows Android/iOS terminology. Presets are starting points, not
callback guarantees or universal recommendations. The accepted-accuracy column
is the preset's `maximumAcceptedAccuracyMeters`; it is available directly as,
for example, `TrackingAccuracy.high.maximumAcceptedAccuracyMeters`.

| Option | Default | Purpose |
|---|---:|---|
| `accuracy` | `high` | Supplies all preset sampling and accepted-accuracy values |
| `locationAccuracy` | `precised` for the default `high` preset | Overrides only Android/iOS native request accuracy |
| `movingInterval` | 5 seconds | Requested interval while moving |
| `movingDistanceFilterMeters` | 5 m | Minimum moving displacement |
| `stationaryInterval` | 20 seconds | Requested interval while stationary |
| `stationaryDistanceFilterMeters` | 20 m | Minimum stationary displacement |
| `maximumAcceptedAccuracyMeters` | 20 m | Reject fixes with poorer reported accuracy |
| `turnCaptureDegrees` | 45° (High, Precised), off (Medium, Low) | Record a fix between the regular ones when a moving route turns this far |
| `maximumPlausibleSpeedMetersPerSecond` | 70 m/s | Flag implausible point-to-point speed |
| `stationaryConfirmationDuration` | 90 seconds | Still evidence required before low-power mode |
| `stationaryProbeDisplacementMeters` | 30 m | GPS displacement check for stationary entry/exit |
| `stationaryConfidenceThreshold` | 75 | Minimum still confidence |
| `movingConfidenceThreshold` | 60 | Minimum movement confidence |
| `movingConfirmationCount` | 1 | Movement events required to exit stationary mode |
| `activityRecognitionInterval` | 5 seconds | Requested native activity update interval |
| `activityFreshnessThreshold` | 30 seconds | Expire stale activity labels and use the moving fallback |
| `motionEvidenceFreshness` | 30 seconds | Expire stale fused-motion evidence |
| `maximumProviderFixAge` | 5 minutes | Reject genuinely stale provider fixes while retaining delayed background batches |
| `mockLocationPolicy` | `flag` | Allow, flag, or reject detected mock fixes |
| `largeGapThreshold` | 5 minutes | Flag long gaps between accepted fixes |
| `batchPointCount` | 25 | Point threshold for an optional uploader |
| `batchMaxAge` | 2 minutes | Time threshold for an optional uploader |
| `iosTerminationRecoveryMode` | `interrupted` | Standard/manual recovery or opt-in significant-change relaunch semantics |

Operating systems may batch, delay, coalesce, or skip callbacks. Shortening an
interval does not guarantee that frequency. `high` and especially `precised`
can materially increase battery use and should be enabled only when dense route
geometry is necessary. On Android, the host may offer a user-initiated shortcut
to battery-optimization settings, but must not imply that exemption is required
or automatically granted.

## Activity and battery behavior

Native motion APIs report the best available activity class. They do not prove
that the device owner is a driver, passenger, or rider. Cycling is the closest
standard two-wheeler signal; a motorcycle or scooter commonly appears as
`inVehicle`, not `onBicycle`.

The plugin enters the stationary profile only after sustained, confident still
activity plus low GPS displacement. It returns to moving mode after movement
evidence or sufficient displacement. If activity permission or reliable motion
evidence is unavailable, it remains on the moving profile.

Battery results depend on the device, OS version, OEM policy, satellite and
network conditions, route, screen use, and configuration. Measure route
fidelity and battery drain together on the same devices your users carry.

### Bounded adaptive policy

Adaptive changes are disabled unless the host constructs a versioned policy.
The default policy mode is `shadow`: it reports a proposed profile without
changing native capture. Fidelity bounds cap every interval/filter and the
engine always preserves the static configuration's
`maximumAcceptedAccuracyMeters` and `mockLocationPolicy`.

```dart
final engine = AdaptiveBatteryPolicyEngine(
  staticConfig: const TrackingConfig(accuracy: TrackingAccuracy.high),
  policy: const AdaptiveBatteryPolicy(
    version: 1,
    mode: AdaptiveBatteryMode.shadow,
    bounds: AdaptiveFidelityBounds(
      leastAccurateProfile: TrackingAccuracy.medium,
      maximumMovingInterval: Duration(seconds: 30),
      maximumMovingDistanceFilterMeters: 25,
      maximumStationaryInterval: Duration(minutes: 3),
      maximumStationaryDistanceFilterMeters: 100,
    ),
  ),
);
final coordinator = AdaptiveTrackingCoordinator(
  controller: tracking as TrackingConfigurationController,
  engine: engine,
);
final decision = await coordinator.observe(
  AdaptiveBatteryObservation(
    observedAt: DateTime.now(),
    batteryPercent: batteryPercent,
    charging: charging,
    lowPowerMode: lowPowerMode,
  ),
);
print(decision.toRedactedMap());
```

Move to `AdaptiveBatteryMode.apply` only after shadow traces and physical
battery/route benchmarks justify it. Applied transitions use immutable runtime
configuration epochs, minimum residence time, and a maximum transition rate.
`disableAndRestore()` returns to the static policy through the same atomic
epoch path.

## Mock-location interpretation

Every point exposes `mockAssessment`:

- `detected`: the operating system marked this exact fix as mocked or
  simulated;
- `notDetected`: the signal was available and clear for this fix;
- `unavailable`: the signal was unavailable for this fix.

Android uses `Location.isMock` or the legacy mock-provider flag. On iOS 15 and
later, the plugin reads `CLLocation.sourceInformation.isSimulatedBySoftware`.

`notDetected` is evidence, not proof that a coordinate is genuine. Rooted or
jailbroken devices, external accessories, GNSS/RF spoofing, and other methods
may evade platform signals. Do not use this value as the sole fraud or safety
decision.

