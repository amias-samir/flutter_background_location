import 'dart:collection';

import 'native_tracking_protocol.dart';
import 'permission_state.dart';
import 'tracker_status.dart';
import 'tracking_readiness.dart';
import 'tracking_settings.dart';

enum TrackingFixState { idle, acquiringFix, healthy, firstFixTimedOut, stale }

/// A stable, coordinate-free diagnostic finding.
final class TrackingHealthIssue {
  const TrackingHealthIssue({
    required this.code,
    required this.blocking,
    this.message,
  });

  final String code;
  final bool blocking;
  final String? message;
}

/// Coordinate-free status for every durable tracking pipeline boundary.
final class TrackingHealthSnapshot {
  TrackingHealthSnapshot({
    required this.observedAt,
    required this.status,
    required this.readiness,
    required this.nativeProtocol,
    this.nativeServiceState = 'unknown',
    this.providerState = 'unknown',
    this.fixState = TrackingFixState.idle,
    this.lastNativeFixAt,
    this.lastJournaledAt,
    this.lastCommittedAt,
    this.lastAcceptedAt,
    this.pendingNativeEvents,
    this.pendingNativeBytes,
    Iterable<TrackingHealthIssue> issues = const <TrackingHealthIssue>[],
  }) : issues = UnmodifiableListView<TrackingHealthIssue>(
          List<TrackingHealthIssue>.of(issues),
        );

  final DateTime observedAt;
  final TrackerStatus status;
  final TrackingReadiness readiness;
  final NativeTrackingProtocol nativeProtocol;
  final String nativeServiceState;
  final String providerState;
  final TrackingFixState fixState;
  final DateTime? lastNativeFixAt;
  final DateTime? lastJournaledAt;
  final DateTime? lastCommittedAt;
  final DateTime? lastAcceptedAt;
  final int? pendingNativeEvents;
  final int? pendingNativeBytes;
  final UnmodifiableListView<TrackingHealthIssue> issues;

  bool get canStart => readiness.canStart;
  bool get hasActiveNativeTrack =>
      status.lifecycle == TrackerLifecycle.tracking ||
      status.lifecycle == TrackerLifecycle.starting;
  bool get healthy => issues.every((issue) => !issue.blocking);

  /// Redacted transport data suitable for support diagnostics.
  Map<String, Object?> toRedactedMap() => <String, Object?>{
        'observedAt': observedAt.toIso8601String(),
        'lifecycle': status.lifecycle.name,
        'nativeServiceState': nativeServiceState,
        'providerState': providerState,
        'fixState': fixState.name,
        'lastNativeFixAt': lastNativeFixAt?.toIso8601String(),
        'lastJournaledAt': lastJournaledAt?.toIso8601String(),
        'lastCommittedAt': lastCommittedAt?.toIso8601String(),
        'lastAcceptedAt': lastAcceptedAt?.toIso8601String(),
        'pendingNativeEvents': pendingNativeEvents,
        'pendingNativeBytes': pendingNativeBytes,
        'issues': issues
            .map((issue) => <String, Object?>{
                  'code': issue.code,
                  'blocking': issue.blocking,
                })
            .toList(growable: false),
      };
}

enum TrackingDoctorFindingSeverity { information, warning, error }

final class TrackingDoctorFinding {
  const TrackingDoctorFinding({
    required this.code,
    required this.severity,
    required this.applicable,
    required this.passed,
    this.troubleshootingAnchor,
  });

  final String code;
  final TrackingDoctorFindingSeverity severity;
  final bool applicable;
  final bool passed;
  final String? troubleshootingAnchor;
}

final class TrackingDoctorReport {
  TrackingDoctorReport({
    required this.observedAt,
    required Iterable<TrackingDoctorFinding> findings,
  }) : findings = UnmodifiableListView<TrackingDoctorFinding>(
          List<TrackingDoctorFinding>.of(findings),
        );

  final DateTime observedAt;
  final UnmodifiableListView<TrackingDoctorFinding> findings;
  bool get passed =>
      findings.where((finding) => finding.applicable).every((finding) =>
          finding.passed ||
          finding.severity != TrackingDoctorFindingSeverity.error);
}

/// Sanitized support data with no route/owner IDs, coordinates, filenames,
/// command tokens, or raw native exception details.
final class TrackingSupportReport {
  TrackingSupportReport({
    required this.createdAt,
    required this.protocolVersion,
    required Iterable<String> capabilities,
    required this.health,
    required this.batteryOptimization,
  }) : capabilities = UnmodifiableListView<String>(
          List<String>.of(capabilities)..sort(),
        );

  final DateTime createdAt;
  final int protocolVersion;
  final UnmodifiableListView<String> capabilities;
  final TrackingHealthSnapshot health;
  final BatteryOptimizationState batteryOptimization;

  Map<String, Object?> toRedactedMap() => <String, Object?>{
        'createdAt': createdAt.toIso8601String(),
        'protocolVersion': protocolVersion,
        'capabilities': capabilities,
        'health': health.toRedactedMap(),
        'batteryOptimization': <String, Object?>{
          'supported': batteryOptimization.supported,
          'ignoringOptimizations':
              batteryOptimization.isIgnoringBatteryOptimizations,
        },
      };
}

/// Additive diagnostics capability implemented by the owner-bound facade.
abstract interface class TrackingDiagnosticsController {
  TrackingHealthSnapshot get currentHealth;
  Stream<TrackingHealthSnapshot> get healthStream;
  Future<TrackingDoctorReport> runSetupDoctor();
  Future<TrackingSupportReport> createSupportReport();
  Future<BatteryOptimizationState> batteryOptimizationState();
}

/// Optional raw native state capability used to build typed health snapshots.
abstract interface class NativeTrackingHealthAdapter {
  Future<Map<String, Object?>> nativeHealthState();
}

DateTime? trackingHealthDate(Object? value) {
  if (value is num) {
    return DateTime.fromMillisecondsSinceEpoch(value.toInt(), isUtc: true);
  }
  if (value is String) return DateTime.tryParse(value)?.toUtc();
  return null;
}

String providerStateForPermission(TrackingPermissionState permission) {
  if (!permission.locationServiceEnabled) return 'disabled';
  if (permission.location == LocationPermissionLevel.denied ||
      permission.location == LocationPermissionLevel.deniedForever) {
    return 'unauthorized';
  }
  if (!permission.preciseLocation) return 'reduced_accuracy';
  return 'available';
}
