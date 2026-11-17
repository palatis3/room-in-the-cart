import CSQLite
import Foundation

public struct InventoryRevisionCursor: Codable, Equatable, Sendable {
  public let kind: InventoryRecordKind
  public let id: UUID
  public let revision: Int64
  public init(kind: InventoryRecordKind, id: UUID, revision: Int64) {
    self.kind = kind
    self.id = id
    self.revision = revision
  }
}
public struct InventoryComparisonRevisionCursor: Codable, Equatable, Sendable {
  public let id: UUID
  public let revision: Int64
  public init(id: UUID, revision: Int64) {
    self.id = id
    self.revision = revision
  }
}

extension ComparisonStore {
  /// Retained history, not only current heads. Every page is tied to the same
  /// complete source token and canonical revision. An empty page ends the scan.
  /// The byte cap can shorten a page even when `limit` has not been reached.
  public func inventoryRevisionPage(
    expectedRevision: Int64, sourceToken: InventorySourceToken,
    after: InventoryRevisionCursor? = nil, limit: Int = 100
  ) throws -> [InventoryRecord] {
    guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
    guard expectedRevision >= 0, (1...200).contains(limit), after.map({ $0.revision > 0 }) != false
    else { throw ComparisonStoreError.invalidInput }
    return try database.transaction(immediate: false) {
      try requireErasureHistoryBasis(expectedRevision, sourceToken)
      var query = """
        SELECT r.kind,r.id,r.revision,r.payload_version,r.payload,r.digest,r.lot_id,h.source_origin,h.source_id
        FROM inventory_revisions r JOIN inventory_heads h ON h.kind=r.kind AND h.id=r.id
        """
      var values: [ComparisonSQLValue] = []
      if let after {
        query += " WHERE (r.kind,r.id,r.revision)>(?,?,?)"
        values = [.text(after.kind.rawValue), .text(after.id.uuidString), .integer(after.revision)]
      }
      query += " ORDER BY r.kind,r.id,r.revision LIMIT ?"
      values.append(.integer(Int64(limit)))
      let row = try database.statement(query, values: values)
      defer { sqlite3_finalize(row) }
      var result: [InventoryRecord] = []
      var used = 0
      while true {
        let status = sqlite3_step(row)
        if status == SQLITE_DONE { return result }
        guard status == SQLITE_ROW,
          let kind = InventoryRecordKind(rawValue: try database.text(row, column: 0)),
          let id = UUID(uuidString: try database.text(row, column: 1)),
          sqlite3_column_type(row, 2) == SQLITE_INTEGER,
          sqlite3_column_type(row, 3) == SQLITE_INTEGER
        else { throw ComparisonStoreError.corruptRecord }
        let payload = try database.inventoryBlob(
          row, column: 4, maximum: InventoryPersistenceLimits.recordBytes)
        guard inventoryDigest(payload) == (try database.inventoryBlob(row, column: 5, maximum: 32))
        else { throw ComparisonStoreError.corruptRecord }
        if !result.isEmpty, used + payload.count > InventoryPersistenceLimits.batchBytes {
          return result
        }
        let lot: UUID?
        if sqlite3_column_type(row, 6) == SQLITE_NULL {
          lot = nil
        } else {
          guard let value = UUID(uuidString: try database.text(row, column: 6)) else {
            throw ComparisonStoreError.corruptRecord
          }
          lot = value
        }
        let source: InventorySourceIdentity?
        if sqlite3_column_type(row, 7) == SQLITE_NULL {
          source = nil
        } else {
          guard let origin = UUID(uuidString: try database.text(row, column: 7)) else {
            throw ComparisonStoreError.corruptRecord
          }
          source = .init(originID: origin, sourceID: try database.text(row, column: 8))
        }
        result.append(
          .init(
            key: .init(kind, id), revision: sqlite3_column_int64(row, 2),
            payloadVersion: Int(sqlite3_column_int64(row, 3)), payload: payload, lotID: lot,
            source: source))
        used += payload.count
      }
    }
  }

  public func inventoryComparisonRevisionPage(
    expectedRevision: Int64, sourceToken: InventorySourceToken,
    after: InventoryComparisonRevisionCursor? = nil, limit: Int = 100
  ) throws -> [SavedComparison] {
    guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
    guard expectedRevision >= 0, (1...200).contains(limit), after.map({ $0.revision > 0 }) != false
    else { throw ComparisonStoreError.invalidInput }
    return try database.transaction(immediate: false) {
      try requireErasureHistoryBasis(expectedRevision, sourceToken)
      var cursor = after
      var result: [SavedComparison] = []
      var used = 0
      // Decode one bounded envelope at a time; 200 maximum-sized snapshots
      // must not be loaded just to discover they exceed the page byte budget.
      while result.count < limit {
        var query =
          "SELECT comparison_id,title,envelope,saved_at,revision FROM comparison_revisions"
        var values: [ComparisonSQLValue] = []
        if let cursor {
          query += " WHERE (comparison_id,revision)>(?,?)"
          values = [.text(cursor.id.uuidString), .integer(cursor.revision)]
        }
        query += " ORDER BY comparison_id,revision LIMIT 1"
        guard let value = try database.records(query, values: values).first else { break }
        let bytes = value.payload.count + value.title.utf8.count
        if !result.isEmpty, used + bytes > InventoryPersistenceLimits.batchBytes { break }
        result.append(value)
        used += bytes
        cursor = .init(id: value.id, revision: value.revision)
      }
      return result
    }
  }

  /// SQL-paged payload-free comparison retirements at one complete source token.
  public func inventoryComparisonTombstones(
    token: InventorySourceToken, after: UUID? = nil,
    limit: Int = 100
  ) throws -> [ComparisonTombstone] {
    guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
    guard (1...200).contains(limit) else { throw ComparisonStoreError.invalidInput }
    return try database.transaction(immediate: false) {
      guard token == (try database.inventorySourceToken(workspaceID: workspaceID)) else {
        throw ComparisonStoreError.staleInventory
      }
      var suffix = ""
      var values: [ComparisonSQLValue] = []
      if let after {
        suffix = "WHERE comparison_id > ? "
        values.append(.text(after.uuidString))
      }
      suffix += "ORDER BY comparison_id LIMIT ?"
      values.append(.integer(Int64(limit)))
      return try database.tombstones(suffix, values: values)
    }
  }

  /// Latest cumulative history floor per stable claim. Tombstones take precedence
  /// if the claim was later erased. These metadata remain readable after origin retirement.
  public func inventoryReservationRedactions(
    expectedInventoryRevision: Int64, after: UUID? = nil,
    limit: Int = 100
  ) throws -> [InventoryReservationRedaction] {
    guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
    guard expectedInventoryRevision >= 0, (1...200).contains(limit) else {
      throw ComparisonStoreError.invalidInput
    }
    return try database.transaction(immediate: false) {
      guard
        try database.inventoryState(workspaceID: workspaceID).revision == expectedInventoryRevision
      else { throw ComparisonStoreError.staleInventory }
      var query =
        "SELECT id,through_revision,operation_id,previous_lot_id FROM inventory_reservation_redactions d WHERE through_revision=(SELECT max(through_revision) FROM inventory_reservation_redactions x WHERE x.id=d.id)"
      var values: [ComparisonSQLValue] = []
      if let after {
        query += " AND id>?"
        values.append(.text(after.uuidString))
      }
      query += " ORDER BY id LIMIT ?"
      values.append(.integer(Int64(limit)))
      let row = try database.statement(query, values: values)
      defer { sqlite3_finalize(row) }
      var result: [InventoryReservationRedaction] = []
      while true {
        let status = sqlite3_step(row)
        if status == SQLITE_DONE { return result }
        guard status == SQLITE_ROW, let id = UUID(uuidString: try database.text(row, column: 0)),
          let operation = UUID(uuidString: try database.text(row, column: 2)),
          sqlite3_column_type(row, 1) == SQLITE_INTEGER
        else { throw ComparisonStoreError.corruptRecord }
        let pin: UUID?
        if sqlite3_column_type(row, 3) == SQLITE_NULL {
          pin = nil
        } else {
          guard let value = UUID(uuidString: try database.text(row, column: 3)) else {
            throw ComparisonStoreError.corruptRecord
          }
          pin = value
        }
        let revision = sqlite3_column_int64(row, 1)
        guard revision > 0 else { throw ComparisonStoreError.corruptRecord }
        result.append(
          .init(
            workspaceID: workspaceID, reservationID: id, throughRevision: revision,
            operationID: operation, previousLotID: pin))
      }
    }
  }

  private func requireErasureHistoryBasis(_ revision: Int64, _ token: InventorySourceToken) throws {
    try database.requireInventoryOriginLive()
    guard try database.inventoryState(workspaceID: workspaceID).revision == revision,
      try database.inventorySourceToken(workspaceID: workspaceID) == token
    else { throw ComparisonStoreError.staleInventory }
  }
}
