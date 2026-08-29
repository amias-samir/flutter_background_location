/// Settings screens that the package can ask the operating system to open.
enum TrackingSettingsDestination {
  application,
  locationServices,
  batteryOptimization,
}

/// Result of asking the operating system to open a settings screen.
final class TrackingSettingsResult {
  const TrackingSettingsResult({
    required this.destination,
    required this.supported,
    required this.opened,
    this.message,
  });

  final TrackingSettingsDestination destination;
  final bool supported;
  final bool opened;
  final String? message;
}

/// Android battery-optimization state, or an unsupported result elsewhere.
final class BatteryOptimizationState {
  const BatteryOptimizationState({
    required this.supported,
    required this.isIgnoringBatteryOptimizations,
    this.packageName,
  });

  const BatteryOptimizationState.unsupported()
      : supported = false,
        isIgnoringBatteryOptimizations = true,
        packageName = null;

  final bool supported;
  final bool isIgnoringBatteryOptimizations;
  final String? packageName;

  factory BatteryOptimizationState.fromMap(Map<Object?, Object?> map) =>
      BatteryOptimizationState(
        supported: map['supported'] == true,
        isIgnoringBatteryOptimizations:
            map['isIgnoringBatteryOptimizations'] != false,
        packageName: map['packageName'] as String?,
      );
}
