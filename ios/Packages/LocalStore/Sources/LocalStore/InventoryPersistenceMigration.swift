import Foundation
import CryptoKit
import CSQLite

public struct InventoryMigrationChunk: Codable, Equatable, Sendable {
    public let index: Int
    public let records: [InventoryRecord]
    public init(index: Int, records: [InventoryRecord]) { self.index = index; self.records = records }
}

/// Review metadata is bounded; the manifest describes arbitrarily many bounded chunks without
/// concatenating their payloads. Version one uses sorted-key JSON and a domain-separated hash chain.
public enum InventoryMigrationManifest {
    public static var initialDigest: Data { inventoryDigest(Data("inventory-migration-manifest:v1".utf8)) }
    public static func appending(_ chunk: InventoryMigrationChunk, to previous: Data) throws -> Data {
        guard previous.count == 32 else { throw ComparisonStoreError.invalidInput }
        try validateInventoryMigrationChunk(chunk)
        return inventoryDigest(previous + inventoryDigest(try inventoryCanonical(chunk)))
    }
}

public struct InventoryMigrationPlan: Codable, Equatable, Sendable {
    public let version: Int
    public let migrationID: UUID
    public let workspaceID: UUID
    public let expectedRevision: Int64
    public let sourceToken: InventorySourceToken
    public let reviewContext: Data
    public let expectedChunkCount: Int
    public let expectedRecordCount: Int
    public let manifestDigest: Data
    public init(migrationID: UUID, workspaceID: UUID, expectedRevision: Int64, sourceToken: InventorySourceToken,
                reviewContext: Data, expectedChunkCount: Int, expectedRecordCount: Int, manifestDigest: Data) {
        version = 1; self.migrationID = migrationID; self.workspaceID = workspaceID; self.expectedRevision = expectedRevision
        self.sourceToken = sourceToken; self.reviewContext = reviewContext; self.expectedChunkCount = expectedChunkCount
        self.expectedRecordCount = expectedRecordCount; self.manifestDigest = manifestDigest
    }
}

public struct InventoryMigrationProgress: Equatable, Sendable {
    public enum Status: String, Sendable { case staging, active, cancelled }
    public let migrationID: UUID
    public let status: Status
    public let nextChunk: Int
    public let stagedRecordCount: Int
    /// Context is removed on cancellation/completion; it is never authoritative food.
    public let plan: InventoryMigrationPlan?
    public let receipt: InventoryOperationReceipt?
}

func validateInventoryMigrationChunk(_ chunk: InventoryMigrationChunk) throws {
    guard chunk.index >= 0, chunk.index < 1_000_000,
          !chunk.records.isEmpty, chunk.records.count <= InventoryPersistenceLimits.batchItems,
          Set(chunk.records.map(\.key)).count == chunk.records.count else { throw ComparisonStoreError.invalidInput }
    var raw = 0
    for record in chunk.records {
        // Original chronology belongs in provenance. Never fabricate missing SQL revision history.
        guard record.revision == 1, (1...10_000).contains(record.payloadVersion),
              !record.payload.isEmpty, record.payload.count <= InventoryPersistenceLimits.recordBytes,
              (!record.key.kind.requiresLot || record.lotID != nil), (record.key.kind.permitsLot || record.lotID == nil),
              (record.key.kind == .sourceLink) == (record.source != nil) else { throw ComparisonStoreError.invalidInput }
        if let source = record.source {
            guard !source.sourceID.isEmpty, source.sourceID.utf8.count <= 256,
                  !source.sourceID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ComparisonStoreError.invalidInput }
        }
        raw += record.payload.count + (record.source?.sourceID.utf8.count ?? 0)
        guard raw <= InventoryPersistenceLimits.batchBytes else { throw ComparisonStoreError.payloadTooLarge }
    }
    guard try inventoryCanonical(chunk).count <= InventoryPersistenceLimits.batchBytes else { throw ComparisonStoreError.payloadTooLarge }
}

extension ComparisonStore {
    /// Payload-free proof that this exact migration activated this physical
    /// database. Unlike replay/progress, later key erasure does not hide it.
    /// This does not authorize reading or restoring any imported record.
    public func inventoryMigrationActivation(_ expected: InventoryMigrationPlan) throws -> InventoryOperationReceipt? {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        guard expected.version == 1, expected.workspaceID == workspaceID,
              expected.expectedRevision >= 0, expected.expectedRevision < Int64.max,
              expected.sourceToken.workspaceID == workspaceID,
              expected.sourceToken.digest.count == 32, expected.sourceToken.generation >= 0,
              !expected.reviewContext.isEmpty, expected.reviewContext.count <= InventoryPersistenceLimits.requestBytes,
              (0...1_000_000).contains(expected.expectedChunkCount),
              (0...256_000_000).contains(expected.expectedRecordCount),
              expected.expectedRecordCount >= expected.expectedChunkCount,
              expected.expectedRecordCount <= expected.expectedChunkCount * InventoryPersistenceLimits.batchItems,
              expected.manifestDigest.count == 32 else { throw ComparisonStoreError.invalidInput }
        let digest = inventoryDigest(try inventoryCanonical(expected))
        return try database.transaction(immediate: false) {
            guard let header = try database.migrationHeader(expected.migrationID) else { return nil }
            guard header.digest == digest else { throw ComparisonStoreError.operationConflict }
            guard header.status == .active else { return nil }
            guard header.nextChunk == expected.expectedChunkCount, header.recordCount == expected.expectedRecordCount,
                  header.chainDigest == expected.manifestDigest,
                  let stored = try database.inventoryReceipt(expected.migrationID),
                  stored.digest == digest, stored.requestDigest == digest else { throw ComparisonStoreError.corruptRecord }
            let receipt = stored.receipt, state = try database.inventoryState(workspaceID: workspaceID)
            guard state.active, state.revision >= receipt.revision,
                  receipt.workspaceID == workspaceID, receipt.operationID == expected.migrationID,
                  receipt.migrationID == expected.migrationID, receipt.revision == expected.expectedRevision + 1,
                  receipt.heads.isEmpty, receipt.comparisonHeads.isEmpty,
                  receipt.committedAt.timeIntervalSinceReferenceDate.isFinite else { throw ComparisonStoreError.corruptRecord }
            return receipt
        }
    }

    @discardableResult
    public func beginInventoryMigration(_ plan: InventoryMigrationPlan) throws -> InventoryMigrationProgress {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        guard plan.version == 1, plan.workspaceID == workspaceID, plan.expectedRevision >= 0,
              plan.sourceToken.workspaceID == workspaceID, plan.sourceToken.generation >= 0, plan.sourceToken.digest.count == 32,
              !plan.reviewContext.isEmpty, plan.reviewContext.count <= InventoryPersistenceLimits.requestBytes,
              (0...1_000_000).contains(plan.expectedChunkCount), (0...256_000_000).contains(plan.expectedRecordCount),
              plan.expectedRecordCount >= plan.expectedChunkCount,
              plan.expectedRecordCount <= plan.expectedChunkCount * InventoryPersistenceLimits.batchItems,
              plan.manifestDigest.count == 32 else { throw ComparisonStoreError.invalidInput }
        let bytes = try inventoryCanonical(plan), digest = inventoryDigest(bytes)
        return try database.transaction {
            if let previous = try database.migrationHeader(plan.migrationID) {
                guard previous.digest == digest else { throw ComparisonStoreError.operationConflict }
                // A retired ID remains retired even if source conditions later become similar.
                return try migrationProgress(previous)
            }
            guard try database.inventoryReceipt(plan.migrationID) == nil,
                  try database.tombstones("WHERE operation_id = ?", values: [.text(plan.migrationID.uuidString)]).isEmpty else { throw ComparisonStoreError.operationConflict }
            let state = try database.inventoryState(workspaceID: workspaceID)
            guard !state.active, state.revision == plan.expectedRevision, try !database.hasStagingMigration(),
                  plan.sourceToken == (try database.inventorySourceToken(workspaceID: workspaceID)) else { throw ComparisonStoreError.staleInventory }
            try database.run("INSERT INTO inventory_migrations (id,digest,plan,status,next_chunk,record_count,chain_digest) VALUES (?,?,?,'staging',0,0,?)",
                [.text(plan.migrationID.uuidString), .blob(digest), .blob(bytes), .blob(InventoryMigrationManifest.initialDigest)])
            // Source identity manifest only, never copied comparison payloads. It supports retirement checks after activation.
            try database.run("INSERT INTO inventory_migration_sources (migration_id,comparison_id,revision) SELECT ?,id,head_revision FROM comparisons",
                [.text(plan.migrationID.uuidString)])
            guard let header = try database.migrationHeader(plan.migrationID) else { throw ComparisonStoreError.corruptRecord }
            return try migrationProgress(header)
        }
    }

    public func inventoryMigrationProgress(id: UUID) throws -> InventoryMigrationProgress? {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        return try database.transaction(immediate: false) {
            guard let header = try database.migrationHeader(id) else { return nil }
            return try migrationProgress(header)
        }
    }

    /// Discovers the durable reviewed plan after restart, including stale plans that may need cancellation.
    /// Staged records remain hidden from physical inventory until verified activation.
    public func inventoryPendingMigration() throws -> InventoryMigrationProgress? {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        return try database.transaction(immediate: false) {
            let row = try database.statement("SELECT id FROM inventory_migrations WHERE status = 'staging' LIMIT 2")
            defer { sqlite3_finalize(row) }
            let first = sqlite3_step(row)
            if first == SQLITE_DONE { return nil }
            guard first == SQLITE_ROW else { throw ComparisonStoreError.database(first) }
            let rawID = try database.text(row, column: 0)
            guard let id = UUID(uuidString: rawID), id.uuidString == rawID else { throw ComparisonStoreError.corruptRecord }
            let next = sqlite3_step(row)
            guard next != SQLITE_ROW else { throw ComparisonStoreError.corruptRecord }
            guard next == SQLITE_DONE else { throw ComparisonStoreError.database(next) }
            guard let header = try database.migrationHeader(id), header.status == .staging, header.plan != nil else {
                throw ComparisonStoreError.corruptRecord
            }
            return try migrationProgress(header)
        }
    }

    @discardableResult
    public func stageInventoryMigration(id: UUID, chunk: InventoryMigrationChunk) throws -> InventoryMigrationProgress {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try validateInventoryMigrationChunk(chunk)
        let digest = inventoryDigest(try inventoryCanonical(chunk))
        return try database.transaction {
            guard let header = try database.migrationHeader(id) else { throw ComparisonStoreError.notFound }
            let previousDigest = try database.migrationChunkDigest(id, index: chunk.index)
            if let prior = previousDigest {
                guard prior == digest else { throw ComparisonStoreError.operationConflict }
                if header.status == .active { return try migrationProgress(header) }
            }
            guard header.status == .staging, let plan = header.plan else { throw ComparisonStoreError.staleInventory }
            try validateStagingPlan(plan)
            if previousDigest != nil { return try migrationProgress(header) }
            guard chunk.index == header.nextChunk, chunk.index < plan.expectedChunkCount,
                  header.recordCount + chunk.records.count <= plan.expectedRecordCount else { throw ComparisonStoreError.staleInventory }
            for (ordinal, record) in chunk.records.enumerated() {
                if try database.inventoryErased(record.key) { throw ComparisonStoreError.erased }
                try database.run("INSERT INTO inventory_staged_records (migration_id,kind,id,chunk_index,record_ordinal,source_origin,source_id,record) VALUES (?,?,?,?,?,?,?,?)",
                    [.text(id.uuidString), .text(record.key.kind.rawValue), .text(record.key.id.uuidString),
                     .integer(Int64(chunk.index)), .integer(Int64(ordinal)), record.source.map { .text($0.originID.uuidString) } ?? .null, record.source.map { .text($0.sourceID) } ?? .null,
                     .blob(try inventoryCanonical(record))])
            }
            try database.run("INSERT INTO inventory_migration_chunks (migration_id,chunk_index,digest,record_count) VALUES (?,?,?,?)",
                [.text(id.uuidString), .integer(Int64(chunk.index)), .blob(digest), .integer(Int64(chunk.records.count))])
            try database.run("UPDATE inventory_migrations SET next_chunk = ?, record_count = ?, chain_digest = ? WHERE id = ?",
                [.integer(Int64(header.nextChunk + 1)), .integer(Int64(header.recordCount + chunk.records.count)),
                 .blob(inventoryDigest(header.chainDigest + digest)), .text(id.uuidString)])
            guard let updated = try database.migrationHeader(id) else { throw ComparisonStoreError.corruptRecord }
            return try migrationProgress(updated)
        }
    }

    @discardableResult
    public func finishInventoryMigration(id: UUID, at date: Date = Date()) throws -> InventoryOperationReceipt {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw ComparisonStoreError.invalidInput }
        return try database.transaction {
            guard let header = try database.migrationHeader(id) else { throw ComparisonStoreError.notFound }
            if header.status == .active {
                guard let prior = try database.inventoryReceipt(id), prior.digest == header.digest else { throw ComparisonStoreError.corruptRecord }
                try validateInventoryReceiptAccess(prior.receipt)
                return prior.receipt
            }
            guard header.status == .staging, let plan = header.plan else { throw ComparisonStoreError.staleInventory }
            try validateStagingPlan(plan)
            guard header.nextChunk == plan.expectedChunkCount, header.recordCount == plan.expectedRecordCount,
                  header.chainDigest == plan.manifestDigest,
                  plan.sourceToken == (try database.inventorySourceToken(workspaceID: workspaceID)),
                  plan.expectedRevision < Int64.max else { throw ComparisonStoreError.staleInventory }
            try database.validateStagedManifest(header)
            // Every source has been reviewed before this point. Copy in bounded pages inside ONE transaction.
            for kind in InventoryRecordKind.allCases { // lot is first; other FK checks are deferred until COMMIT.
                var after: UUID?
                while true {
                    let records = try database.stagedRecords(id, kind: kind, after: after)
                    if records.isEmpty { break }
                    for record in records {
                        try database.writeInventory(.init(record: record, expectedRevision: 0))
                        try database.run("INSERT INTO inventory_migration_keys (migration_id,kind,id) VALUES (?,?,?)",
                            [.text(id.uuidString), .text(kind.rawValue), .text(record.key.id.uuidString)])
                    }
                    after = records.last?.key.id
                }
            }
            let receipt = InventoryOperationReceipt(workspaceID: workspaceID, operationID: id, revision: plan.expectedRevision + 1,
                heads: [], comparisonHeads: [:], committedAt: date, migrationID: id)
            try database.run("INSERT INTO inventory_operations (id,digest,request_digest,receipt) VALUES (?,?,?,?)",
                [.text(id.uuidString), .blob(header.digest), .blob(header.digest), .blob(try inventoryCanonical(receipt))])
            try database.run("UPDATE inventory_state SET revision = ?, active = 1 WHERE singleton = 1", [.integer(receipt.revision)])
            try database.run("UPDATE inventory_migrations SET status = 'active', plan = NULL WHERE id = ?", [.text(id.uuidString)])
            try database.run("DELETE FROM inventory_staged_records WHERE migration_id = ?", [.text(id.uuidString)])
            return receipt
        }
    }

    @discardableResult
    public func cancelInventoryMigration(id: UUID) throws -> InventoryMigrationProgress {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        let result = try database.transaction {
            guard let header = try database.migrationHeader(id) else { throw ComparisonStoreError.notFound }
            guard header.status != .active else { throw ComparisonStoreError.inventoryRequired }
            if header.status == .cancelled { return try migrationProgress(header) }
            // Source mutations do not prevent cancellation; cancellation never touches original comparisons or canonical food.
            try database.run("UPDATE inventory_migrations SET status = 'cancelled', plan = NULL WHERE id = ?", [.text(id.uuidString)])
            try database.run("DELETE FROM inventory_staged_records WHERE migration_id = ?", [.text(id.uuidString)])
            try database.run("DELETE FROM inventory_migration_sources WHERE migration_id = ?", [.text(id.uuidString)])
            guard let cancelled = try database.migrationHeader(id) else { throw ComparisonStoreError.corruptRecord }
            return try migrationProgress(cancelled)
        }
        database.checkpointAfterErasure()
        return result
    }

    private func validateStagingPlan(_ plan: InventoryMigrationPlan) throws {
        let state = try database.inventoryState(workspaceID: workspaceID)
        guard plan.workspaceID == workspaceID, !state.active, state.revision == plan.expectedRevision,
              plan.sourceToken.generation == (try database.integer("SELECT source_generation FROM inventory_state WHERE singleton = 1")) else {
            throw ComparisonStoreError.staleInventory
        }
    }

    private func migrationProgress(_ header: InventoryMigrationHeader) throws -> InventoryMigrationProgress {
        var receipt: InventoryOperationReceipt?
        if header.status == .active {
            guard let found = try database.inventoryReceipt(header.id) else { throw ComparisonStoreError.corruptRecord }
            try validateInventoryReceiptAccess(found.receipt); receipt = found.receipt
        }
        return InventoryMigrationProgress(migrationID: header.id, status: header.status, nextChunk: header.nextChunk,
            stagedRecordCount: header.recordCount, plan: header.plan, receipt: receipt)
    }
}
