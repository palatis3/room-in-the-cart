import Foundation
import CSQLite

/// Payload-free evidence used to invalidate archived and independently recovered copies.
public struct InventoryTombstone: Equatable, Sendable {
    public let key: InventoryRecordKey
    public let workspaceID: UUID
    public let erasedRevision: Int64
    public let operationID: UUID
}

public struct InventoryRetiredSource: Equatable, Sendable {
    public let source: InventorySourceIdentity
    public let workspaceID: UUID
    public let operationID: UUID
}

extension ComparisonStore {
    /// Read every page at the same inventory revision. A concurrent erasure or
    /// mutation invalidates the scan instead of returning a partial proof of absence.
    public func inventoryTombstones(kind: InventoryRecordKind, expectedInventoryRevision: Int64,
                                    after: UUID? = nil, limit: Int = 100) throws -> [InventoryTombstone] {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        guard expectedInventoryRevision >= 0, (1...InventoryPersistenceLimits.pageItems).contains(limit) else {
            throw ComparisonStoreError.invalidInput
        }
        return try database.transaction(immediate: false) {
            guard try database.inventoryState(workspaceID: workspaceID).revision == expectedInventoryRevision else {
                throw ComparisonStoreError.staleInventory
            }
            var query = "SELECT id, revision, operation_id FROM inventory_tombstones WHERE kind = ?"
            var values: [ComparisonSQLValue] = [.text(kind.rawValue)]
            if let after { query += " AND id > ?"; values.append(.text(after.uuidString)) }
            query += " ORDER BY id LIMIT ?"; values.append(.integer(Int64(limit)))
            let row = try database.statement(query, values: values)
            defer { sqlite3_finalize(row) }
            var result: [InventoryTombstone] = []
            while true {
                let status = sqlite3_step(row)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw ComparisonStoreError.database(status) }
                guard let id = UUID(uuidString: try database.text(row, column: 0)),
                      sqlite3_column_type(row, 1) == SQLITE_INTEGER, sqlite3_column_int64(row, 1) > 0,
                      let operationID = UUID(uuidString: try database.text(row, column: 2)) else {
                    throw ComparisonStoreError.corruptRecord
                }
                result.append(.init(key: .init(kind, id), workspaceID: workspaceID,
                    erasedRevision: sqlite3_column_int64(row, 1), operationID: operationID))
            }
        }
    }

    public func inventoryRetiredSources(expectedInventoryRevision: Int64,
                                        after: InventorySourceIdentity? = nil, limit: Int = 100) throws -> [InventoryRetiredSource] {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        guard expectedInventoryRevision >= 0, (1...InventoryPersistenceLimits.pageItems).contains(limit),
              after.map({ (1...256).contains($0.sourceID.utf8.count) }) != false else { throw ComparisonStoreError.invalidInput }
        return try database.transaction(immediate: false) {
            guard try database.inventoryState(workspaceID: workspaceID).revision == expectedInventoryRevision else {
                throw ComparisonStoreError.staleInventory
            }
            var query = "SELECT origin_id, source_id, operation_id FROM inventory_retired_sources"
            var values: [ComparisonSQLValue] = []
            if let after {
                query += " WHERE (origin_id, source_id) > (?, ?)"
                values = [.text(after.originID.uuidString), .text(after.sourceID)]
            }
            query += " ORDER BY origin_id, source_id LIMIT ?"; values.append(.integer(Int64(limit)))
            let row = try database.statement(query, values: values)
            defer { sqlite3_finalize(row) }
            var result: [InventoryRetiredSource] = []
            while true {
                let status = sqlite3_step(row)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw ComparisonStoreError.database(status) }
                guard let origin = UUID(uuidString: try database.text(row, column: 0)),
                      let operation = UUID(uuidString: try database.text(row, column: 2)) else {
                    throw ComparisonStoreError.corruptRecord
                }
                let source = try database.text(row, column: 1)
                guard (1...256).contains(source.utf8.count) else { throw ComparisonStoreError.corruptRecord }
                result.append(.init(source: .init(originID: origin, sourceID: source), workspaceID: workspaceID, operationID: operation))
            }
        }
    }
}
