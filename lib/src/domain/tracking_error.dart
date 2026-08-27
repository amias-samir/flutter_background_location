/// A stable recovery action code attached to package exceptions.
final class TrackingRecoveryAction {
  const TrackingRecoveryAction(this.code);

  /// Stable snake_case action identifier.
  final String code;

  @override
  String toString() => code;
}

/// Common recovery actions used by package exceptions.
abstract final class TrackingRecoveryActions {
  static const refresh = TrackingRecoveryAction('refresh');
  static const retry = TrackingRecoveryAction('retry');
  static const resume = TrackingRecoveryAction('resume');
  static const complete = TrackingRecoveryAction('complete');
  static const openSettings = TrackingRecoveryAction('open_settings');
  static const resolveOwnerCapture =
      TrackingRecoveryAction('resolve_owner_capture');
}

/// Base package exception with a stable, machine-readable code.
///
/// The [message] is safe for developer display but is not a localized end-user
/// string. Package code must not put coordinates, route bodies, or owner
/// identifiers in this envelope.
class TrackingException implements Exception {
  const TrackingException({
    required this.code,
    required this.message,
    this.recoveryAction,
    this.trackId,
    this.cause,
  });

  /// Stable snake_case failure identifier.
  final String code;

  /// Developer-facing sanitized message.
  final String message;

  /// Suggested host recovery action, when one is known.
  final TrackingRecoveryAction? recoveryAction;

  /// Verified same-scope track ID, when safe to reveal.
  final String? trackId;

  /// Sanitized debugging cause.
  final Object? cause;

  @override
  String toString() => 'TrackingException($code, $message)';
}

/// Invalid package or per-route tracking configuration.
final class TrackingConfigurationException extends TrackingException {
  const TrackingConfigurationException({
    required super.code,
    required super.message,
    super.recoveryAction = TrackingRecoveryActions.refresh,
    super.cause,
  });
}

/// A tracking command cannot proceed until readiness issues are resolved.
final class TrackingNotReadyException extends TrackingException {
  const TrackingNotReadyException({
    required super.code,
    required super.message,
    super.recoveryAction = TrackingRecoveryActions.refresh,
    super.trackId,
    super.cause,
  });
}

/// A lifecycle command conflicts with an existing same-owner route.
final class TrackingConflictException extends TrackingException {
  const TrackingConflictException({
    required super.code,
    required super.message,
    super.recoveryAction = TrackingRecoveryActions.resume,
    super.trackId,
    super.cause,
  });
}

/// A lifecycle command would cross a host owner/account boundary.
final class TrackingOwnershipException extends TrackingException {
  const TrackingOwnershipException({
    required super.code,
    required super.message,
    super.recoveryAction = TrackingRecoveryActions.resolveOwnerCapture,
    super.cause,
  });
}

/// A native permission step may have partially reached the OS prompt.
final class TrackingPermissionStepException extends TrackingException {
  const TrackingPermissionStepException({
    required super.code,
    required super.message,
    required this.permissionMayHaveChanged,
    super.recoveryAction = TrackingRecoveryActions.refresh,
    super.cause,
  });

  final bool permissionMayHaveChanged;
}

/// A native platform operation failed or is not available.
final class TrackingNativeException extends TrackingException {
  const TrackingNativeException({
    required super.code,
    required super.message,
    super.recoveryAction = TrackingRecoveryActions.retry,
    super.trackId,
    super.cause,
  });
}

/// Canonical route storage or bounded-read operation failed.
final class TrackingStorageException extends TrackingException {
  const TrackingStorageException({
    required super.code,
    required super.message,
    super.recoveryAction = TrackingRecoveryActions.retry,
    super.trackId,
    super.cause,
  });
}

/// A route export, destination, or share preparation operation failed.
final class TrackingExportException extends TrackingException {
  const TrackingExportException({
    required super.code,
    required super.message,
    super.recoveryAction = TrackingRecoveryActions.retry,
    super.trackId,
    super.cause,
  });
}
