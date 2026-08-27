import 'package:uuid/uuid.dart';

import '../domain/export_models.dart';
import '../domain/track.dart';
import '../domain/tracking_error.dart';
import '../domain/tracking_privacy.dart';
import '../domain/tracking_start.dart';
import '../platform/tracker_adapter.dart';
import '../storage/track_repository.dart';

/// Owner-bound implementation of additive Abort/Delete/Erase semantics.
///
/// This service coordinates the default canonical repository, native journal,
/// upload outbox, and package-managed exports. Physical secure deletion from
/// flash storage and copies made by other applications cannot be guaranteed.
final class TrackingPrivacyService implements TrackingPrivacyController {
  TrackingPrivacyService({
    required this.repository,
    required this.tracker,
    required this.owner,
    this.managedExports,
    String Function()? operationIdGenerator,
  }) : _operationIdGenerator =
            operationIdGenerator ?? (() => const Uuid().v4());

  final TrackRepository repository;
  final TrackerAdapter tracker;
  final TrackingOwner owner;
  final TrackingManagedExportController? managedExports;
  final String Function() _operationIdGenerator;

  OwnerScopedTrackRepository get _ownerStore {
    final store = repository;
    if (store is OwnerScopedTrackRepository) {
      return store as OwnerScopedTrackRepository;
    }
    throw const TrackingStorageException(
      code: 'capability_unsupported',
      message: 'This repository does not support owner-scoped privacy actions.',
    );
  }

  PrivacyTrackRepository get _privacyStore {
    final store = repository;
    if (store is PrivacyTrackRepository) {
      return store as PrivacyTrackRepository;
    }
    throw const TrackingStorageException(
      code: 'capability_unsupported',
      message: 'This repository does not support durable privacy operations.',
    );
  }

  @override
  TrackingPrivacyActions privacyActionsFor(Track? selectedTrack) {
    final selectedOwned = selectedTrack != null && owner.owns(selectedTrack);
    return TrackingPrivacyActions(
      canAbortCurrent: selectedOwned && !selectedTrack.isTerminal,
      canDeleteSelected: selectedOwned && selectedTrack.isTerminal,
      canEraseSelected: selectedOwned,
    );
  }

  @override
  Future<TrackTerminalActionReport> abortCurrentTrack(
    AbortTrackRequest request,
  ) async {
    final replayId = request.operationId;
    if (replayId != null) {
      final replay = await _privacyStore.getPrivacyOperation(replayId);
      if (replay?.operationType == TrackPrivacyOperationTypes.abort &&
          replay?.status == 'completed') {
        return _abortReport(replayId, nativeStatus: 'removed');
      }
    }
    final track = await _ownerStore.findActiveTrackForOwner(owner) ??
        await _ownerStore.findLatestPausedTrackForOwner(owner);
    if (track == null) {
      throw const TrackingConflictException(
        code: 'no_abortable_track',
        message: 'There is no current route to abort.',
      );
    }
    if (track.isTerminal) {
      throw TrackingConflictException(
        code: 'track_not_abortable',
        message: 'The selected route is already terminal.',
        trackId: track.id,
      );
    }
    final operation = await _privacyStore.beginPrivacyOperation(
      owner: owner,
      trackId: track.id,
      operationType: TrackPrivacyOperationTypes.abort,
      operationId: request.operationId ?? _operationIdGenerator(),
    );
    if (operation.status == 'completed') {
      return _abortReport(operation.id, nativeStatus: 'removed');
    }

    await _stopAndFence(track, reason: request.reason);
    await _privacyStore.abortTrackForOwner(
      owner: owner,
      trackId: track.id,
      reason: request.reason,
      operationId: operation.id,
    );
    final nativeStatus = await _clearNativeTrack(track.id);
    if (nativeStatus != TrackArtifactActionStatuses.removed) {
      await _privacyStore.updatePrivacyOperation(
        operationId: operation.id,
        stage: TrackPrivacyOperationStages.nativeClear,
        status: 'partial',
        terminalReasonCode: 'cancelled_by_host',
      );
    }
    return _abortReport(operation.id, nativeStatus: nativeStatus);
  }

  TrackTerminalActionReport _abortReport(
    String operationId, {
    required String nativeStatus,
  }) =>
      TrackTerminalActionReport(
        operationId: operationId,
        status: nativeStatus == TrackArtifactActionStatuses.removed
            ? 'completed'
            : 'partial',
        artifacts: <TrackArtifactActionResult>[
          const TrackArtifactActionResult(
            artifact: TrackArtifactKinds.canonicalRoute,
            status: TrackArtifactActionStatuses.retained,
            code: 'cancelled_by_host',
          ),
          TrackArtifactActionResult(
            artifact: TrackArtifactKinds.nativeJournal,
            status: nativeStatus,
          ),
          const TrackArtifactActionResult(
            artifact: TrackArtifactKinds.uploadOutbox,
            status: TrackArtifactActionStatuses.removed,
          ),
          const TrackArtifactActionResult(
            artifact: TrackArtifactKinds.managedExport,
            status: TrackArtifactActionStatuses.retained,
          ),
        ],
      );

  @override
  Future<TrackDeletionReport> deleteRecordedTrack(
    DeleteTrackRequest request,
  ) async {
    if (!request.confirmed) {
      throw const TrackingConflictException(
        code: 'destructive_action_not_confirmed',
        message: 'Recorded-route deletion requires explicit confirmation.',
      );
    }
    final replayId = request.operationId;
    if (replayId != null) {
      final replay = await _privacyStore.getPrivacyOperation(replayId);
      if (replay?.operationType == TrackPrivacyOperationTypes.delete &&
          replay?.status == 'completed') {
        return TrackDeletionReport(
          operationId: replayId,
          status: 'completed',
          artifacts: _deletionArtifacts(
            nativeStatus: TrackArtifactActionStatuses.removed,
            exportCount: 0,
            deleteExports: request.deleteManagedExports,
          ),
        );
      }
    }
    final track = await _requiredOwnedTrack(request.trackId);
    if (!track.isTerminal) {
      throw TrackingConflictException(
        code: 'track_not_deletable',
        message: 'Only a terminal route can be deleted.',
        trackId: track.id,
      );
    }
    final operation = await _privacyStore.beginPrivacyOperation(
      owner: owner,
      trackId: track.id,
      operationType: TrackPrivacyOperationTypes.delete,
      operationId: request.operationId ?? _operationIdGenerator(),
    );
    final exportResults = await _prepareManagedExportCleanup(
      track.id,
      delete: request.deleteManagedExports,
    );
    await _privacyStore.updatePrivacyOperation(
      operationId: operation.id,
      stage: TrackPrivacyOperationStages.nativeClear,
      irreversibleCommitted: true,
    );
    final nativeStatus = await _clearNativeTrack(track.id);
    if (nativeStatus == TrackArtifactActionStatuses.failed) {
      throw const TrackingNativeException(
        code: 'native_clear_failed',
        message: 'Native route evidence could not be cleared.',
      );
    }
    await _deleteManagedExports(exportResults);
    await _privacyStore.deleteRecordedTrackForOwner(
      owner: owner,
      trackId: track.id,
      operationId: operation.id,
    );
    return TrackDeletionReport(
      operationId: operation.id,
      status: 'completed',
      artifacts: _deletionArtifacts(
        nativeStatus: nativeStatus,
        exportCount: exportResults.length,
        deleteExports: request.deleteManagedExports,
      ),
    );
  }

  @override
  Future<TrackErasureReport> eraseTrackEverywhere(
    EraseTrackRequest request,
  ) async {
    if (!request.confirmed) {
      throw const TrackingConflictException(
        code: 'destructive_action_not_confirmed',
        message: 'Route erasure requires explicit confirmation.',
      );
    }
    final replayId = request.operationId;
    if (replayId != null) {
      final replay = await _privacyStore.getPrivacyOperation(replayId);
      if (replay?.operationType == TrackPrivacyOperationTypes.erase &&
          replay?.status == 'completed') {
        return TrackErasureReport(
          operationId: replayId,
          status: 'completed',
          artifacts: const <TrackArtifactActionResult>[
            TrackArtifactActionResult(
              artifact: TrackArtifactKinds.canonicalRoute,
              status: TrackArtifactActionStatuses.removed,
            ),
            TrackArtifactActionResult(
              artifact: TrackArtifactKinds.externalCopies,
              status: TrackArtifactActionStatuses.unmanaged,
            ),
          ],
        );
      }
    }
    final track = await _requiredOwnedTrack(request.trackId);
    final operation = await _privacyStore.beginPrivacyOperation(
      owner: owner,
      trackId: track.id,
      operationType: TrackPrivacyOperationTypes.erase,
      operationId: request.operationId ?? _operationIdGenerator(),
    );
    await _stopAndFence(track, reason: 'erased_by_host');
    final exportResults = await _prepareManagedExportCleanup(
      track.id,
      delete: true,
    );
    await _privacyStore.updatePrivacyOperation(
      operationId: operation.id,
      stage: TrackPrivacyOperationStages.nativeClear,
      irreversibleCommitted: true,
    );
    final nativeStatus = await _clearNativeTrack(track.id);
    if (nativeStatus == TrackArtifactActionStatuses.failed) {
      throw const TrackingNativeException(
        code: 'native_clear_failed',
        message: 'Native route evidence could not be cleared.',
      );
    }
    await _deleteManagedExports(exportResults);
    await _privacyStore.eraseTrackForOwner(
      owner: owner,
      trackId: track.id,
      operationId: operation.id,
    );
    return TrackErasureReport(
      operationId: operation.id,
      status: 'completed',
      artifacts: <TrackArtifactActionResult>[
        const TrackArtifactActionResult(
          artifact: TrackArtifactKinds.canonicalRoute,
          status: TrackArtifactActionStatuses.removed,
        ),
        TrackArtifactActionResult(
          artifact: TrackArtifactKinds.nativeJournal,
          status: nativeStatus,
        ),
        const TrackArtifactActionResult(
          artifact: TrackArtifactKinds.uploadOutbox,
          status: TrackArtifactActionStatuses.removed,
        ),
        TrackArtifactActionResult(
          artifact: TrackArtifactKinds.managedExport,
          status: TrackArtifactActionStatuses.removed,
          code: 'count_${exportResults.length}',
        ),
        const TrackArtifactActionResult(
          artifact: TrackArtifactKinds.externalCopies,
          status: TrackArtifactActionStatuses.unmanaged,
        ),
      ],
    );
  }

  Future<Track> _requiredOwnedTrack(String trackId) async {
    final track = await _ownerStore.getTrackForOwner(owner, trackId);
    if (track == null) {
      throw const TrackingOwnershipException(
        code: 'track_not_found_in_owner_scope',
        message: 'The route is not available in the current owner scope.',
      );
    }
    return track;
  }

  Future<void> _stopAndFence(Track track, {required String reason}) async {
    final runtime = await tracker.runtimeState();
    if (runtime.trackId != null && runtime.trackId != track.id) {
      throw const TrackingOwnershipException(
        code: 'native_owner_conflict',
        message: 'Native capture belongs to another hidden route.',
      );
    }
    await tracker.stop(trackId: track.id, reason: reason);
  }

  Future<String> _clearNativeTrack(String trackId) async {
    final adapter = tracker;
    if (adapter is! TrackScopedNativeDataAdapter) {
      return TrackArtifactActionStatuses.failed;
    }
    try {
      await (adapter as TrackScopedNativeDataAdapter)
          .clearNativeTrackData(trackId);
      return TrackArtifactActionStatuses.removed;
    } on Object {
      return TrackArtifactActionStatuses.failed;
    }
  }

  Future<List<ManagedTrackExport>> _prepareManagedExportCleanup(
    String trackId, {
    required bool delete,
  }) async {
    final controller = managedExports;
    final List<ManagedTrackExport> exports;
    if (controller != null) {
      exports = (await controller.listManagedExports(trackId))
          .where((item) => item.state == 'committed')
          .toList(growable: false);
    } else if (repository is ManagedExportRepository) {
      final records = await (repository as ManagedExportRepository)
          .listManagedExports(owner: owner, trackId: trackId);
      exports = records
          .where((item) => item.state == ManagedExportState.committed)
          .map(
            (item) => ManagedTrackExport(
              id: item.id,
              trackId: item.trackId,
              format: item.format,
              state: item.state.name,
              destination: item.destination,
              createdAt: item.createdAt,
              deletedAt: item.deletedAt,
            ),
          )
          .toList(growable: false);
    } else {
      throw const TrackingStorageException(
        code: 'capability_unsupported',
        message: 'Managed export inventory is required for safe deletion.',
      );
    }
    if (exports.isNotEmpty && !delete) {
      throw const TrackingConflictException(
        code: 'managed_exports_require_explicit_cleanup',
        message:
            'This route has managed exports; choose whether to delete them.',
      );
    }
    if (exports.isNotEmpty && delete && controller == null) {
      throw const TrackingStorageException(
        code: 'capability_unsupported',
        message: 'Managed export artifact cleanup is not configured.',
      );
    }
    return exports;
  }

  Future<void> _deleteManagedExports(List<ManagedTrackExport> exports) async {
    final controller = managedExports;
    for (final export in exports) {
      await controller!.deleteManagedExport(export.id);
    }
  }

  static List<TrackArtifactActionResult> _deletionArtifacts({
    required String nativeStatus,
    required int exportCount,
    required bool deleteExports,
  }) =>
      <TrackArtifactActionResult>[
        const TrackArtifactActionResult(
          artifact: TrackArtifactKinds.canonicalRoute,
          status: TrackArtifactActionStatuses.removed,
        ),
        TrackArtifactActionResult(
          artifact: TrackArtifactKinds.nativeJournal,
          status: nativeStatus,
        ),
        const TrackArtifactActionResult(
          artifact: TrackArtifactKinds.uploadOutbox,
          status: TrackArtifactActionStatuses.removed,
        ),
        TrackArtifactActionResult(
          artifact: TrackArtifactKinds.managedExport,
          status: deleteExports
              ? TrackArtifactActionStatuses.removed
              : TrackArtifactActionStatuses.retained,
          code: 'count_$exportCount',
        ),
      ];
}
