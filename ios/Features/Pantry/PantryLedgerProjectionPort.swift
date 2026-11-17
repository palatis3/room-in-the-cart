import Foundation
import CryptoKit
import CoreDomain
import LocalStore

/// Reads a bounded binding committed with the inventory fact. Completion is a separate intent marker.
@MainActor final class PantryLedgerProjectionPort {
    enum Failure: Error, Equatable {
        case unauthorized, wrongOrigin, missingInventoryOperation, missingLedgerHead, invalidBinding, needsReview
    }
    struct Source: Codable, Equatable, Sendable {
        let inventoryWorkspaceID: UUID
        let inventoryOperationID: UUID
        let inventoryRequest: Data
        let sourceIntentID: UUID
    }
    struct IntentBinding: Codable, Equatable, Sendable {
        let version: Int
        let binding: LedgerInventoryProjectionBinding
        let canonicalRequest: Data
        let requestDigest: Data
        let payloadDigest: Data
        let expectedRevision: Int64
        let savedAt: Date
    }
    struct ValidatedSource {
        let source: Source
        fileprivate let intent: IntentBinding
    }
    struct Current {
        let record: LedgerRecord?
        let workspace: LedgerWorkspace
    }
    enum Reconciliation {
        case applied(Result), needsReview(Current), sourceRetired(Current), ledgerRetired
    }
    struct ReviewDisposition: Codable, Equatable {
        let version: Int
        let sourceIntentID: UUID
        let bindingDigest: Data
        let decision: String
        let ledgerRevision: Int64
    }
    struct Result {
        let receipt: LedgerInventoryProjectionReceipt
        let current: LedgerRecord
        let workspace: LedgerWorkspace
        let replayed: Bool
    }
    var ledgerWorkspaceID: UUID { ledger.workspaceID }
    private let ledger: LedgerStore
    private let inventory: ComparisonStore
    private let gate: PantryMutationGate
    private let authorize: (UUID, UUID) -> Bool
    /// Checks the typed request and the current target against the reviewed candidate, only for a new application.
    private let validateNewProjection: @MainActor (IntentBinding, LedgerWorkspace, LedgerWorkspace) async throws -> Void

    init(ledger: LedgerStore, inventory: ComparisonStore, gate: PantryMutationGate,
         authorize: @escaping (UUID, UUID) -> Bool,
         validateNewProjection: @escaping @MainActor (IntentBinding, LedgerWorkspace, LedgerWorkspace) async throws -> Void) {
        self.ledger = ledger; self.inventory = inventory; self.gate = gate
        self.authorize = authorize; self.validateNewProjection = validateNewProjection
    }

    /// Store this immutable record in the SAME inventory operation as the fact being projected.
    /// The payload is hashed in memory; at most 32 KiB of reconstruction request is persisted here.
    nonisolated static func intentRecord(id: UUID, binding: LedgerInventoryProjectionBinding, canonicalRequest: Data,
                                         payload: Data, expectedRevision: Int64, savedAt: Date) throws -> InventoryRecord {
        _ = try LedgerModel.validatePayload(payload)
        let value = IntentBinding(version: 1, binding: binding, canonicalRequest: canonicalRequest,
            requestDigest: digest(canonicalRequest), payloadDigest: digest(payload), expectedRevision: expectedRevision, savedAt: savedAt)
        try validate(value)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(value)
        guard bytes.count <= InventoryPersistenceLimits.recordBytes else { throw Failure.invalidBinding }
        return InventoryRecord(key: .init(.intent, id), revision: 1, payloadVersion: 1, payload: bytes)
    }

    /// Typed archival evidence only. Neither reader recognizes a committed operation or grants replay authority.
    nonisolated static func archiveBinding(_ record: InventoryRecord) throws -> IntentBinding {
        guard record.key.kind == .intent, record.revision == 1, record.payloadVersion == 1,
              record.lotID == nil, record.source == nil, record.payload.count <= InventoryPersistenceLimits.recordBytes else { throw Failure.invalidBinding }
        let value = try JSONDecoder().decode(IntentBinding.self, from: record.payload)
        try validate(value)
        let kind = Array(value.binding.kind.utf8)
        guard (1...64).contains(kind.count), let first = kind.first,
              (65...90).contains(first) || (97...122).contains(first),
              kind.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,46,58,95].contains($0) }) else { throw Failure.invalidBinding }
        return value
    }
    nonisolated static func archiveDisposition(_ record: InventoryRecord, bindingRecord: InventoryRecord) throws -> ReviewDisposition {
        let intent = try archiveBinding(bindingRecord)
        let source = Source(inventoryWorkspaceID: intent.binding.inventoryWorkspaceID,
            inventoryOperationID: intent.binding.inventoryOperationID, inventoryRequest: Data(), sourceIntentID: bindingRecord.key.id)
        guard record.key == InventoryRecordKey(.intent, dispositionID(source)), record.revision == 1,
              record.payloadVersion == 1, record.lotID == nil, record.source == nil,
              record.payload.count <= InventoryPersistenceLimits.recordBytes else { throw Failure.invalidBinding }
        let value = try JSONDecoder().decode(ReviewDisposition.self, from: record.payload)
        guard value.version == 1, value.sourceIntentID == bindingRecord.key.id,
              value.bindingDigest == (try bindingDigest(intent)), value.decision == "needsReview", value.ledgerRevision >= 0 else { throw Failure.invalidBinding }
        return value
    }

    /// Read-only validation occurs before a model latches an attempted source as durable work.
    func preflight(_ source: Source) async throws -> ValidatedSource {
        try requireAccess(source)
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        let intent = try await boundIntent(source)
        let receipt = try await ledger.inventoryProjectionReceipt(binding: intent.binding, request: intent.canonicalRequest)
        try requireAccess(source)
        if let receipt { try requireReceipt(receipt, intent: intent) }
        else { try await requireNoReviewDisposition(source, intent: intent) }
        return ValidatedSource(source: source, intent: intent)
    }

    /// Explicitly resolves a previously validated attempt; transport errors never become absence proofs.
    func reconcile(_ validated: ValidatedSource) async throws -> Reconciliation {
        let source = validated.source, intent = validated.intent
        try requireAccess(source)
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        // Recognition deliberately precedes source retirement and needs-review markers.
        let receipt: LedgerInventoryProjectionReceipt?
        do {
            receipt = try await ledger.inventoryProjectionReceipt(binding: intent.binding, request: intent.canonicalRequest)
            try requireAccess(source)
        } catch LedgerStoreError.erased {
            try requireAccess(source)
            let retired = try await ledger.retiredWorkspaceIDs()
            try requireAccess(source)
            guard retired.contains(intent.binding.ledgerWorkspaceID) else { throw LedgerStoreError.erased }
            return .ledgerRetired
        }
        if let receipt {
            try requireReceipt(receipt, intent: intent)
            let current = try await currentLedger(source)
            guard let record = current.record else { throw Failure.missingLedgerHead }
            return .applied(Result(receipt: receipt, current: record, workspace: current.workspace, replayed: true))
        }
        do {
            guard try await boundIntent(source) == intent else { throw Failure.invalidBinding }
        } catch ComparisonStoreError.erased {
            return .sourceRetired(try await currentLedger(source))
        }
        let current = try await currentLedger(source)
        if try await reviewDisposition(source, intent: intent) == nil {
            let marker = ReviewDisposition(version: 1, sourceIntentID: source.sourceIntentID,
                bindingDigest: try Self.bindingDigest(intent), decision: "needsReview", ledgerRevision: current.record?.revision ?? 0)
            let bytes = try Self.encode(marker), id = Self.dispositionID(source)
            let state = try await inventory.inventoryState()
            try requireAccess(source)
            let record = InventoryRecord(key: .init(.intent, id), revision: 1, payloadVersion: 1, payload: bytes)
            _ = try await inventory.commitInventory(.init(workspaceID: source.inventoryWorkspaceID, operationID: id,
                expectedRevision: state.revision, request: try Self.dispositionRequest(source, intent: intent),
                mode: state.active ? .mutate : .prepare, writes: [.init(record: record, expectedRevision: 0)]))
            try requireAccess(source)
        }
        return .needsReview(current)
    }

    /// Recognition precedes reconstructing a historical candidate or deciding its target/base is stale.
    func recover(_ source: Source) async throws -> Result? {
        try requireAccess(source)
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        let intent = try await boundIntent(source)
        guard let receipt = try await ledger.inventoryProjectionReceipt(binding: intent.binding, request: intent.canonicalRequest) else {
            try requireAccess(source)
            try await requireNoReviewDisposition(source, intent: intent)
            return nil
        }
        try requireAccess(source)
        try requireReceipt(receipt, intent: intent)
        return try await currentResult(receipt, source: source, intent: intent, replayed: true)
    }

    /// Reconstruct only from the original request at the SAME ledger base when recover returns nil.
    /// SQLite commits the exact ledger mutation and binding together. The caller owns completion markers.
    func apply(_ source: Source, payload: Data) async throws -> Result {
        try requireAccess(source)
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        let intent = try await boundIntent(source)
        guard payload.count <= LedgerStore.maximumPayloadBytes else { throw LedgerStoreError.payloadTooLarge }
        guard Self.digest(payload) == intent.payloadDigest else { throw LedgerStoreError.operationConflict }
        if let receipt = try await ledger.inventoryProjectionReceipt(binding: intent.binding, request: intent.canonicalRequest) {
            try requireAccess(source)
            try requireReceipt(receipt, intent: intent)
            return try await currentResult(receipt, source: source, intent: intent, replayed: true)
        }
        try requireAccess(source)
        try await requireNoReviewDisposition(source, intent: intent)
        let candidate = try LedgerModel.validatePayload(payload)
        let current = try await ledger.load()
        try requireAccess(source)
        guard (current?.revision ?? 0) == intent.expectedRevision else {
            throw LedgerStoreError.staleRevision(expected: intent.expectedRevision, actual: current?.revision ?? 0)
        }
        let workspace = try current.map { try LedgerModel.validatePayload($0.payload) } ?? LedgerWorkspace()
        try await validateNewProjection(intent, workspace, candidate)
        guard try await boundIntent(source) == intent else { throw Failure.invalidBinding }
        let receipt = try await ledger.applyInventoryProjection(binding: intent.binding, request: intent.canonicalRequest,
            payload: payload, expectedRevision: intent.expectedRevision, savedAt: intent.savedAt)
        try requireAccess(source)
        try requireReceipt(receipt, intent: intent)
        return try await currentResult(receipt, source: source, intent: intent, replayed: false)
    }

    private func boundIntent(_ source: Source) async throws -> IntentBinding {
        try requireAccess(source)
        guard let receipt = try await inventory.inventoryCommittedOperation(id: source.inventoryOperationID,
            request: source.inventoryRequest) else { throw Failure.missingInventoryOperation }
        try requireAccess(source)
        let key = InventoryRecordKey(.intent, source.sourceIntentID)
        guard let head = receipt.heads.first(where: { $0.key == key }), head.revision > 0,
              let record = try await inventory.inventoryRecord(key), record.revision == head.revision,
              record.payloadVersion == 1, record.payload.count <= InventoryPersistenceLimits.recordBytes else { throw Failure.invalidBinding }
        try requireAccess(source)
        let intent = try JSONDecoder().decode(IntentBinding.self, from: record.payload)
        try Self.validate(intent)
        guard intent.binding.inventoryWorkspaceID == source.inventoryWorkspaceID,
              intent.binding.inventoryOperationID == source.inventoryOperationID,
              intent.binding.ledgerWorkspaceID == ledger.workspaceID else { throw Failure.wrongOrigin }
        return intent
    }
    private func currentResult(_ receipt: LedgerInventoryProjectionReceipt, source: Source,
                               intent: IntentBinding, replayed: Bool) async throws -> Result {
        guard let current = try await ledger.load() else { throw Failure.missingLedgerHead }
        try requireAccess(source)
        let workspace = try LedgerModel.validatePayload(current.payload)
        guard try await boundIntent(source) == intent else { throw Failure.invalidBinding }
        return Result(receipt: receipt, current: current, workspace: workspace, replayed: replayed)
    }
    private func currentLedger(_ source: Source) async throws -> Current {
        let record = try await ledger.load()
        try requireAccess(source)
        return Current(record: record, workspace: try record.map { try LedgerModel.validatePayload($0.payload) } ?? LedgerWorkspace())
    }
    private func requireNoReviewDisposition(_ source: Source, intent: IntentBinding) async throws {
        guard try await reviewDisposition(source, intent: intent) == nil else { throw Failure.needsReview }
    }
    private func reviewDisposition(_ source: Source, intent: IntentBinding) async throws -> ReviewDisposition? {
        let id = Self.dispositionID(source)
        guard let row = try await inventory.inventoryRecord(.init(.intent, id)) else {
            // A retired marker must not silently permit the old projection again.
            let receipt = try await inventory.inventoryCommittedOperation(id: id, request: try Self.dispositionRequest(source, intent: intent))
            try requireAccess(source)
            guard receipt == nil else { throw Failure.invalidBinding }
            return nil
        }
        try requireAccess(source)
        guard row.revision == 1, row.payloadVersion == 1 else { throw Failure.invalidBinding }
        let marker = try JSONDecoder().decode(ReviewDisposition.self, from: row.payload)
        guard marker.version == 1, marker.sourceIntentID == source.sourceIntentID,
              marker.bindingDigest == (try Self.bindingDigest(intent)), marker.decision == "needsReview", marker.ledgerRevision >= 0 else {
            throw Failure.invalidBinding
        }
        guard let receipt = try await inventory.inventoryCommittedOperation(id: id, request: try Self.dispositionRequest(source, intent: intent)),
              receipt.heads.contains(where: { $0.key == row.key && $0.revision == row.revision }) else { throw Failure.invalidBinding }
        try requireAccess(source)
        return marker
    }
    nonisolated private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    nonisolated private static func bindingDigest(_ intent: IntentBinding) throws -> Data { digest(try encode(intent)) }
    nonisolated private static func dispositionRequest(_ source: Source, intent: IntentBinding) throws -> Data {
        Data("pantry-ledger-needs-review:v1:".utf8) + Data(source.sourceIntentID.uuidString.utf8) + (try bindingDigest(intent))
    }
    nonisolated private static func dispositionID(_ source: Source) -> UUID {
        var bytes = Array(digest(Data("pantry-ledger-needs-review:v1:\(source.inventoryWorkspaceID):\(source.sourceIntentID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    private func requireReceipt(_ receipt: LedgerInventoryProjectionReceipt, intent: IntentBinding) throws {
        guard receipt.binding == intent.binding, receipt.requestDigest == intent.requestDigest,
              receipt.payloadDigest == intent.payloadDigest, receipt.baseRevision == intent.expectedRevision,
              receipt.savedAt == intent.savedAt else { throw LedgerStoreError.operationConflict }
    }
    private func requireAccess(_ source: Source) throws {
        guard authorize(source.inventoryWorkspaceID, ledger.workspaceID) else { throw Failure.unauthorized }
        guard source.inventoryWorkspaceID == inventory.workspaceID else { throw Failure.wrongOrigin }
    }
    nonisolated private static func digest(_ value: Data) -> Data { Data(SHA256.hash(data: value)) }
    nonisolated private static func validate(_ value: IntentBinding) throws {
        guard value.version == 1, !value.canonicalRequest.isEmpty, value.canonicalRequest.count <= 32_768,
              value.requestDigest == digest(value.canonicalRequest), value.payloadDigest.count == 32,
              value.expectedRevision >= 0, value.savedAt.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidBinding }
    }
}
