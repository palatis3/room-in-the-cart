import CSQLite
import Foundation

/// The caller owns the complete application graph, including references in historical
/// comparison/intent payloads. LocalStore additionally enforces SQL parent closure.
public enum InventoryErasureEntry: Codable, Equatable, Sendable {
  case record(InventoryErase)
  case comparison(id: UUID, expectedRevision: Int64)
  /// Same stable claim, sanitized retained body at expectedRevision + 1.
  /// The app/domain must keep surviving held claims unresolved, never released.
  /// All older bodies are removed, rather than left as accessible history.
  case reservation(InventoryWrite)
}

public struct InventoryErasureChunk: Codable, Equatable, Sendable {
  public let index: Int64
  public let entries: [InventoryErasureEntry]
  public init(index: Int64, entries: [InventoryErasureEntry]) {
    self.index = index
    self.entries = entries
  }
}

public struct InventoryErasureManifest: Codable, Equatable, Sendable {
  public enum Scope: String, Codable, Sendable { case sourceGraph, origin }
  public let version: Int
  public let workspaceID: UUID
  public let operationID: UUID
  public let expectedRevision: Int64
  public let sourceToken: InventorySourceToken
  public let scope: Scope
  public let chunkCount: Int64
  public let entryCount: Int64
  public let manifestDigest: Data
  public init(
    workspaceID: UUID, operationID: UUID, expectedRevision: Int64,
    sourceToken: InventorySourceToken,
    scope: Scope = .sourceGraph, chunkCount: Int64, entryCount: Int64, manifestDigest: Data
  ) {
    version = 1
    self.workspaceID = workspaceID
    self.operationID = operationID
    self.expectedRevision = expectedRevision
    self.sourceToken = sourceToken
    self.scope = scope
    self.chunkCount = chunkCount
    self.entryCount = entryCount
    self.manifestDigest = manifestDigest
  }
  public static var initialDigest: Data {
    inventoryDigest(Data("inventory-erasure-manifest/v1".utf8))
  }
  public static func appending(_ chunk: InventoryErasureChunk, to previous: Data) throws -> Data {
    guard previous.count == 32 else { throw ComparisonStoreError.invalidInput }
    try validateErasureChunk(chunk)
    return inventoryDigest(previous + inventoryDigest(try inventoryCanonical(chunk)))
  }
}

/// Contains no deleted titles, food quantities, notes, or replay bodies.
public struct InventoryErasureReceipt: Codable, Equatable, Sendable {
  public let workspaceID: UUID
  public let operationID: UUID
  public let scope: InventoryErasureManifest.Scope
  public let erasedRevision: Int64
  public let revision: Int64
  public let erasedRecordCount: Int64
  public let erasedComparisonCount: Int64
  public let redactedReservationCount: Int64
  public let committedAt: Date
}

public struct InventoryErasureProgress: Equatable, Sendable {
  public enum Status: String, Sendable { case staging, completed, cancelled }
  public let manifest: InventoryErasureManifest
  public let status: Status
  public let nextChunk: Int64
  public let stagedEntryCount: Int64
  public let receipt: InventoryErasureReceipt?
}

public struct InventoryReservationRedaction: Codable, Equatable, Sendable {
  public let workspaceID: UUID
  public let reservationID: UUID
  public let throughRevision: Int64
  public let operationID: UUID
  public let previousLotID: UUID?
  public init(
    workspaceID: UUID, reservationID: UUID, throughRevision: Int64, operationID: UUID,
    previousLotID: UUID?
  ) {
    self.workspaceID = workspaceID
    self.reservationID = reservationID
    self.throughRevision = throughRevision
    self.operationID = operationID
    self.previousLotID = previousLotID
  }
}

func validateErasureChunk(_ chunk: InventoryErasureChunk) throws {
  guard chunk.index >= 0, !chunk.entries.isEmpty,
    chunk.entries.count <= InventoryPersistenceLimits.batchItems
  else {
    throw ComparisonStoreError.invalidInput
  }
  var keys = Set<String>()
  for entry in chunk.entries {
    let key: String
    switch entry {
    case .record(let value):
      guard value.expectedRevision > 0 else { throw ComparisonStoreError.invalidInput }
      key = value.key.kind.rawValue + ":" + value.key.id.uuidString
    case .comparison(let id, let revision):
      guard revision > 0 else { throw ComparisonStoreError.invalidInput }
      key = "comparison:" + id.uuidString
    case .reservation(let value):
      let record = value.record
      guard record.key.kind == .reservation, value.expectedRevision > 0,
        value.expectedRevision < Int64.max,
        record.revision == value.expectedRevision + 1, record.source == nil,
        (1...10_000).contains(record.payloadVersion), !record.payload.isEmpty,
        record.payload.count <= InventoryPersistenceLimits.recordBytes
      else { throw ComparisonStoreError.invalidInput }
      key = "reservation:" + record.key.id.uuidString
    }
    guard keys.insert(key).inserted else { throw ComparisonStoreError.invalidInput }
  }
  guard try inventoryCanonical(chunk).count <= InventoryPersistenceLimits.batchBytes else {
    throw ComparisonStoreError.payloadTooLarge
  }
}

extension ComparisonStore {
  /// Durable staging contains only a bounded manifest and bounded entry pages. No
  /// canonical payload is erased until finish commits the entire graph atomically.
  public func beginInventoryErasure(_ manifest: InventoryErasureManifest) throws
    -> InventoryErasureProgress
  {
    guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
    try validateErasureManifest(manifest)
    return try database.transaction { try beginErasure(manifest) }
  }

  public func stageInventoryErasure(id: UUID, chunk: InventoryErasureChunk) throws
    -> InventoryErasureProgress
  {
    guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
    try validateErasureChunk(chunk)
    return try database.transaction {
      try database.requireInventoryOriginLive()
      guard let current = try database.erasureProgress(id) else {
        throw ComparisonStoreError.notFound
      }
      guard current.status == .staging else { throw ComparisonStoreError.erased }
      try validateErasureBasis(current.manifest)
      return try stageErasure(current, chunk: chunk)
    }
  }

  /// Exact completed work is recognized before stale-base checks. Reusing an ID
  /// with another manifest is rejected by begin; cancelled work never resumes.
  public func finishInventoryErasure(id: UUID, at date: Date = Date()) throws
    -> InventoryErasureReceipt
  {
    guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
    guard date.timeIntervalSinceReferenceDate.isFinite else {
      throw ComparisonStoreError.invalidInput
    }
    let result = try database.transaction { try finishErasure(id: id, at: date) }
    database.checkpointAfterErasure()
    return result
  }

  /// Convenience for a bounded in-memory graph. Large graphs use the same public
  /// manifest/chunk APIs; there is no fixed total graph-size ceiling on staging.
  public func eraseInventory(
    workspaceID: UUID, operationID: UUID, expectedRevision: Int64,
    sourceToken: InventorySourceToken, entries: [InventoryErasureEntry],
    at date: Date = Date()
  ) throws -> InventoryErasureReceipt {
    guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
    guard entries.count <= 250_000, date.timeIntervalSinceReferenceDate.isFinite else {
      throw ComparisonStoreError.invalidInput
    }
    var chunks: [InventoryErasureChunk] = []
    var pending: [InventoryErasureEntry] = []
    var digest = InventoryErasureManifest.initialDigest
    var totalBytes = 0
    for entry in entries {
      // A single replacement is <=64 KiB; split by canonical bytes as well as count.
      let bytes = try inventoryCanonical(entry).count
      guard bytes < InventoryPersistenceLimits.batchBytes else {
        throw ComparisonStoreError.payloadTooLarge
      }
      totalBytes += bytes
      guard totalBytes <= 32 * 1_024 * 1_024 else { throw ComparisonStoreError.payloadTooLarge }
      let combinedBytes = try inventoryCanonical(pending + [entry]).count
      if !pending.isEmpty && (pending.count == 256 || combinedBytes > 1_400_000) {
        let chunk = InventoryErasureChunk(index: Int64(chunks.count), entries: pending)
        digest = try InventoryErasureManifest.appending(chunk, to: digest)
        chunks.append(chunk)
        pending = []
      }
      pending.append(entry)
    }
    if !pending.isEmpty {
      let chunk = InventoryErasureChunk(index: Int64(chunks.count), entries: pending)
      digest = try InventoryErasureManifest.appending(chunk, to: digest)
      chunks.append(chunk)
    }
    let manifest = InventoryErasureManifest(
      workspaceID: workspaceID, operationID: operationID, expectedRevision: expectedRevision,
      sourceToken: sourceToken, chunkCount: Int64(chunks.count), entryCount: Int64(entries.count),
      manifestDigest: digest)
    try validateErasureManifest(manifest)
    let result = try database.transaction {
      var progress = try beginErasure(manifest)
      if let receipt = progress.receipt { return receipt }
      for chunk in chunks { progress = try stageErasure(progress, chunk: chunk) }
      return try finishErasure(id: operationID, at: date)
    }
    database.checkpointAfterErasure()
    return result
  }

  /// Permanently retires this inventory origin and this physical pickup database.
  /// Reopen exposes only retirement evidence. A new workspace needs a new file;
  /// ledger retirement and protected app-journal cleanup are separate operations.
  /// secure_delete and best-effort WAL truncation do not erase external backups,
  /// active reader snapshots, filesystem snapshots, or storage-media copies.
  public func eraseInventoryOrigin(
    expectedRevision: Int64, sourceToken: InventorySourceToken,
    operationID: UUID, at date: Date = Date()
  ) throws -> InventoryErasureReceipt {
    guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
    guard date.timeIntervalSinceReferenceDate.isFinite else {
      throw ComparisonStoreError.invalidInput
    }
    let manifest = InventoryErasureManifest(
      workspaceID: workspaceID, operationID: operationID, expectedRevision: expectedRevision,
      sourceToken: sourceToken, scope: .origin, chunkCount: 0, entryCount: 0,
      manifestDigest: InventoryErasureManifest.initialDigest)
    try validateErasureManifest(manifest)
    let result = try database.transaction {
      let progress = try beginErasure(manifest)
      if let receipt = progress.receipt { return receipt }
      return try finishErasure(id: operationID, at: date)
    }
    database.checkpointAfterErasure()
    return result
  }

  public func inventoryErasureProgress(id: UUID) throws -> InventoryErasureProgress? {
    guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
    return try database.transaction(immediate: false) { try database.erasureProgress(id) }
  }

  public func cancelInventoryErasure(id: UUID) throws -> InventoryErasureProgress {
    guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
    return try database.transaction {
      guard let current = try database.erasureProgress(id) else {
        throw ComparisonStoreError.notFound
      }
      guard current.status != .completed else { throw ComparisonStoreError.operationConflict }
      if current.status == .staging {
        try database.run(
          "UPDATE inventory_erasures SET status = 'cancelled' WHERE id = ?", [.text(id.uuidString)])
        try database.run(
          "DELETE FROM inventory_erasure_entries WHERE operation_id = ?", [.text(id.uuidString)])
      }
      return try database.erasureProgress(id)!
    }
  }

  public func inventoryOriginRetirement() throws -> InventoryErasureReceipt? {
    guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
    return try database.originRetirement()
  }

  private func validateErasureManifest(_ value: InventoryErasureManifest) throws {
    guard value.version == 1, value.workspaceID == workspaceID, value.expectedRevision >= 0,
      value.expectedRevision < Int64.max,
      value.sourceToken.workspaceID == workspaceID, value.sourceToken.generation >= 0,
      value.sourceToken.digest.count == 32,
      value.chunkCount >= 0, value.entryCount >= 0, value.chunkCount <= value.entryCount,
      value.chunkCount >= value.entryCount / 256 + (value.entryCount % 256 == 0 ? 0 : 1),
      value.manifestDigest.count == 32,
      value.scope == .origin ? value.entryCount == 0 : value.entryCount > 0
    else { throw ComparisonStoreError.invalidInput }
  }

  private func validateErasureBasis(_ manifest: InventoryErasureManifest) throws {
    try database.requireInventoryOriginLive()
    guard
      try database.inventoryState(workspaceID: workspaceID).revision == manifest.expectedRevision,
      try database.inventorySourceToken(workspaceID: workspaceID) == manifest.sourceToken
    else { throw ComparisonStoreError.staleInventory }
  }

  private func beginErasure(_ manifest: InventoryErasureManifest) throws -> InventoryErasureProgress
  {
    let bytes = try inventoryCanonical(manifest)
    let digest = inventoryDigest(bytes)
    if let previous = try database.erasureProgress(manifest.operationID) {
      guard previous.manifest == manifest else { throw ComparisonStoreError.operationConflict }
      guard previous.status != .cancelled else { throw ComparisonStoreError.erased }
      return previous
    }
    try validateErasureBasis(manifest)
    guard try database.inventoryReceipt(manifest.operationID) == nil,
      try database.migrationHeader(manifest.operationID) == nil,
      try database.tombstones(
        "WHERE operation_id = ?", values: [.text(manifest.operationID.uuidString)]
      ).isEmpty
    else {
      throw ComparisonStoreError.operationConflict
    }
    try database.run(
      "INSERT INTO inventory_erasures (id,manifest,digest,status,next_chunk,entry_count,chain_digest) VALUES (?,?,?,'staging',0,0,?)",
      [
        .text(manifest.operationID.uuidString), .blob(bytes), .blob(digest),
        .blob(InventoryErasureManifest.initialDigest),
      ])
    return try database.erasureProgress(manifest.operationID)!
  }

  private func stageErasure(_ current: InventoryErasureProgress, chunk: InventoryErasureChunk)
    throws -> InventoryErasureProgress
  {
    let id = current.manifest.operationID
    let bytes = try inventoryCanonical(chunk)
    let digest = inventoryDigest(bytes)
    if let existing = try database.erasureChunkDigest(id, index: chunk.index) {
      guard existing == digest else { throw ComparisonStoreError.operationConflict }
      return current
    }
    guard current.status == .staging, chunk.index == current.nextChunk,
      chunk.index < current.manifest.chunkCount,
      Int64(chunk.entries.count) <= current.manifest.entryCount - current.stagedEntryCount
    else { throw ComparisonStoreError.staleInventory }
    for (ordinal, entry) in chunk.entries.enumerated() {
      try database.stageErasureEntry(
        entry, operationID: id, chunkIndex: chunk.index, ordinal: ordinal)
    }
    let previous = try database.erasureChain(id)
    try database.run(
      "INSERT INTO inventory_erasure_chunks (operation_id,chunk_index,digest) VALUES (?,?,?)",
      [.text(id.uuidString), .integer(chunk.index), .blob(digest)])
    try database.run(
      "UPDATE inventory_erasures SET next_chunk = next_chunk + 1, entry_count = entry_count + ?, chain_digest = ? WHERE id = ?",
      [
        .integer(Int64(chunk.entries.count)), .blob(inventoryDigest(previous + digest)),
        .text(id.uuidString),
      ])
    return try database.erasureProgress(id)!
  }

  private func finishErasure(id: UUID, at date: Date) throws -> InventoryErasureReceipt {
    guard let current = try database.erasureProgress(id) else {
      throw ComparisonStoreError.notFound
    }
    if let receipt = current.receipt { return receipt }
    guard current.status == .staging else { throw ComparisonStoreError.erased }
    let plan = current.manifest
    try validateErasureBasis(plan)
    guard current.nextChunk == plan.chunkCount, current.stagedEntryCount == plan.entryCount,
      try database.erasureChain(id) == plan.manifestDigest
    else { throw ComparisonStoreError.staleInventory }
    try database.validateErasureStaging(current)
    let counts = try performInventoryErasure(plan, at: date)
    let receipt = InventoryErasureReceipt(
      workspaceID: workspaceID, operationID: id, scope: plan.scope,
      erasedRevision: plan.expectedRevision, revision: plan.expectedRevision + 1,
      erasedRecordCount: counts.records, erasedComparisonCount: counts.comparisons,
      redactedReservationCount: counts.redactions, committedAt: date)
    try database.run("UPDATE inventory_state SET revision = revision + 1 WHERE singleton = 1", [])
    try database.run(
      "UPDATE inventory_erasures SET status = 'completed', receipt = ? WHERE id = ?",
      [.blob(try inventoryCanonical(receipt)), .text(id.uuidString)])
    try database.run(
      "DELETE FROM inventory_erasure_entries WHERE operation_id = ?", [.text(id.uuidString)])
    if plan.scope == .origin {
      try database.run(
        "INSERT INTO inventory_origin_retirement (singleton,operation_id) VALUES (1,?)",
        [.text(id.uuidString)])
    }
    return receipt
  }
}
