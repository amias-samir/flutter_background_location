import Foundation
import SQLite3

enum NativeLocationJournalError: LocalizedError {
  case fileSystem(String)
  case database(operation: String, code: Int32, message: String)
  case capacity(current: Int, maximum: Int)
  case invalidEvent(String)
  case corruptEvent(String)
  case invalidCursor

  var errorDescription: String? {
    switch self {
    case .fileSystem(let message):
      return "Location journal file-system error: \(message)"
    case .database(let operation, let code, let message):
      return "Location journal \(operation) failed (SQLite \(code)): \(message)"
    case .capacity(let current, let maximum):
      return "Location journal is full (\(current)/\(maximum) pending fixes)."
    case .invalidEvent(let message):
      return "Location journal rejected an invalid event: \(message)"
    case .corruptEvent(let message):
      return "Location journal contains a corrupt event: \(message)"
    case .invalidCursor:
      return "The native location-journal cursor is invalid."
    }
  }

  var isCapacityFailure: Bool {
    if case .capacity = self { return true }
    return false
  }
}

struct NativeLocationJournalAcknowledgement {
  let deleted: Int
  let remaining: Int
}

struct NativeLocationJournalPage {
  let events: [[String: Any]]
  let nextCursor: String?
  let hasMore: Bool
  let encodedBytes: Int
  let remainingCount: Int

  var map: [String: Any] {
    var values: [String: Any] = [
      "events": events,
      "hasMore": hasMore,
      "encodedBytes": encodedBytes,
      "remainingCount": remainingCount,
    ]
    if let nextCursor {
      values["nextCursor"] = nextCursor
    }
    return values
  }
}

/// Serializes all SQLite journal work away from the Core Location/main thread.
final class NativeLocationJournalQueue {
  private let journal: NativeLocationJournal
  private let queue: DispatchQueue
  private let callbackQueue: DispatchQueue

  init(
    journal: NativeLocationJournal,
    callbackQueue: DispatchQueue = .main
  ) {
    self.journal = journal
    self.callbackQueue = callbackQueue
    queue = DispatchQueue(
      label: "com.samir.flutter_background_location.native_location_journal",
      qos: .utility
    )
  }

  func prepare(completion: @escaping (Result<Int, Error>) -> Void) {
    execute(completion: completion) {
      try self.journal.prepare()
    }
  }

  func ensureCapacityForCapture(completion: @escaping (Result<Int, Error>) -> Void) {
    execute(completion: completion) {
      try self.journal.ensureCapacityForCapture()
    }
  }

  func append(
    _ event: [String: Any],
    completion: @escaping (Result<Int, Error>) -> Void
  ) {
    execute(completion: completion) {
      try self.journal.append(event)
    }
  }

  func pendingLocations(completion: @escaping (Result<[[String: Any]], Error>) -> Void) {
    execute(completion: completion) {
      try self.journal.pendingLocations()
    }
  }

  func pendingLocationPage(
    cursor: String?,
    maxRecords: Int,
    maxEncodedBytes: Int,
    completion: @escaping (Result<NativeLocationJournalPage, Error>) -> Void
  ) {
    execute(completion: completion) {
      try self.journal.pendingLocationPage(
        cursor: cursor,
        maxRecords: maxRecords,
        maxEncodedBytes: maxEncodedBytes
      )
    }
  }

  func diagnostic(
    performMaintenance: Bool,
    completion: @escaping ([String: Any]) -> Void
  ) {
    queue.async { [callbackQueue] in
      let diagnostic: [String: Any]
      do {
        diagnostic = try self.journal.diagnostic(
          performMaintenance: performMaintenance
        )
      } catch {
        diagnostic = NativeLocationJournal.failureDiagnostic(error)
      }
      callbackQueue.async {
        completion(diagnostic)
      }
    }
  }

  func acknowledge(
    eventIds: [String],
    completion: @escaping (Result<NativeLocationJournalAcknowledgement, Error>) -> Void
  ) {
    execute(completion: completion) {
      try self.journal.acknowledge(eventIds: eventIds)
    }
  }

  func deleteTrack(
    trackId: String,
    completion: @escaping (Result<Int, Error>) -> Void
  ) {
    execute(completion: completion) {
      try self.journal.deleteTrack(trackId: trackId)
    }
  }

  /// Runs after all journal tasks enqueued before the call have completed.
  func fence(completion: @escaping () -> Void) {
    queue.async { [callbackQueue] in
      callbackQueue.async(execute: completion)
    }
  }

  private func execute<T>(
    completion: @escaping (Result<T, Error>) -> Void,
    operation: @escaping () throws -> T
  ) {
    queue.async { [callbackQueue] in
      let result = Result(catching: operation)
      callbackQueue.async {
        completion(result)
      }
    }
  }
}

/// Durable handoff between Core Location and Dart persistence.
///
/// Rows are never aged out or evicted. They leave this database only after
/// Dart explicitly acknowledges their stable event IDs.
final class NativeLocationJournal {
  static let maximumPendingEvents = 25_000

  private static let directoryName = "flutter_background_location"
  private static let databaseName = "pending_locations.sqlite3"
  private static let maximumPayloadBytes = 64 * 1_024
  private static let maximumPageRecords = 250
  // Leaves conservative headroom for StandardMessageCodec map/list keys.
  private static let maximumPageBytes = 900 * 1_024
  private static let requestedPageSize = 4_096
  private static let maximumDatabaseBytes = 64 * 1_024 * 1_024

  private let fileManager: FileManager
  private var database: OpaquePointer?
  private var pendingCount = 0
  private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  static func failureDiagnostic(_ error: Error) -> [String: Any] {
    [
      "platform": "ios",
      "healthy": false,
      "opened": false,
      "databaseName": databaseName,
      "errorType": String(describing: type(of: error)),
      "errorMessage": error.localizedDescription,
    ]
  }

  deinit {
    if let database {
      sqlite3_close_v2(database)
    }
  }

  @discardableResult
  func prepare() throws -> Int {
    if database != nil { return pendingCount }

    let fileURL = try journalFileURL()
    var openedDatabase: OpaquePointer?
    let openCode = sqlite3_open_v2(
      fileURL.path,
      &openedDatabase,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard openCode == SQLITE_OK, let openedDatabase else {
      let message =
        openedDatabase.map { String(cString: sqlite3_errmsg($0)) }
        ?? "Could not open the database."
      if let openedDatabase { sqlite3_close_v2(openedDatabase) }
      throw NativeLocationJournalError.database(
        operation: "open",
        code: openCode,
        message: message
      )
    }

    database = openedDatabase
    do {
      sqlite3_extended_result_codes(openedDatabase, 1)
      let timeoutCode = sqlite3_busy_timeout(openedDatabase, 2_500)
      guard timeoutCode == SQLITE_OK else {
        throw databaseError(operation: "configure busy timeout", code: timeoutCode)
      }

      try execute("PRAGMA page_size = \(Self.requestedPageSize)")
      try execute("PRAGMA auto_vacuum = INCREMENTAL")
      try execute("PRAGMA journal_mode = TRUNCATE")
      try execute("PRAGMA synchronous = FULL")
      try execute("PRAGMA temp_store = MEMORY")
      let pageSize = try queryPragmaInt("page_size")
      guard pageSize > 0 else {
        throw NativeLocationJournalError.database(
          operation: "read page size",
          code: SQLITE_MISUSE,
          message: "SQLite returned an invalid page size."
        )
      }
      let maximumPageCount = max(
        1,
        Self.maximumDatabaseBytes / Int(pageSize)
      )
      try execute("PRAGMA max_page_count = \(maximumPageCount)")
      try execute(
        """
        CREATE TABLE IF NOT EXISTS pending_locations (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT,
          event_id TEXT NOT NULL UNIQUE CHECK(length(event_id) > 0),
          track_id TEXT NOT NULL CHECK(length(track_id) > 0),
          captured_at_ms INTEGER NOT NULL,
          created_at_ms INTEGER NOT NULL,
          payload BLOB NOT NULL CHECK(length(payload) > 0)
        )
        """
      )
      try execute(
        """
        CREATE INDEX IF NOT EXISTS pending_locations_capture_order
        ON pending_locations(captured_at_ms, sequence)
        """
      )
      try execute("PRAGMA user_version = 1")
      try verifyIntegrity()
      pendingCount = try queryCount()
      try applyDataProtection(to: fileURL)
      return pendingCount
    } catch {
      sqlite3_close_v2(openedDatabase)
      database = nil
      throw error
    }
  }

  @discardableResult
  func ensureCapacityForCapture() throws -> Int {
    let count = try prepare()
    guard count < Self.maximumPendingEvents else {
      throw NativeLocationJournalError.capacity(
        current: count,
        maximum: Self.maximumPendingEvents
      )
    }
    return count
  }

  /// Commits the exact envelope before it is delivered over EventChannel.
  @discardableResult
  func append(_ event: [String: Any]) throws -> Int {
    try prepare()

    guard let eventId = event["eventId"] as? String, !eventId.isEmpty else {
      throw NativeLocationJournalError.invalidEvent("eventId is required.")
    }
    guard let trackId = event["trackId"] as? String, !trackId.isEmpty else {
      throw NativeLocationJournalError.invalidEvent("trackId is required.")
    }
    guard let timestamp = event["timestamp"] as? NSNumber else {
      throw NativeLocationJournalError.invalidEvent("timestamp is required.")
    }
    guard JSONSerialization.isValidJSONObject(event) else {
      throw NativeLocationJournalError.invalidEvent("payload is not valid JSON.")
    }

    let payload: Data
    do {
      payload = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
    } catch {
      throw NativeLocationJournalError.invalidEvent(error.localizedDescription)
    }
    guard payload.count <= Self.maximumPayloadBytes else {
      throw NativeLocationJournalError.invalidEvent(
        "payload is \(payload.count) bytes; maximum is \(Self.maximumPayloadBytes)."
      )
    }

    return try transaction {
      guard pendingCount < Self.maximumPendingEvents else {
        throw NativeLocationJournalError.capacity(
          current: pendingCount,
          maximum: Self.maximumPendingEvents
        )
      }

      let sql =
        """
        INSERT OR IGNORE INTO pending_locations(
          event_id, track_id, captured_at_ms, created_at_ms, payload
        ) VALUES (?, ?, ?, ?, ?)
        """
      let statement = try prepareStatement(sql, operation: "prepare insert")
      defer { sqlite3_finalize(statement) }

      try bind(eventId, to: statement, index: 1, operation: "bind event ID")
      try bind(trackId, to: statement, index: 2, operation: "bind track ID")
      sqlite3_bind_int64(statement, 3, timestamp.int64Value)
      sqlite3_bind_int64(statement, 4, epochMilliseconds(Date()))
      let bindPayloadCode = payload.withUnsafeBytes { bytes in
        sqlite3_bind_blob(
          statement,
          5,
          bytes.baseAddress,
          Int32(bytes.count),
          sqliteTransient
        )
      }
      guard bindPayloadCode == SQLITE_OK else {
        throw databaseError(operation: "bind payload", code: bindPayloadCode)
      }

      let stepCode = sqlite3_step(statement)
      guard stepCode == SQLITE_DONE else {
        throw databaseError(operation: "insert", code: stepCode)
      }
      if sqlite3_changes(requiredDatabase()) > 0 {
        pendingCount += 1
      }
      return pendingCount
    }
  }

  func pendingLocations() throws -> [[String: Any]] {
    try prepare()
    let statement = try prepareStatement(
      """
      SELECT event_id, track_id, payload
      FROM pending_locations
      ORDER BY captured_at_ms ASC, sequence ASC
      """,
      operation: "prepare pending query"
    )
    defer { sqlite3_finalize(statement) }

    var events: [[String: Any]] = []
    events.reserveCapacity(pendingCount)
    while true {
      let stepCode = sqlite3_step(statement)
      if stepCode == SQLITE_DONE { break }
      guard stepCode == SQLITE_ROW else {
        throw databaseError(operation: "read pending events", code: stepCode)
      }

      guard let eventIdText = sqlite3_column_text(statement, 0),
        let trackIdText = sqlite3_column_text(statement, 1),
        let payloadBytes = sqlite3_column_blob(statement, 2)
      else {
        throw NativeLocationJournalError.corruptEvent("A required column is null.")
      }
      let payloadLength = Int(sqlite3_column_bytes(statement, 2))
      guard payloadLength > 0, payloadLength <= Self.maximumPayloadBytes else {
        throw NativeLocationJournalError.corruptEvent(
          "Payload length \(payloadLength) is invalid."
        )
      }

      let eventId = String(cString: eventIdText)
      let trackId = String(cString: trackIdText)
      let payload = Data(bytes: payloadBytes, count: payloadLength)
      let decoded: Any
      do {
        decoded = try JSONSerialization.jsonObject(with: payload)
      } catch {
        throw NativeLocationJournalError.corruptEvent(error.localizedDescription)
      }
      guard let event = decoded as? [String: Any],
        event["eventId"] as? String == eventId,
        event["trackId"] as? String == trackId
      else {
        throw NativeLocationJournalError.corruptEvent(
          "Payload identity does not match its journal row."
        )
      }
      events.append(event)
    }
    return events
  }

  func pendingLocationPage(
    cursor: String?,
    maxRecords: Int,
    maxEncodedBytes: Int
  ) throws -> NativeLocationJournalPage {
    try prepare()
    let afterSequence: Int64
    if let cursor {
      guard let parsed = Int64(cursor), parsed >= 0 else {
        throw NativeLocationJournalError.invalidCursor
      }
      afterSequence = parsed
    } else {
      afterSequence = 0
    }
    let recordLimit = min(max(maxRecords, 1), Self.maximumPageRecords)
    let byteLimit = min(
      max(maxEncodedBytes, Self.maximumPayloadBytes),
      Self.maximumPageBytes
    )
    let statement = try prepareStatement(
      """
      SELECT sequence, event_id, track_id, payload
      FROM pending_locations
      WHERE sequence > ?
      ORDER BY sequence ASC
      LIMIT ?
      """,
      operation: "prepare pending page query"
    )
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, afterSequence)
    sqlite3_bind_int64(statement, 2, Int64(recordLimit + 1))

    var events: [[String: Any]] = []
    events.reserveCapacity(recordLimit)
    var encodedBytes = 0
    var lastSequence = afterSequence
    var hasMore = false
    while true {
      let stepCode = sqlite3_step(statement)
      if stepCode == SQLITE_DONE { break }
      guard stepCode == SQLITE_ROW else {
        throw databaseError(operation: "read pending event page", code: stepCode)
      }

      let sequence = sqlite3_column_int64(statement, 0)
      let event = try decodeEvent(
        from: statement,
        eventIdIndex: 1,
        trackIdIndex: 2,
        payloadIndex: 3
      )
      let payloadLength = Int(sqlite3_column_bytes(statement, 3))
      if events.count >= recordLimit
        || (!events.isEmpty && encodedBytes + payloadLength > byteLimit)
      {
        hasMore = true
        break
      }

      events.append(event)
      encodedBytes += payloadLength
      lastSequence = sequence
    }

    let remaining = try queryCount(
      after: events.isEmpty ? afterSequence : lastSequence
    )
    return NativeLocationJournalPage(
      events: events,
      nextCursor: events.isEmpty ? nil : String(lastSequence),
      hasMore: hasMore || remaining > 0,
      encodedBytes: encodedBytes,
      remainingCount: remaining
    )
  }

  func acknowledge(eventIds: [String]) throws -> NativeLocationJournalAcknowledgement {
    try prepare()
    let uniqueEventIds = Array(Set(eventIds))
    guard uniqueEventIds.allSatisfy({ !$0.isEmpty }) else {
      throw NativeLocationJournalError.invalidEvent(
        "acknowledgement event IDs must be non-empty."
      )
    }
    guard !uniqueEventIds.isEmpty else {
      return NativeLocationJournalAcknowledgement(deleted: 0, remaining: pendingCount)
    }

    return try transaction {
      let statement = try prepareStatement(
        "DELETE FROM pending_locations WHERE event_id = ?",
        operation: "prepare acknowledgement"
      )
      defer { sqlite3_finalize(statement) }

      var deleted = 0
      for eventId in uniqueEventIds {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bind(eventId, to: statement, index: 1, operation: "bind acknowledgement")
        let stepCode = sqlite3_step(statement)
        guard stepCode == SQLITE_DONE else {
          throw databaseError(operation: "acknowledge", code: stepCode)
        }
        deleted += Int(sqlite3_changes(requiredDatabase()))
      }
      pendingCount = max(0, pendingCount - deleted)
      return NativeLocationJournalAcknowledgement(
        deleted: deleted,
        remaining: pendingCount
      )
    }
  }

  func deleteTrack(trackId: String) throws -> Int {
    try prepare()
    guard !trackId.isEmpty, trackId.utf8.count <= 512 else {
      throw NativeLocationJournalError.invalidEvent("A valid trackId is required.")
    }
    return try transaction {
      let statement = try prepareStatement(
        "DELETE FROM pending_locations WHERE track_id = ?",
        operation: "prepare track-scoped deletion"
      )
      defer { sqlite3_finalize(statement) }
      try bind(trackId, to: statement, index: 1, operation: "bind track deletion")
      let stepCode = sqlite3_step(statement)
      guard stepCode == SQLITE_DONE else {
        throw databaseError(operation: "delete track events", code: stepCode)
      }
      let deleted = Int(sqlite3_changes(requiredDatabase()))
      pendingCount = max(0, pendingCount - deleted)
      return deleted
    }
  }

  func diagnostic(performMaintenance: Bool = false) throws -> [String: Any] {
    try prepare()
    let integrity = try quickCheck()
    let pageSize = try queryPragmaInt("page_size")
    let pageCount = try queryPragmaInt("page_count")
    let freelistPages = min(
      max(try queryPragmaInt("freelist_count"), 0),
      max(pageCount, 0)
    )
    let livePages = max(pageCount - freelistPages, 0)
    let pendingPayloadBytes = try queryPendingPayloadBytes()
    return [
      "platform": "ios",
      "healthy": integrity == "ok",
      "opened": true,
      "databaseName": Self.databaseName,
      "integrityCheck": integrity,
      "stats": [
        "pendingRows": pendingCount,
        "pendingPayloadBytes": pendingPayloadBytes,
        "pageSizeBytes": pageSize,
        "pageCount": pageCount,
        "freelistPages": freelistPages,
        "livePages": livePages,
        "liveDatabaseBytes": livePages * pageSize,
        "maxPageCount": try queryPragmaInt("max_page_count"),
        "maintenanceResult": performMaintenance ? "not_required" : "not_run",
      ],
    ]
  }

  private func journalFileURL() throws -> URL {
    guard
      let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      throw NativeLocationJournalError.fileSystem(
        "Application Support directory is unavailable."
      )
    }

    var directory = applicationSupport.appendingPathComponent(
      Self.directoryName,
      isDirectory: true
    )
    do {
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [
          .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ]
      )
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: directory.path
      )
      var resourceValues = URLResourceValues()
      resourceValues.isExcludedFromBackup = true
      try directory.setResourceValues(resourceValues)
    } catch {
      throw NativeLocationJournalError.fileSystem(error.localizedDescription)
    }
    return directory.appendingPathComponent(Self.databaseName, isDirectory: false)
  }

  private func applyDataProtection(to fileURL: URL) throws {
    do {
      try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: fileURL.path
      )
      var protectedURL = fileURL
      var resourceValues = URLResourceValues()
      resourceValues.isExcludedFromBackup = true
      try protectedURL.setResourceValues(resourceValues)
    } catch {
      throw NativeLocationJournalError.fileSystem(error.localizedDescription)
    }
  }

  private func verifyIntegrity() throws {
    let result = try quickCheck()
    guard result == "ok" else {
      throw NativeLocationJournalError.corruptEvent("SQLite quick check returned: \(result)")
    }
  }

  private func quickCheck() throws -> String {
    let statement = try prepareStatement(
      "PRAGMA quick_check(1)",
      operation: "prepare quick check"
    )
    defer { sqlite3_finalize(statement) }
    let stepCode = sqlite3_step(statement)
    guard stepCode == SQLITE_ROW, let resultText = sqlite3_column_text(statement, 0) else {
      throw databaseError(operation: "quick check", code: stepCode)
    }
    return String(cString: resultText)
  }

  private func queryCount() throws -> Int {
    let statement = try prepareStatement(
      "SELECT COUNT(*) FROM pending_locations",
      operation: "prepare count"
    )
    defer { sqlite3_finalize(statement) }
    let stepCode = sqlite3_step(statement)
    guard stepCode == SQLITE_ROW else {
      throw databaseError(operation: "count", code: stepCode)
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func queryPendingPayloadBytes() throws -> Int64 {
    let statement = try prepareStatement(
      "SELECT COALESCE(SUM(length(payload)), 0) FROM pending_locations",
      operation: "prepare pending payload bytes"
    )
    defer { sqlite3_finalize(statement) }
    let stepCode = sqlite3_step(statement)
    guard stepCode == SQLITE_ROW else {
      throw databaseError(operation: "read pending payload bytes", code: stepCode)
    }
    return sqlite3_column_int64(statement, 0)
  }

  private func queryPragmaInt(_ name: String) throws -> Int64 {
    let statement = try prepareStatement(
      "PRAGMA \(name)",
      operation: "prepare \(name) pragma"
    )
    defer { sqlite3_finalize(statement) }
    let stepCode = sqlite3_step(statement)
    guard stepCode == SQLITE_ROW else {
      throw databaseError(operation: "read \(name) pragma", code: stepCode)
    }
    return sqlite3_column_int64(statement, 0)
  }

  private func queryCount(after sequence: Int64) throws -> Int {
    let statement = try prepareStatement(
      "SELECT COUNT(*) FROM pending_locations WHERE sequence > ?",
      operation: "prepare count after sequence"
    )
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, sequence)
    let stepCode = sqlite3_step(statement)
    guard stepCode == SQLITE_ROW else {
      throw databaseError(operation: "count after sequence", code: stepCode)
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func decodeEvent(
    from statement: OpaquePointer,
    eventIdIndex: Int32,
    trackIdIndex: Int32,
    payloadIndex: Int32
  ) throws -> [String: Any] {
    guard let eventIdText = sqlite3_column_text(statement, eventIdIndex),
      let trackIdText = sqlite3_column_text(statement, trackIdIndex),
      let payloadBytes = sqlite3_column_blob(statement, payloadIndex)
    else {
      throw NativeLocationJournalError.corruptEvent("A required column is null.")
    }
    let payloadLength = Int(sqlite3_column_bytes(statement, payloadIndex))
    guard payloadLength > 0, payloadLength <= Self.maximumPayloadBytes else {
      throw NativeLocationJournalError.corruptEvent(
        "Payload length \(payloadLength) is invalid."
      )
    }

    let eventId = String(cString: eventIdText)
    let trackId = String(cString: trackIdText)
    let payload = Data(bytes: payloadBytes, count: payloadLength)
    let decoded: Any
    do {
      decoded = try JSONSerialization.jsonObject(with: payload)
    } catch {
      throw NativeLocationJournalError.corruptEvent(error.localizedDescription)
    }
    guard let event = decoded as? [String: Any],
      event["eventId"] as? String == eventId,
      event["trackId"] as? String == trackId
    else {
      throw NativeLocationJournalError.corruptEvent(
        "Payload identity does not match its journal row."
      )
    }
    return event
  }

  private func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let value = try body()
      try execute("COMMIT")
      return value
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func execute(_ sql: String) throws {
    let database = try requiredDatabaseOrThrow()
    var errorMessage: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(database, sql, nil, nil, &errorMessage)
    guard code == SQLITE_OK else {
      let message =
        errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(database))
      if let errorMessage { sqlite3_free(errorMessage) }
      throw NativeLocationJournalError.database(
        operation: "execute SQL",
        code: code,
        message: message
      )
    }
  }

  private func prepareStatement(_ sql: String, operation: String) throws -> OpaquePointer {
    let database = try requiredDatabaseOrThrow()
    var statement: OpaquePointer?
    let code = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
    guard code == SQLITE_OK, let statement else {
      throw databaseError(operation: operation, code: code)
    }
    return statement
  }

  private func bind(
    _ value: String,
    to statement: OpaquePointer,
    index: Int32,
    operation: String
  ) throws {
    let code = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    guard code == SQLITE_OK else {
      throw databaseError(operation: operation, code: code)
    }
  }

  private func requiredDatabase() -> OpaquePointer {
    // All callers have successfully completed prepare(). Keeping this helper
    // non-optional makes sqlite3_changes calls readable without force unwraps.
    database!
  }

  private func requiredDatabaseOrThrow() throws -> OpaquePointer {
    guard let database else {
      throw NativeLocationJournalError.database(
        operation: "access",
        code: SQLITE_MISUSE,
        message: "Database has not been opened."
      )
    }
    return database
  }

  private func databaseError(operation: String, code: Int32) -> NativeLocationJournalError {
    let message =
      database.map { String(cString: sqlite3_errmsg($0)) }
      ?? "Database is unavailable."
    return .database(operation: operation, code: code, message: message)
  }

  private func epochMilliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded())
  }
}
