import 'dart:collection';

import 'capability_report.dart';
import 'permission_state.dart';

/// The single next action a host should present before tracking can start.
enum TrackingReadinessAction {
  none,
  requestForegroundLocation,
  explainBackgroundLocation,
  requestBackgroundLocation,
  requestNotification,
  requestActivityRecognition,
  openAppSettings,
  enableLocationServices,
  enablePreciseLocation,
  unsupported,
  unknown,
}

/// One readiness issue found during a non-prompting preflight check.
final class TrackingReadinessIssue {
  const TrackingReadinessIssue({
    required this.code,
    required this.action,
    required this.blocking,
    this.message,
  });

  final String code;
  final TrackingReadinessAction action;
  final bool blocking;
  final String? message;
}

/// Permission/capability readiness snapshot for background tracking.
final class TrackingReadiness {
  TrackingReadiness({
    required this.revision,
    required this.permissions,
    required this.capabilities,
    required Iterable<TrackingReadinessIssue> issues,
    required this.nextAction,
    this.rawNextActionCode,
  }) : issues = UnmodifiableListView<TrackingReadinessIssue>(
          List<TrackingReadinessIssue>.of(issues),
        );

  final int revision;
  final TrackingPermissionState permissions;
  final TrackingCapabilityReport capabilities;
  final UnmodifiableListView<TrackingReadinessIssue> issues;
  final TrackingReadinessAction nextAction;
  final String? rawNextActionCode;

  bool get canStart => issues.every((issue) => !issue.blocking);
}
