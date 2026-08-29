import 'track.dart';
import 'tracking_config.dart';
import 'tracking_readiness.dart';

/// Tenant/application metadata used by explicit start and resume APIs.
final class TrackingOwner {
  const TrackingOwner({
    required this.userId,
    required this.organizationId,
  });

  /// Host-authenticated user identifier stored on new tracks.
  final String userId;

  /// Host-authenticated organization/workspace identifier stored on new tracks.
  final String organizationId;

  /// Whether [track] belongs to this owner metadata.
  bool owns(Track track) =>
      track.userId == userId && track.organizationId == organizationId;
}

/// Explicit request for creating or recovering a route.
final class TrackStartRequest {
  const TrackStartRequest({
    required this.owner,
    this.routeId,
    this.requestedTrackId,
    this.config,
  });

  /// Owner metadata for the route operation.
  final TrackingOwner owner;

  /// Optional readable route identifier. Whitespace is normalized on creation.
  final String? routeId;

  /// Optional host-supplied internal track ID.
  final String? requestedTrackId;

  /// Optional per-route sampling/validation configuration.
  final TrackingConfig? config;
}

/// How an explicit start/recovery command reached an active route.
enum TrackStartDisposition {
  /// A new database route and native capture were created.
  created,

  /// A same-owner active route was reused.
  reusedActive,

  /// A same-owner paused route was resumed.
  resumedPaused,

  /// A same-owner interrupted route was resumed.
  resumedInterrupted,
}

/// Result returned by explicit start and recovery APIs.
final class TrackStartResult {
  const TrackStartResult({
    required this.track,
    required this.disposition,
    required this.readiness,
  });

  /// The active route after the command.
  final Track track;

  /// Whether the route was created, reused, or resumed.
  final TrackStartDisposition disposition;

  /// Readiness snapshot used before issuing native capture.
  final TrackingReadiness readiness;

  /// Convenience accessor for [Track.id].
  String get trackId => track.id;

  /// Whether this command created a new route.
  bool get created => disposition == TrackStartDisposition.created;
}

/// Explicit host confirmation for resolving a redacted foreign live capture.
final class OwnerConflictResolutionRequest {
  const OwnerConflictResolutionRequest({
    required this.conflictToken,
    required this.operationId,
    required this.confirmed,
  });

  /// Ephemeral opaque token published by the blocked session snapshot.
  final String conflictToken;

  /// Host-generated idempotency key for the durable pause operation.
  final String operationId;

  /// Must be true only after the host has shown a destructive-flow warning.
  final bool confirmed;
}

enum OwnerConflictResolutionDisposition { preservedPaused, alreadyResolved }

final class OwnerConflictResolutionResult {
  const OwnerConflictResolutionResult({required this.disposition});

  final OwnerConflictResolutionDisposition disposition;
  bool get resolved => true;
}
