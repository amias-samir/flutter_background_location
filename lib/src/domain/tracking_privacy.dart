import 'dart:collection';

import 'track.dart';

final class AbortTrackRequest {
  const AbortTrackRequest({
    this.reason = 'cancelled_by_host',
    this.operationId,
  });

  final String reason;
  final String? operationId;
}

final class DeleteTrackRequest {
  const DeleteTrackRequest({
    required this.trackId,
    this.deleteManagedExports = false,
    this.confirmed = false,
    this.operationId,
  });

  final String trackId;
  final bool deleteManagedExports;
  final bool confirmed;
  final String? operationId;
}

final class EraseTrackRequest {
  const EraseTrackRequest({
    required this.trackId,
    this.confirmed = false,
    this.operationId,
  });

  final String trackId;
  final bool confirmed;
  final String? operationId;
}

abstract final class TrackArtifactKinds {
  static const canonicalRoute = 'canonical_route';
  static const nativeJournal = 'native_journal';
  static const uploadOutbox = 'upload_outbox';
  static const managedExport = 'managed_export';
  static const externalCopies = 'external_copies';
}

abstract final class TrackArtifactActionStatuses {
  static const removed = 'removed';
  static const retained = 'retained';
  static const notFound = 'not_found';
  static const failed = 'failed';
  static const unmanaged = 'unmanaged';
}

abstract final class TrackPrivacyOperationTypes {
  static const abort = 'abort';
  static const delete = 'delete';
  static const erase = 'erase';
}

abstract final class TrackPrivacyOperationStages {
  static const preflight = 'preflight';
  static const stopAndFence = 'stop_and_fence';
  static const nativeClear = 'native_clear';
  static const artifactCleanup = 'artifact_cleanup';
  static const canonicalDelete = 'canonical_delete';
  static const completed = 'completed';
  static const failed = 'failed';
}

final class TrackPrivacyOperationRecord {
  const TrackPrivacyOperationRecord({
    required this.id,
    required this.operationType,
    required this.stage,
    required this.irreversibleCommitted,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.trackId,
    this.terminalReasonCode,
    this.completedAt,
  });

  final String id;
  final String? trackId;
  final String operationType;
  final String stage;
  final bool irreversibleCommitted;
  final String status;
  final String? terminalReasonCode;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
}

final class TrackArtifactActionResult {
  const TrackArtifactActionResult({
    required this.artifact,
    required this.status,
    this.code,
  });

  final String artifact;
  final String status;
  final String? code;
}

sealed class TrackPrivacyReport {
  TrackPrivacyReport({
    required this.operationId,
    required this.status,
    required Iterable<TrackArtifactActionResult> artifacts,
  }) : artifacts = UnmodifiableListView<TrackArtifactActionResult>(
          List<TrackArtifactActionResult>.of(artifacts),
        );

  final String operationId;
  final String status;
  final List<TrackArtifactActionResult> artifacts;
}

final class TrackTerminalActionReport extends TrackPrivacyReport {
  TrackTerminalActionReport({
    required super.operationId,
    required super.status,
    required super.artifacts,
  });
}

final class TrackDeletionReport extends TrackPrivacyReport {
  TrackDeletionReport({
    required super.operationId,
    required super.status,
    required super.artifacts,
  });
}

final class TrackErasureReport extends TrackPrivacyReport {
  TrackErasureReport({
    required super.operationId,
    required super.status,
    required super.artifacts,
  });
}

final class TrackingPrivacyActions {
  const TrackingPrivacyActions({
    required this.canAbortCurrent,
    required this.canDeleteSelected,
    required this.canEraseSelected,
  });

  final bool canAbortCurrent;
  final bool canDeleteSelected;
  final bool canEraseSelected;
}

abstract interface class TrackingPrivacyController {
  TrackingPrivacyActions privacyActionsFor(Track? selectedTrack);

  Future<TrackTerminalActionReport> abortCurrentTrack(
    AbortTrackRequest request,
  );

  Future<TrackDeletionReport> deleteRecordedTrack(DeleteTrackRequest request);

  Future<TrackErasureReport> eraseTrackEverywhere(EraseTrackRequest request);
}
