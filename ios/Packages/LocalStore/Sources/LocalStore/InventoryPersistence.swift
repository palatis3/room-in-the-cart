import Foundation
import CryptoKit

/// Persistence owns identity, revisions and atomicity. The app adapter owns food/unit validation.
public enum InventoryRecordKind: String, Codable, Sendable, CaseIterable {
    case lot, observation, event, reservation, sourceLink, intent
    var appendOnly: Bool { self == .observation || self == .event || self == .sourceLink }
    var requiresLot: Bool { self == .observation || self == .event || self == .sourceLink }
    var permitsLot: Bool { requiresLot || self == .reservation }
}

public struct InventoryRecordKey: Codable, Hashable, Sendable {
    public let kind: InventoryRecordKind
    public let id: UUID
    public init(_ kind: InventoryRecordKind, _ id: UUID) { self.kind = kind; self.id = id }
}

/// A canonical source address, never a food label or a caller-supplied authority grant.
public struct InventorySourceIdentity: Codable, Equatable, Sendable {
    public let originID: UUID
    public let sourceID: String
    public init(originID: UUID, sourceID: String) { self.originID = originID; self.sourceID = sourceID }
}

public struct InventoryRecord: Codable, Equatable, Sendable {
    public let key: InventoryRecordKey
    public let revision: Int64
    public let payloadVersion: Int
    public let payload: Data
    public let lotID: UUID?
    public let source: InventorySourceIdentity?
    public init(key: InventoryRecordKey, revision: Int64, payloadVersion: Int = 1, payload: Data,
                lotID: UUID? = nil, source: InventorySourceIdentity? = nil) {
        self.key = key; self.revision = revision; self.payloadVersion = payloadVersion
        self.payload = payload; self.lotID = lotID; self.source = source
    }
}

public struct InventoryWrite: Codable, Equatable, Sendable {
    public let record: InventoryRecord
    public let expectedRevision: Int64
    public init(record: InventoryRecord, expectedRevision: Int64) {
        self.record = record; self.expectedRevision = expectedRevision
    }
}

public struct InventoryErase: Codable, Equatable, Sendable {
    public let key: InventoryRecordKey
    public let expectedRevision: Int64
    public init(key: InventoryRecordKey, expectedRevision: Int64) { self.key = key; self.expectedRevision = expectedRevision }
}

public struct InventoryComparisonEffect: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case save, erase }
    public let action: Action
    public let id: UUID
    public let expectedRevision: Int64
    public let title: String
    public let payload: Data
    public init(action: Action, id: UUID, expectedRevision: Int64, title: String = "", payload: Data = Data()) {
        self.action = action; self.id = id; self.expectedRevision = expectedRevision; self.title = title; self.payload = payload
    }
}

/// The digest covers the COMPLETE live source heads and tombstones, not a caller-selected subset.
/// Generation also detects an inserted-and-erased source between review and activation.
public struct InventorySourceToken: Codable, Equatable, Sendable {
    public let workspaceID: UUID
    public let generation: Int64
    public let digest: Data
    public init(workspaceID: UUID, generation: Int64, digest: Data) {
        self.workspaceID = workspaceID; self.generation = generation; self.digest = digest
    }
}

public struct InventoryCutoverSnapshot: Sendable {
    public let token: InventorySourceToken
    public let sources: [SavedComparison]
    public let tombstones: [ComparisonTombstone]
}

public struct InventoryState: Equatable, Sendable, Codable {
    public let workspaceID: UUID
    public let revision: Int64
    public let active: Bool
}

public struct InventoryBatch: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case prepare, activate, mutate }
    public let workspaceID: UUID
    public let operationID: UUID
    public let expectedRevision: Int64
    public let mode: Mode
    public let request: Data
    public let sourceToken: InventorySourceToken?
    public let writes: [InventoryWrite]
    public let erasures: [InventoryErase]
    public let comparisons: [InventoryComparisonEffect]
    public let reviewedReceipt: ReviewedPutawayReceipt?
    public let price: InventoryPriceRow?
    public let receiptBindings: [InventoryReceiptBinding]?
    public let aliasEdit: InventoryReceiptAliasEdit?
    public let acquisitions: [InventoryAcquisitionRow]?
    public init(workspaceID: UUID, operationID: UUID, expectedRevision: Int64, request: Data, mode: Mode = .mutate,
                sourceToken: InventorySourceToken? = nil, writes: [InventoryWrite] = [],
                erasures: [InventoryErase] = [], comparisons: [InventoryComparisonEffect] = [], acquisitions: [InventoryAcquisitionRow] = [],
                aliasEdit: InventoryReceiptAliasEdit? = nil, price: InventoryPriceRow? = nil, receiptBindings: [InventoryReceiptBinding] = [], reviewedReceipt: ReviewedPutawayReceipt? = nil) {
        self.workspaceID = workspaceID; self.operationID = operationID; self.expectedRevision = expectedRevision
        self.mode = mode; self.request = request; self.sourceToken = sourceToken; self.writes = writes; self.erasures = erasures; self.comparisons = comparisons
        self.reviewedReceipt = reviewedReceipt
        self.price = price
        self.receiptBindings = receiptBindings.isEmpty ? nil : receiptBindings
        self.aliasEdit = aliasEdit
        self.acquisitions = acquisitions.isEmpty ? nil : acquisitions
    }
}

public struct InventoryHead: Codable, Equatable, Sendable {
    public let key: InventoryRecordKey
    /// Zero in an operation receipt denotes an erased head, not an empty quantity.
    public let revision: Int64
}

public struct InventoryOperationReceipt: Codable, Equatable, Sendable {
    public let workspaceID: UUID
    public let operationID: UUID
    public let revision: Int64
    public let heads: [InventoryHead]
    public let comparisonHeads: [UUID: Int64]
    public let committedAt: Date
    public let migrationID: UUID?
    public internal(set) var acquisitionLotIDs: [UUID]? = nil
}

public enum InventoryPersistenceLimits {
    public static let requestBytes = 65_536
    public static let recordBytes = 65_536
    public static let batchBytes = 1_500_000
    public static let batchItems = 256
    public static let pageItems = 200
}

func inventoryCanonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

func inventoryDigest(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }

extension ComparisonStore {
    public func inventoryState() throws -> InventoryState {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.requireInventoryOriginLive()
        return try database.inventoryState(workspaceID: workspaceID)
    }

    public func inventorySourceToken() throws -> InventorySourceToken {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.requireInventoryOriginLive()
        return try database.transaction(immediate: false) { try database.inventorySourceToken(workspaceID: workspaceID) }
    }

    /// Payload pages for a reviewed token. A changed source generation invalidates the entire read.
    public func inventorySourcePage(token: InventorySourceToken, after: UUID? = nil, limit: Int = 100) throws -> [SavedComparison] {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.requireInventoryOriginLive()
        guard (1...InventoryPersistenceLimits.pageItems).contains(limit) else { throw ComparisonStoreError.invalidInput }
        return try database.transaction(immediate: false) {
            guard token == (try database.inventorySourceToken(workspaceID: workspaceID)) else { throw ComparisonStoreError.staleInventory }
            var query = Self.select
            var values: [ComparisonSQLValue] = []
            if let after { query += " WHERE c.id > ?"; values.append(.text(after.uuidString)) }
            query += " ORDER BY c.id LIMIT ?"; values.append(.integer(Int64(limit)))
            return try database.records(query, values: values)
        }
    }

    public func inventoryCutoverSnapshot() throws -> InventoryCutoverSnapshot {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.requireInventoryOriginLive()
        return try database.transaction(immediate: false) { try cutoverSnapshot() }
    }

    func cutoverSnapshot() throws -> InventoryCutoverSnapshot {
        let sources = try database.records(Self.select + " ORDER BY c.id", values: [])
        let tombstones = try database.tombstones("ORDER BY comparison_id", values: [])
        let token = try database.inventorySourceToken(workspaceID: workspaceID)
        return InventoryCutoverSnapshot(token: token, sources: sources, tombstones: tombstones)
    }

    public func inventoryRecord(_ key: InventoryRecordKey) throws -> InventoryRecord? {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.requireInventoryOriginLive()
        try requireInventoryReadable(key.kind)
        return try database.inventoryRecords(kind: key.kind, id: key.id).first
    }

    /// Stable UUID pagination. Callers must check inventory revision again when combining pages.
    public func inventoryRecords(kind: InventoryRecordKind, lotID: UUID? = nil, after: UUID? = nil, limit: Int = 100) throws -> [InventoryRecord] {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.requireInventoryOriginLive()
        guard (1...InventoryPersistenceLimits.pageItems).contains(limit) else { throw ComparisonStoreError.invalidInput }
        try requireInventoryReadable(kind)
        return try database.inventoryRecords(kind: kind, lotID: lotID, after: after, limit: limit)
    }

    private func requireInventoryReadable(_ kind: InventoryRecordKind) throws {
        if kind != .intent, try !database.inventoryState(workspaceID: workspaceID).active { throw ComparisonStoreError.inventoryInactive }
    }

    /// Look up exact original request identity before preparing against a newer domain head.
    /// The app must reauthorize its private workspace before calling; no payload is returned.
    public func inventoryCommittedOperation(id: UUID, request: Data) throws -> InventoryOperationReceipt? {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.requireInventoryOriginLive()
        guard !request.isEmpty, request.count <= InventoryPersistenceLimits.requestBytes else { throw ComparisonStoreError.invalidInput }
        return try database.transaction(immediate: false) {
            try database.requireInventoryOriginLive()
            guard try database.erasureProgress(id) == nil else { throw ComparisonStoreError.operationConflict }
            guard let prior = try database.inventoryReceipt(id) else { return nil }
            guard prior.requestDigest == inventoryDigest(request) else { throw ComparisonStoreError.operationConflict }
            try validateInventoryReceiptAccess(prior.receipt)
            return prior.receipt
        }
    }

    func validateInventoryReceiptAccess(_ receipt: InventoryOperationReceipt) throws {
        guard receipt.workspaceID == workspaceID else { throw ComparisonStoreError.corruptRecord }
        try database.requireInventoryOriginLive()
        if let migration = receipt.migrationID { try database.validateMigrationReceiptAccess(migration, receipt: receipt) }
        for id in receipt.acquisitionLotIDs ?? [] where try database.inventoryErased(.init(.lot, id)) { throw ComparisonStoreError.erased }
        for head in receipt.heads {
            let retiredBy = try database.inventoryRetirementOperation(head.key)
            if head.key.kind == .reservation, head.revision > 0, try database.reservationRedactionFloor(head.key.id) >= head.revision { throw ComparisonStoreError.erased }
            if head.revision == 0 {
                guard retiredBy == receipt.operationID else { throw ComparisonStoreError.erased }
            } else if retiredBy != nil { throw ComparisonStoreError.erased }
        }
        for (id, revision) in receipt.comparisonHeads {
            let retired = try database.tombstones("WHERE comparison_id = ?", values: [.text(id.uuidString)]).first
            if revision == 0 {
                guard retired?.operationID == inventoryComparisonErasureID(operation: receipt.operationID, source: id) else { throw ComparisonStoreError.erased }
            } else if retired != nil { throw ComparisonStoreError.erased }
        }
    }

    @discardableResult
    public func commitInventory(_ batch: InventoryBatch, at date: Date = Date()) throws -> InventoryOperationReceipt {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.requireInventoryOriginLive()
        try validateInventoryBatch(batch, date: date)
        let digest = inventoryDigest(try inventoryCanonical(batch))
        let requestDigest = inventoryDigest(batch.request)
        let receipt = try database.transaction {
            try database.requireInventoryOriginLive()
            guard try database.erasureProgress(batch.operationID) == nil else { throw ComparisonStoreError.operationConflict }
            // Retired identities win over old success receipts: an old operation cannot resurrect or reveal food.
            for write in batch.writes where try database.inventoryErased(write.record.key) { throw ComparisonStoreError.erased }
            for effect in batch.comparisons where effect.action == .save {
                if try isErased(id: effect.id) { throw ComparisonStoreError.erased }
            }
            if let price = batch.price, try database.priceWasErased(price.id) { throw ComparisonStoreError.erased }
            if let prior = try database.inventoryReceipt(batch.operationID) {
                guard prior.digest == digest, prior.requestDigest == requestDigest else { throw ComparisonStoreError.operationConflict }
                try validateInventoryReceiptAccess(prior.receipt)
                return prior.receipt
            }
            guard try database.tombstones("WHERE operation_id = ?", values: [.text(batch.operationID.uuidString)]).isEmpty else {
                throw ComparisonStoreError.operationConflict
            }
            let state = try database.inventoryState(workspaceID: workspaceID)
            guard state.revision == batch.expectedRevision, state.revision < Int64.max else { throw ComparisonStoreError.staleInventory }
            guard try !database.hasStagingMigration() else { throw ComparisonStoreError.staleInventory }
            switch batch.mode {
            case .prepare:
                guard !state.active else { throw ComparisonStoreError.staleInventory }
            case .activate:
                guard !state.active, batch.sourceToken == (try database.inventorySourceToken(workspaceID: workspaceID)) else { throw ComparisonStoreError.staleInventory }
            case .mutate:
                guard state.active else { throw ComparisonStoreError.inventoryInactive }
            }
            var heads: [InventoryHead] = []
            // Parent lots first; foreign keys validate the final transaction graph, independent of input order.
            for write in batch.writes.sorted(by: { $0.record.key.kind == .lot && $1.record.key.kind != .lot }) {
                try database.writeInventory(write)
                heads.append(InventoryHead(key: write.record.key, revision: write.record.revision))
            }
            for erase in batch.erasures {
                try database.eraseInventory(erase, operationID: batch.operationID)
                heads.append(InventoryHead(key: erase.key, revision: 0))
            }
            if let edit = batch.aliasEdit { try database.applyReceiptAlias(edit) }
            for row in batch.acquisitions ?? [] { try database.insertAcquisition(row) }
            for binding in batch.receiptBindings ?? [] { try database.bindReceipt(binding) }
            if let review = batch.reviewedReceipt { try database.savePutaway(review) }
            if let price = batch.price { try database.insertPrice(price) }
            var comparisonHeads: [UUID: Int64] = [:]
            for effect in batch.comparisons {
                let actual = try database.head(id: effect.id, workspaceID: workspaceID) ?? 0
                guard actual == effect.expectedRevision else { throw ComparisonStoreError.staleRevision(expected: effect.expectedRevision, actual: actual) }
                if effect.action == .save {
                    let saved = try saveComparison(id: effect.id, title: effect.title, payload: effect.payload,
                        savedAt: date, requiring: [effect.id: effect.expectedRevision])
                    comparisonHeads[effect.id] = saved.revision
                } else {
                    // Derive a distinct erasure receipt key; its source remains explicitly reviewed.
                    let erasureID = inventoryComparisonErasureID(operation: batch.operationID, source: effect.id)
                    _ = try eraseComparison(id: effect.id, expectedRevision: effect.expectedRevision, operationID: erasureID, at: date)
                    comparisonHeads[effect.id] = 0
                }
            }
            var receipt = InventoryOperationReceipt(workspaceID: workspaceID, operationID: batch.operationID,
                revision: state.revision + 1, heads: heads, comparisonHeads: comparisonHeads, committedAt: date, migrationID: nil)
            receipt.acquisitionLotIDs = batch.acquisitions.map { Array(Set($0.map(\.lotID))).sorted { $0.uuidString < $1.uuidString } }
            if let bindings = batch.receiptBindings {
                receipt.acquisitionLotIDs = Array(Set((receipt.acquisitionLotIDs ?? []) + bindings.map(\.lotID))).sorted { $0.uuidString < $1.uuidString }
            }
            if let lotID = batch.price?.lotID { receipt.acquisitionLotIDs = [lotID] }
            if case .remember(let alias) = batch.aliasEdit { receipt.acquisitionLotIDs = [alias.lotID] }
            try database.run("INSERT INTO inventory_operations (id, digest, request_digest, receipt) VALUES (?, ?, ?, ?)",
                [.text(batch.operationID.uuidString), .blob(digest), .blob(requestDigest), .blob(try inventoryCanonical(receipt))])
            try database.run("UPDATE inventory_state SET revision = ?, active = ? WHERE singleton = 1",
                [.integer(receipt.revision), .integer((state.active || batch.mode == .activate) ? 1 : 0)])
            return receipt
        }
        if batch.aliasEdit?.removesSpellings == true || !batch.erasures.isEmpty || batch.comparisons.contains(where: { $0.action == .erase }) {
            database.checkpointAfterErasure()
        }
        return receipt
    }

    private func validateInventoryBatch(_ batch: InventoryBatch, date: Date) throws {
        guard batch.workspaceID == workspaceID, batch.expectedRevision >= 0, date.timeIntervalSinceReferenceDate.isFinite,
              !batch.request.isEmpty, batch.request.count <= InventoryPersistenceLimits.requestBytes,
              batch.writes.count + batch.erasures.count + batch.comparisons.count + (batch.acquisitions?.count ?? 0) <= InventoryPersistenceLimits.batchItems,
              batch.mode == .activate || batch.reviewedReceipt != nil || batch.receiptBindings != nil || batch.price != nil || batch.aliasEdit != nil || batch.acquisitions?.isEmpty == false || !batch.writes.isEmpty || !batch.erasures.isEmpty || !batch.comparisons.isEmpty,
              (batch.mode == .activate) == (batch.sourceToken != nil),
              batch.sourceToken.map({ $0.workspaceID == workspaceID && $0.generation >= 0 && $0.digest.count == 32 }) ?? true,
              Set(batch.writes.map(\.record.key) + batch.erasures.map(\.key)).count == batch.writes.count + batch.erasures.count,
              Set(batch.comparisons.map(\.id)).count == batch.comparisons.count else { throw ComparisonStoreError.invalidInput }
        if batch.mode == .prepare {
            guard batch.writes.allSatisfy({ $0.record.key.kind == .intent }), batch.erasures.isEmpty, batch.comparisons.isEmpty else {
                throw ComparisonStoreError.invalidInput
            }
        }
        if let edit = batch.aliasEdit {
            guard batch.mode == .mutate, batch.writes.isEmpty, batch.erasures.isEmpty,
                  batch.comparisons.isEmpty, batch.acquisitions == nil else { throw ComparisonStoreError.invalidInput }
            try edit.validate()
        }
        if let price = batch.price {
            guard batch.mode == .mutate, batch.writes.isEmpty, batch.erasures.isEmpty,
                  batch.comparisons.isEmpty, batch.acquisitions == nil, batch.aliasEdit == nil else { throw ComparisonStoreError.invalidInput }
            guard price.revision > 0, !price.payload.isEmpty, price.payload.count <= InventoryPersistenceLimits.recordBytes else {
                throw ComparisonStoreError.invalidInput
            }
        }
        // Bindings annotate up to 50 reviewed lines. Charge their bytes separately so a full
        // 50-line receipt can still contain its 200 inventory writes and 50 acquisitions.
        if let bindings = batch.receiptBindings {
            guard (1...50).contains(bindings.count), batch.mode == .mutate, batch.price == nil, batch.aliasEdit == nil,
                  batch.erasures.isEmpty, batch.comparisons.isEmpty,
                  bindings.allSatisfy({ (0..<4000).contains($0.ordinal) && ($0.fileDigest.map { $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } } ?? true) }) else { throw ComparisonStoreError.invalidInput }
        }
        var rawBytes = batch.request.count + (batch.price?.payload.count ?? 0) + (batch.receiptBindings?.count ?? 0) * 300
        if let review = batch.reviewedReceipt {
            guard batch.mode == .mutate, batch.aliasEdit == nil, batch.price == nil, batch.erasures.isEmpty,
                  batch.comparisons.isEmpty else { throw ComparisonStoreError.invalidInput }
            try review.validate()
            rawBytes += try inventoryCanonical(review).count
            guard rawBytes <= InventoryPersistenceLimits.batchBytes else { throw ComparisonStoreError.payloadTooLarge }
        }
        if let rows = batch.acquisitions {
            guard !rows.isEmpty, batch.mode == .mutate, batch.erasures.isEmpty, batch.comparisons.isEmpty,
                  Set(rows.map(\.id)).count == rows.count else { throw ComparisonStoreError.invalidInput }
            for row in rows {
                guard !row.payload.isEmpty, row.payload.count <= InventoryPersistenceLimits.recordBytes,
                      row.revision > 0, (row.revision == 1) == (row.supersedesID == nil) else { throw ComparisonStoreError.invalidInput }
                rawBytes += row.payload.count
                guard rawBytes <= InventoryPersistenceLimits.batchBytes else { throw ComparisonStoreError.payloadTooLarge }
            }
        }
        for write in batch.writes {
            let record = write.record
            guard write.expectedRevision >= 0, write.expectedRevision < Int64.max, record.revision == write.expectedRevision + 1,
                  record.payloadVersion > 0, record.payloadVersion <= 10_000,
                  !record.payload.isEmpty, record.payload.count <= InventoryPersistenceLimits.recordBytes,
                  (!record.key.kind.requiresLot || record.lotID != nil),
                  (record.key.kind.permitsLot || record.lotID == nil),
                  (record.key.kind == .sourceLink) == (record.source != nil),
                  !record.key.kind.appendOnly || write.expectedRevision == 0 else { throw ComparisonStoreError.invalidInput }
            if let source = record.source {
                guard !source.sourceID.isEmpty, source.sourceID.utf8.count <= 256,
                      !source.sourceID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ComparisonStoreError.invalidInput }
            }
            rawBytes += record.payload.count + (record.source?.sourceID.utf8.count ?? 0)
            guard rawBytes <= InventoryPersistenceLimits.batchBytes else { throw ComparisonStoreError.payloadTooLarge }
        }
        guard batch.erasures.allSatisfy({ $0.expectedRevision > 0 }) else { throw ComparisonStoreError.invalidInput }
        for effect in batch.comparisons {
            guard effect.expectedRevision >= 0,
                  effect.action != .erase || (effect.expectedRevision > 0 && effect.title.isEmpty && effect.payload.isEmpty),
                  effect.title.utf8.count <= 4096, !effect.title.contains("\0"),
                  effect.payload.count <= Self.maximumPayloadBytes else { throw ComparisonStoreError.invalidInput }
            rawBytes += effect.payload.count + effect.title.utf8.count
            guard rawBytes <= InventoryPersistenceLimits.batchBytes else { throw ComparisonStoreError.payloadTooLarge }
        }
        guard try inventoryCanonical(batch).count <= InventoryPersistenceLimits.batchBytes else { throw ComparisonStoreError.payloadTooLarge }
    }
}

func inventoryComparisonErasureID(operation: UUID, source: UUID) -> UUID {
    let bytes = [UInt8](inventoryDigest(Data(("inventory-comparison-erasure:" + operation.uuidString + ":" + source.uuidString).utf8)).prefix(16))
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
}
