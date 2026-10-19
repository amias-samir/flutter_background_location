import '../domain/track_point.dart';

/// Per-point diagnostic fields, exported only when
/// `TrackExportOptions.includeDiagnosticProperties` is set.
///
/// Everything here is coordinate-free evidence the route database already
/// stores: reported accuracies and Doppler speed, the native sampling profile,
/// where the activity reading came from and how old it was, and how late the
/// fix reached native code. Field tests use it to explain a recorded route.
Map<String, Object?> diagnosticPointProperties(TrackPoint point) {
  double? finite(double? value) =>
      value != null && value.isFinite ? value : null;
  final receivedAt = point.nativeReceivedAt;
  return <String, Object?>{
    if (finite(point.verticalAccuracy) case final value?)
      'verticalAccuracy': value,
    if (finite(point.speed) case final value?) 'speed': value,
    if (finite(point.speedAccuracy) case final value?) 'speedAccuracy': value,
    if (finite(point.heading) case final value?) 'heading': value,
    if (finite(point.headingAccuracy) case final value?)
      'headingAccuracy': value,
    if (point.provider case final value?) 'provider': value,
    if (point.samplingProfile case final value?) 'samplingProfile': value.name,
    if (point.activitySource case final value?) 'activitySource': value,
    if (point.activityRawType case final value?) 'activityRawType': value,
    'activityEvidenceState': point.activityEvidenceState.name,
    if (point.activityAge case final value?)
      'activityAgeMs': value.inMilliseconds,
    if (receivedAt != null)
      'receiptDelayMs': receivedAt.difference(point.capturedAt).inMilliseconds,
    if (point.qualityPolicyVersion case final value?)
      'qualityPolicyVersion': value,
  };
}
