import Foundation
import CryptoKit
import CSQLite

/// Identity only, never an authority grant. The app reauthorizes both origins before calling this port.
public struct LedgerInventoryProjectionBinding: Codable, Equatable, Sendable {
    public let ledgerWorkspaceID: UUID
    public let projectionID: UUID
    public let inventoryWorkspaceID: UUID
    public let inventoryOperationID: UUID
    public let kind: String
    public let targetID: UUID
    public init(ledgerWorkspaceID: UUID, projectionID: UUID, inventoryWorkspaceID: UUID,
                inventoryOperationID: UUID, kind: String, targetID: UUID) {
        self.ledgerWorkspaceID = ledgerWorkspaceID; self.projectionID = projectionID
        self.inventoryWorkspaceID = inventoryWorkspaceID; self.inventoryOperationID = inventoryOperationID
        self.kind = kind; self.targetID = targetID
    }
}

/// Deliberately does not return an old workspace payload. Reload the current ledger after recognition.
public struct LedgerInventoryProjectionReceipt: Equatable, Sendable {
    public let binding: LedgerInventoryProjectionBinding
    public let requestDigest: Data
    public let baseRevision: Int64
    public let revision: Int64
    public let payloadDigest: Data
    public let savedAt: Date
}

extension LedgerStore {
    public nonisolated static let maximumInventoryProjectionRequestBytes = 65_536

    public func inventoryProjectionReceipt(binding: LedgerInventoryProjectionBinding, request: Data) throws -> LedgerInventoryProjectionReceipt? {
        try validateInventoryProjectionInput(binding, request: request)
        let digest = Data(SHA256.hash(data: request))
        return try database.transaction(immediate: false) {
            try requireInventoryProjectionOrigin(binding)
            if let prior = try database.inventoryProjectionReceipt(binding.projectionID) {
                guard prior.binding == binding, prior.requestDigest == digest else { throw LedgerStoreError.operationConflict }
                return prior
            }
            // An ordinary save or a different projection ID cannot be adopted as this prepared projection's receipt.
            guard try !database.hasSaveOperation(binding.projectionID),
                  try !database.hasInventoryProjectionBinding(binding) else { throw LedgerStoreError.operationConflict }
            return nil
        }
    }

    @discardableResult
    public func applyInventoryProjection(binding: LedgerInventoryProjectionBinding, request: Data, payload: Data,
                                         expectedRevision: Int64, savedAt: Date) throws -> LedgerInventoryProjectionReceipt {
        try validateInventoryProjectionInput(binding, request: request)
        guard payload.count <= Self.maximumPayloadBytes else { throw LedgerStoreError.payloadTooLarge }
        guard expectedRevision >= 0, savedAt.timeIntervalSinceReferenceDate.isFinite else { throw LedgerStoreError.invalidInput }
        let requestDigest = Data(SHA256.hash(data: request)), payloadDigest = Data(SHA256.hash(data: payload))
        return try database.transaction {
            try requireInventoryProjectionOrigin(binding)
            // This precedes stale-base validation: a committed projection may have been followed by unrelated edits or deletion.
            if let prior = try database.inventoryProjectionReceipt(binding.projectionID) {
                guard prior.binding == binding, prior.requestDigest == requestDigest,
                      prior.baseRevision == expectedRevision, prior.payloadDigest == payloadDigest else { throw LedgerStoreError.operationConflict }
                return prior
            }
            guard try !database.hasSaveOperation(binding.projectionID),
                  try !database.hasInventoryProjectionBinding(binding) else { throw LedgerStoreError.operationConflict }
            _ = try saveSnapshot(payload: payload, expectedRevision: expectedRevision, operationID: binding.projectionID, savedAt: savedAt)
            try database.run("""
                INSERT INTO ledger_inventory_projections
                (projection_id,ledger_workspace_id,inventory_workspace_id,inventory_operation_id,kind,target_id,request_digest)
                VALUES (?,?,?,?,?,?,?)
                """, [.text(binding.projectionID.uuidString), .text(binding.ledgerWorkspaceID.uuidString),
                    .text(binding.inventoryWorkspaceID.uuidString), .text(binding.inventoryOperationID.uuidString),
                    .text(binding.kind), .text(binding.targetID.uuidString), .blob(requestDigest)])
            guard let receipt = try database.inventoryProjectionReceipt(binding.projectionID) else { throw LedgerStoreError.corruptRecord }
            return receipt
        }
    }

    private func validateInventoryProjectionInput(_ binding: LedgerInventoryProjectionBinding, request: Data) throws {
        guard inventoryProjectionsEnabled else { throw LedgerStoreError.inventoryProjectionDisabled }
        guard validInventoryProjectionKind(binding.kind), !request.isEmpty,
              request.count <= Self.maximumInventoryProjectionRequestBytes else { throw LedgerStoreError.invalidInput }
    }

    private func requireInventoryProjectionOrigin(_ binding: LedgerInventoryProjectionBinding) throws {
        guard try !database.isRetiredWorkspace(binding.ledgerWorkspaceID),
              try !database.isRetiredWorkspace(workspaceID),
              try !database.isRetiredOperation(binding.projectionID) else { throw LedgerStoreError.erased }
        guard binding.ledgerWorkspaceID == workspaceID else { throw LedgerStoreError.invalidInput }
        guard try database.workspace().id == workspaceID else { throw LedgerStoreError.corruptRecord }
        guard try database.tombstones("WHERE operation_id = ?", values: [.text(binding.projectionID.uuidString)]).isEmpty else {
            throw LedgerStoreError.operationConflict
        }
    }
}

private func validInventoryProjectionKind(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard (1...64).contains(bytes.count), let first = bytes.first,
          (65...90).contains(first) || (97...122).contains(first) else { return false }
    return bytes.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 58, 95].contains($0) }
}

extension LedgerDatabase {
    func migrateInventoryProjections() throws {
        try transaction {
            let version = try integer("PRAGMA user_version")
            if version == 3 { try validate(version: 3); return }
            guard version == 2 else { throw LedgerStoreError.unsupportedSchema(version) }
            try validate(version: 2)
            try execute("""
                CREATE TABLE ledger_inventory_projections (
                    projection_id TEXT PRIMARY KEY NOT NULL REFERENCES ledger_revisions(operation_id)
                        CHECK(typeof(projection_id) = 'text' AND length(projection_id) = 36),
                    ledger_workspace_id TEXT NOT NULL REFERENCES ledger_workspace(id),
                    inventory_workspace_id TEXT NOT NULL CHECK(typeof(inventory_workspace_id) = 'text' AND length(inventory_workspace_id) = 36),
                    inventory_operation_id TEXT NOT NULL CHECK(typeof(inventory_operation_id) = 'text' AND length(inventory_operation_id) = 36),
                    kind TEXT NOT NULL CHECK(typeof(kind) = 'text' AND length(kind) BETWEEN 1 AND 64),
                    target_id TEXT NOT NULL CHECK(typeof(target_id) = 'text' AND length(target_id) = 36),
                    request_digest BLOB NOT NULL CHECK(typeof(request_digest) = 'blob' AND length(request_digest) = 32),
                    UNIQUE(ledger_workspace_id,inventory_workspace_id,inventory_operation_id,kind,target_id)
                );
                CREATE TRIGGER ledger_projection_requires_snapshot BEFORE INSERT ON ledger_inventory_projections
                WHEN NOT EXISTS (SELECT 1 FROM ledger_revisions WHERE operation_id = NEW.projection_id AND workspace_id = NEW.ledger_workspace_id)
                    OR EXISTS (SELECT 1 FROM ledger_workspace_tombstones WHERE workspace_id = NEW.ledger_workspace_id)
                    OR EXISTS (SELECT 1 FROM ledger_retired_operations WHERE operation_id = NEW.projection_id)
                BEGIN SELECT RAISE(ABORT, 'projection snapshot required'); END;
                CREATE TRIGGER ledger_projection_immutable_update BEFORE UPDATE ON ledger_inventory_projections
                BEGIN SELECT RAISE(ABORT, 'immutable projection binding'); END;
                CREATE TRIGGER ledger_projection_erase_only BEFORE DELETE ON ledger_inventory_projections
                WHEN NOT EXISTS (
                    SELECT 1 FROM ledger_workspace_tombstones t JOIN ledger_retired_operations o ON o.workspace_id = t.workspace_id
                    WHERE t.workspace_id = OLD.ledger_workspace_id AND o.operation_id = OLD.projection_id
                )
                BEGIN SELECT RAISE(ABORT, 'projection retirement required'); END;
                PRAGMA user_version = 3;
                """)
            try validate(version: 3)
        }
    }

    func hasInventoryProjectionOperation(_ id: UUID) throws -> Bool {
        guard try integer("PRAGMA user_version") >= 3 else { return false }
        return try exists("SELECT 1 FROM ledger_inventory_projections WHERE projection_id = ?", values: [.text(id.uuidString)])
    }

    func hasInventoryProjectionBinding(_ binding: LedgerInventoryProjectionBinding) throws -> Bool {
        try exists("""
            SELECT 1 FROM ledger_inventory_projections WHERE ledger_workspace_id = ? AND inventory_workspace_id = ?
                AND inventory_operation_id = ? AND kind = ? AND target_id = ?
            """, values: [.text(binding.ledgerWorkspaceID.uuidString), .text(binding.inventoryWorkspaceID.uuidString),
                .text(binding.inventoryOperationID.uuidString), .text(binding.kind), .text(binding.targetID.uuidString)])
    }

    func inventoryProjectionReceipt(_ id: UUID) throws -> LedgerInventoryProjectionReceipt? {
        let row = try statement(Self.inventoryProjectionSelect + " WHERE p.projection_id = ?", values: [.text(id.uuidString)])
        defer { sqlite3_finalize(row) }
        let status = sqlite3_step(row)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw LedgerStoreError.database(status) }
        let receipt = try decodeInventoryProjection(row)
        guard sqlite3_step(row) == SQLITE_DONE else { throw LedgerStoreError.corruptRecord }
        return receipt
    }

    func validateInventoryProjectionSchema() throws {
        guard try integer("SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'ledger_inventory_projections'") == 1 else { throw LedgerStoreError.corruptRecord }
        for trigger in ["ledger_projection_requires_snapshot", "ledger_projection_immutable_update", "ledger_projection_erase_only"] {
            guard try integer("SELECT count(*) FROM sqlite_master WHERE type = 'trigger' AND name = '\(trigger)'") == 1 else { throw LedgerStoreError.corruptRecord }
        }
        let rows = try statement(Self.inventoryProjectionSelect)
        defer { sqlite3_finalize(rows) }
        while true {
            let status = sqlite3_step(rows)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else { throw LedgerStoreError.database(status) }
            _ = try decodeInventoryProjection(rows)
        }
    }

    private static let inventoryProjectionSelect = """
        SELECT p.ledger_workspace_id,p.projection_id,p.inventory_workspace_id,p.inventory_operation_id,p.kind,p.target_id,p.request_digest,
               r.workspace_id,r.base_revision,r.revision,r.payload_sha256,r.saved_at
        FROM ledger_inventory_projections p LEFT JOIN ledger_revisions r ON r.operation_id = p.projection_id
        """

    private func decodeInventoryProjection(_ row: OpaquePointer) throws -> LedgerInventoryProjectionReceipt {
        func uuid(_ column: Int32) throws -> UUID {
            let literal = try text(row, column)
            guard let id = UUID(uuidString: literal), id.uuidString == literal else { throw LedgerStoreError.corruptRecord }
            return id
        }
        let ledger = try uuid(0), projection = try uuid(1), inventory = try uuid(2), operation = try uuid(3)
        let kind = try text(row, 4), target = try uuid(5)
        let requestDigest = try blob(row, 6, limit: 32), payloadDigest = try blob(row, 10, limit: 32)
        guard validInventoryProjectionKind(kind), requestDigest.count == 32, payloadDigest.count == 32,
              try text(row, 7) == ledger.uuidString, sqlite3_column_type(row, 8) == SQLITE_INTEGER,
              sqlite3_column_type(row, 9) == SQLITE_INTEGER, [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(row, 11)) else { throw LedgerStoreError.corruptRecord }
        let base = sqlite3_column_int64(row, 8), revision = sqlite3_column_int64(row, 9), savedAt = sqlite3_column_double(row, 11)
        guard base >= 0, base < Int64.max, revision == base + 1, savedAt.isFinite else { throw LedgerStoreError.corruptRecord }
        return LedgerInventoryProjectionReceipt(binding: .init(ledgerWorkspaceID: ledger, projectionID: projection,
            inventoryWorkspaceID: inventory, inventoryOperationID: operation, kind: kind, targetID: target),
            requestDigest: requestDigest, baseRevision: base, revision: revision, payloadDigest: payloadDigest,
            savedAt: Date(timeIntervalSinceReferenceDate: savedAt))
    }
}
