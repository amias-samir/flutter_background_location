import Foundation

final class NativeCommandCoordinator {
  static let shared = NativeCommandCoordinator()

  struct Lease {
    let engineId: String
    let engineLeaseToken: String
    let trackId: String
    let sessionControlToken: String
  }

  struct Permit {
    let commandId: String
    let sessionControlToken: String
    let revision: Int64
    let replayed: Bool
  }

  struct Rejection: Error {
    let code: String
    let message: String
  }

  private var lease: Lease?
  private var pendingCommandId: String?

  var hasLease: Bool { lease != nil }

  func acquire(
    service: BackgroundLocationService,
    engineId: String,
    trackId: String,
    sessionControlToken: String
  ) throws -> Lease {
    guard !trackId.isEmpty, !sessionControlToken.isEmpty else {
      throw Rejection(code: "native_command_lease_invalid", message: "Lease identity is incomplete.")
    }
    if let activeTrack = service.nativeCommandTrackId,
      activeTrack != trackId,
      !service.nativeCommandLifecycleIsIdle
    {
      throw Rejection(
        code: "native_command_lease_conflict",
        message: "Another native tracking session owns lifecycle commands."
      )
    }
    if let durableToken = service.nativeSessionControlToken,
      durableToken != sessionControlToken,
      !service.nativeCommandLifecycleIsIdle
    {
      throw Rejection(
        code: "native_command_lease_conflict",
        message: "The durable native session does not match this command session."
      )
    }
    if let lease {
      guard lease.engineId == engineId,
        lease.trackId == trackId,
        lease.sessionControlToken == sessionControlToken
      else {
        throw Rejection(
          code: "native_command_lease_conflict",
          message: "Another Flutter engine currently owns lifecycle commands."
        )
      }
      return lease
    }
    try service.claimNativeSessionControl(sessionControlToken)
    let acquired = Lease(
      engineId: engineId,
      engineLeaseToken: UUID().uuidString,
      trackId: trackId,
      sessionControlToken: sessionControlToken
    )
    lease = acquired
    return acquired
  }

  func begin(
    service: BackgroundLocationService,
    engineId: String,
    arguments: [String: Any]
  ) throws -> Permit {
    guard let lease,
      lease.engineId == engineId,
      lease.engineLeaseToken == arguments["engineLeaseToken"] as? String,
      lease.sessionControlToken == arguments["sessionControlToken"] as? String,
      lease.trackId == arguments["trackId"] as? String
    else {
      throw Rejection(
        code: "native_command_lease_conflict",
        message: "The command does not own the current native lease."
      )
    }
    guard let commandId = arguments["commandId"] as? String, !commandId.isEmpty,
      let expected = (arguments["expectedCommandRevision"] as? NSNumber)?.int64Value,
      expected >= 0
    else {
      throw Rejection(code: "native_command_invalid", message: "Command identity is invalid.")
    }
    let revision = service.nativeCommandRevision
    if service.nativeLastCommandId == commandId {
      return Permit(
        commandId: commandId,
        sessionControlToken: lease.sessionControlToken,
        revision: revision,
        replayed: true
      )
    }
    guard expected == revision else {
      throw Rejection(
        code: "native_command_revision_conflict",
        message: "The lifecycle command was based on a stale native revision."
      )
    }
    guard pendingCommandId == nil else {
      throw Rejection(
        code: "native_command_in_progress",
        message: "Another native lifecycle command is still being applied."
      )
    }
    pendingCommandId = commandId
    return Permit(
      commandId: commandId,
      sessionControlToken: lease.sessionControlToken,
      revision: revision,
      replayed: false
    )
  }

  func complete(service: BackgroundLocationService, permit: Permit) throws -> Int64 {
    if permit.replayed { return permit.revision }
    guard pendingCommandId == permit.commandId else {
      throw Rejection(code: "native_command_invalid", message: "Command reservation was lost.")
    }
    let next = permit.revision + 1
    try service.recordNativeCommandResult(
      token: permit.sessionControlToken,
      commandId: permit.commandId,
      revision: next
    )
    pendingCommandId = nil
    return next
  }

  func fail(_ permit: Permit) {
    if !permit.replayed, pendingCommandId == permit.commandId { pendingCommandId = nil }
  }

  func release(engineId: String, engineLeaseToken: String?) {
    guard let lease, lease.engineId == engineId else { return }
    if let engineLeaseToken, engineLeaseToken != lease.engineLeaseToken { return }
    self.lease = nil
    pendingCommandId = nil
  }
}
