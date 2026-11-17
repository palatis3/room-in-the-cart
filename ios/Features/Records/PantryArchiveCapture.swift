import Foundation
import CryptoKit
import CoreDomain
import LocalStore
import RecordArchive

/// Owner export only. The common gate covers app-owned writers; final revision checks
/// also detect changes by a separate connection. This is not a cross-process transaction.
@MainActor final class PantryArchiveCapture {
    enum Failure: Error, Equatable { case unauthorized, inactive, stale, unknownHistory, wrongOrigin, tooLarge, invalidEvidence }
    struct Limits {
        // Temporary materialization safety bound, not a supported pantry-size promise.
        // Complete disk-backed graph validation is required before lifting this limitation.
        let materializedBytes: Int
        static let standard = Limits(materializedBytes: 128 * 1_024 * 1_024)
    }
    struct Scope: Codable, Equatable {
        let version: Int
        let inventoryOriginID: UUID
        let inventoryRevision: Int64
        let sourceToken: InventorySourceToken
        let ledgerOriginID: UUID
        let ledgerRevision: Int64
        let ledgerOperationID: UUID?
        let ledgerPayloadDigest: Data?
        let pendingDigest: Data?
        let foodPendingDigest: Data?
        let capturedAt: Date
    }
    /// Payload-free archival evidence. Importing these never authorizes root erasure.
    enum Evidence: Codable, Equatable {
        case inventoryRetired(key: InventoryRecordKey, originID: UUID, revision: Int64, operationID: UUID)
        case sourceRetired(InventorySourceIdentity, originID: UUID, operationID: UUID)
        case comparisonRetired(id: UUID, originID: UUID, revision: Int64, operationID: UUID, at: Date)
        case ledgerRetired(originID: UUID, revision: Int64, replacementID: UUID, operationID: UUID, at: Date)
        case projection(sourceIntentID: UUID, status: ProjectionStatus)
    }
    enum ProjectionStatus: String, Codable { case applied, unappliedAtCapture, retiredLedgerOrigin }
    struct Captured {
        let snapshot: PantryArchiveCodec.Snapshot
        let scope: Scope
        let evidence: [Evidence]
    }
    private let inventory: ComparisonStore
    private let ledger: LedgerStore
    private let pending: PantryPickupPendingStore
    private let gate: PantryMutationGate
    private let authorize: (UUID, UUID) -> Bool
    private let limits: Limits

    init(inventory: ComparisonStore, ledger: LedgerStore, pending: PantryPickupPendingStore,
         gate: PantryMutationGate, limits: Limits = .standard, authorize: @escaping (UUID, UUID) -> Bool) {
        self.inventory = inventory; self.ledger = ledger; self.pending = pending
        self.gate = gate; self.limits = limits; self.authorize = authorize
    }

    func capture(at date: Date) async throws -> Captured {
        guard limits.materializedBytes > 0, date.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidEvidence }
        try access()
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        let initial = try await inventory.inventoryState(); try access()
        guard initial.active else { throw Failure.inactive }
        let token = try await inventory.inventorySourceToken(); try access()
        let ledgerHead = try await ledger.load(); try access()
        if let ledgerHead {
            guard ledgerHead.savedAt <= date else { throw Failure.invalidEvidence }
            _ = try LedgerModel.validatePayload(ledgerHead.payload)
        }
        let ledgerRetirements = try await ledger.tombstones(); try access()
        guard pending.inventoryWorkspaceID == inventory.workspaceID else { throw Failure.wrongOrigin }
        let pendingEntry = try pending.read()
        let foodPending = try pending.makeFoodPendingStore()
        let foodPendingEntry = try foodPending.read()
        var budget = 0
        func account(_ bytes: Int) throws {
            let sum = budget.addingReportingOverflow(bytes)
            guard !sum.overflow, sum.partialValue <= limits.materializedBytes else { throw Failure.tooLarge }
            budget = sum.partialValue
        }
        var lots: [InventoryLot] = [], observations: [InventoryObservation] = [], events: [InventoryEvent] = []
        var claims: [InventoryReservation] = [], links: [PantryPersistenceCodec.SourceLink] = []
        var history: [PantryArchiveCodec.History] = [], intents: [InventoryRecord] = [], evidence: [Evidence] = []
        for kind in InventoryRecordKind.allCases {
            var cursor: UUID?
            while true {
                let page = try await inventory.inventoryRecords(kind: kind, after: cursor, limit: InventoryPersistenceLimits.pageItems)
                try access()
                for row in page {
                    try account(row.payload.count)
                    switch kind {
                    case .lot:
                        let value = try PantryPersistenceCodec.lot(row); try Self.exactKeys(value, bytes: row.payload); lots.append(value)
                    case .observation:
                        let value = try PantryPersistenceCodec.observation(row); try Self.exactKeys(value, bytes: row.payload); observations.append(value)
                    case .reservation:
                        let value = try PantryPersistenceCodec.reservation(row); try Self.exactKeys(value, bytes: row.payload); claims.append(value)
                    case .sourceLink:
                        let value = try PantryPersistenceCodec.sourceLink(row); try Self.exactKeys(value, bytes: row.payload); links.append(value)
                    case .event:
                        guard row.revision == 1, row.payloadVersion == 1, row.source == nil else { throw Failure.invalidEvidence }
                        let event = try JSONDecoder().decode(InventoryEvent.self, from: row.payload)
                        guard event.id == row.key.id, event.lotID == row.lotID else { throw Failure.invalidEvidence }
                        try Self.exactKeys(event, bytes: row.payload)
                        events.append(event)
                    case .intent: intents.append(row)
                    }
                }
                if page.count < InventoryPersistenceLimits.pageItems { break }
                cursor = page.last?.key.id
            }
            var retiredCursor: UUID?
            while true {
                let page = try await inventory.inventoryTombstones(kind: kind, expectedInventoryRevision: initial.revision,
                    after: retiredCursor, limit: InventoryPersistenceLimits.pageItems)
                try access()
                for value in page {
                    let item = Evidence.inventoryRetired(key: value.key, originID: value.workspaceID,
                        revision: value.erasedRevision, operationID: value.operationID)
                    try account(ArchiveCodec.canonical(item).count); evidence.append(item)
                }
                if page.count < InventoryPersistenceLimits.pageItems { break }
                retiredCursor = page.last?.key.id
            }
        }
        var sourceCursor: UUID?
        while true {
            let page = try await inventory.inventorySourcePage(token: token, after: sourceCursor, limit: InventoryPersistenceLimits.pageItems)
            try access()
            for value in page {
                try account(value.payload.count)
                history.append(.sourceHead(originID: inventory.workspaceID, .init(value)))
            }
            if page.count < InventoryPersistenceLimits.pageItems { break }
            sourceCursor = page.last?.id
        }
        var retiredSourceCursor: InventorySourceIdentity?
        while true {
            let page = try await inventory.inventoryRetiredSources(expectedInventoryRevision: initial.revision,
                after: retiredSourceCursor, limit: InventoryPersistenceLimits.pageItems)
            try access()
            for value in page {
                let item = Evidence.sourceRetired(value.source, originID: value.workspaceID, operationID: value.operationID)
                try account(ArchiveCodec.canonical(item).count); evidence.append(item)
            }
            if page.count < InventoryPersistenceLimits.pageItems { break }
            retiredSourceCursor = page.last?.source
        }
        let comparisons = try await inventory.tombstones(); try access()
        for value in comparisons {
            let item = Evidence.comparisonRetired(id: value.id, originID: value.workspaceID, revision: value.erasedRevision,
                operationID: value.operationID, at: value.erasedAt)
            try account(ArchiveCodec.canonical(item).count); evidence.append(item)
        }
        for value in ledgerRetirements {
            let item = Evidence.ledgerRetired(originID: value.workspaceID, revision: value.erasedRevision,
                replacementID: value.replacementWorkspaceID, operationID: value.operationID, at: value.erasedAt)
            try account(ArchiveCodec.canonical(item).count); evidence.append(item)
        }
        var bindings: [UUID: (InventoryRecord, PantryLedgerProjectionPort.IntentBinding)] = [:]
        var dispositions: [UUID: InventoryRecord] = [:]
        for row in intents {
            try ArchiveCodec.preflight(row.payload, maximum: InventoryPersistenceLimits.recordBytes)
            let object = try JSONSerialization.jsonObject(with: row.payload) as? [String: Any]
            if object?["namespace"] != nil {
                guard object?["namespace"] as? String == "pantry-legacy-provenance/v1" else { throw Failure.unknownHistory }
                let envelope = try JSONDecoder().decode(PantryMigrationPackage.Envelope.self, from: row.payload)
                let value = try PantryMigrationPackage.provenance(row, migrationID: envelope.migrationID, originID: inventory.workspaceID)
                try Self.exactKeys(value, bytes: row.payload); history.append(.migration(value))
            } else if object?["binding"] != nil {
                let value = try PantryLedgerProjectionPort.archiveBinding(row)
                guard value.binding.inventoryWorkspaceID == inventory.workspaceID else { throw Failure.wrongOrigin }
                try Self.exactKeys(value, bytes: row.payload)
                bindings[row.key.id] = (row, value)
            } else if object?["decision"] != nil {
                let value = try JSONDecoder().decode(PantryLedgerProjectionPort.ReviewDisposition.self, from: row.payload)
                guard dispositions.updateValue(row, forKey: value.sourceIntentID) == nil else { throw Failure.invalidEvidence }
            } else { throw Failure.unknownHistory }
        }
        guard Set(dispositions.keys).isSubset(of: Set(bindings.keys)) else { throw Failure.invalidEvidence }
        for id in bindings.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let (row, value) = bindings[id] else { throw Failure.invalidEvidence }
            var review: PantryArchiveCodec.ProjectionDisposition?
            if let marker = dispositions[id] {
                let disposition = try PantryLedgerProjectionPort.archiveDisposition(marker, bindingRecord: row)
                try Self.exactKeys(disposition, bytes: marker.payload)
                review = .init(recordID: marker.key.id, value: disposition)
            }
            var application: PantryArchiveCodec.ProjectionApplication?
            let status: ProjectionStatus
            if value.binding.ledgerWorkspaceID == ledger.workspaceID {
                let receipt = try await ledger.inventoryProjectionReceipt(binding: value.binding, request: value.canonicalRequest)
                try access()
                application = receipt.map(PantryArchiveCodec.ProjectionApplication.init)
                status = receipt == nil ? .unappliedAtCapture : .applied
            } else {
                guard ledgerRetirements.contains(where: { $0.workspaceID == value.binding.ledgerWorkspaceID }) else { throw Failure.wrongOrigin }
                // Retirement removed old operation history: never represent it as proven unapplied.
                status = .retiredLedgerOrigin
            }
            history.append(.projection(.init(sourceIntentID: id, binding: value, needsReview: review, application: application)))
            let statusEvidence = Evidence.projection(sourceIntentID: id, status: status)
            try account(ArchiveCodec.canonical(statusEvidence).count); evidence.append(statusEvidence)
        }
        if let entry = pendingEntry {
            guard let pendingLedger = entry.submission.request.ledgerOriginID,
                  pendingLedger == ledger.workspaceID || ledgerRetirements.contains(where: { $0.workspaceID == pendingLedger }) else { throw Failure.wrongOrigin }
            try account(ArchiveCodec.canonical(entry).count)
            history.append(.pickupPending(entry))
        }
        if let entry = foodPendingEntry {
            try account(ArchiveCodec.canonical(entry).count)
            history.append(.foodPending(entry))
        }
        let finalState = try await inventory.inventoryState(); try access()
        let finalToken = try await inventory.inventorySourceToken(); try access()
        let finalLedger = try await ledger.load(); try access()
        let finalRetired = try await ledger.tombstones(); try access()
        guard finalState == initial, finalToken == token, finalLedger == ledgerHead, finalRetired == ledgerRetirements,
              try pending.read() == pendingEntry, try foodPending.read() == foodPendingEntry else { throw Failure.stale }
        let snapshot = PantryArchiveCodec.Snapshot(descriptor: .init(originID: inventory.workspaceID,
            inventoryRevision: initial.revision, capturedAt: date), lots: lots, observations: observations, events: events,
            reservations: claims, sourceLinks: links, history: history)
        try PantryArchiveCodec.validate(snapshot)
        let scope = Scope(version: 1, inventoryOriginID: inventory.workspaceID, inventoryRevision: initial.revision,
            sourceToken: token, ledgerOriginID: ledger.workspaceID, ledgerRevision: ledgerHead?.revision ?? 0,
            ledgerOperationID: ledgerHead?.operationID, ledgerPayloadDigest: ledgerHead.map { Self.digest($0.payload) },
            pendingDigest: try pendingEntry.map { Self.digest(try ArchiveCodec.canonical($0)) },
            foodPendingDigest: try foodPendingEntry.map { Self.digest(try ArchiveCodec.canonical($0)) }, capturedAt: date)
        let result = Captured(snapshot: snapshot, scope: scope, evidence: evidence)
        try Self.validate(result); try access()
        return result
    }

    /// Publication revalidates the captured source after acquiring a fresh lease. A caller
    /// may display/review capture first without publishing stale data as a fresh backup.
    func publish(_ captured: Captured, to storage: PantryArchiveStorage, bundleID: UUID = UUID()) async throws -> PantryArchiveStorage.VerifiedBundle {
        try access()
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        let state = try await inventory.inventoryState(); try access()
        let token = try await inventory.inventorySourceToken(); try access()
        let head = try await ledger.load(); try access()
        let scope = captured.scope
        guard state.active, state.workspaceID == scope.inventoryOriginID, state.revision == scope.inventoryRevision,
              token == scope.sourceToken, ledger.workspaceID == scope.ledgerOriginID,
              (head?.revision ?? 0) == scope.ledgerRevision, head?.operationID == scope.ledgerOperationID,
              head.map({ Self.digest($0.payload) }) == scope.ledgerPayloadDigest,
              try pending.read().map({ Self.digest(try ArchiveCodec.canonical($0)) }) == scope.pendingDigest,
              try pending.makeFoodPendingStore().read().map({ Self.digest(try ArchiveCodec.canonical($0)) }) == scope.foodPendingDigest else { throw Failure.stale }
        return try storage.publish(captured, bundleID: bundleID)
    }

    private func access() throws {
        guard authorize(inventory.workspaceID, ledger.workspaceID) else { throw Failure.unauthorized }
    }
    static func digest(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
    /// Compare decoded JSON values, allowing harmless JSON escaping differences but rejecting dropped keys.
    private static func exactKeys<T: Encodable>(_ value: T, bytes: Data) throws {
        let canonical = try JSONSerialization.jsonObject(with: ArchiveCodec.canonical(value)) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary
        guard let canonical, let original, canonical == original else { throw Failure.invalidEvidence }
    }
    static func validate(_ captured: Captured) throws {
        let scope = captured.scope, descriptor = captured.snapshot.descriptor
        guard scope.version == 1, scope.inventoryOriginID == descriptor.originID,
              scope.inventoryRevision == descriptor.inventoryRevision, scope.capturedAt == descriptor.capturedAt,
              scope.sourceToken.workspaceID == scope.inventoryOriginID, scope.sourceToken.generation >= 0,
              scope.sourceToken.digest.count == 32, scope.ledgerRevision >= 0,
              (scope.ledgerRevision == 0) == (scope.ledgerOperationID == nil),
              (scope.ledgerRevision == 0) == (scope.ledgerPayloadDigest == nil),
              scope.ledgerPayloadDigest.map({ $0.count == 32 }) ?? true else { throw Failure.invalidEvidence }
        let pending = captured.snapshot.history.compactMap { value -> PantryPickupPendingStore.Entry? in
            if case .pickupPending(let entry) = value, entry.submission.request.originID == scope.inventoryOriginID { return entry }; return nil
        }
        guard pending.count <= 1, try pending.first.map({ digest(try ArchiveCodec.canonical($0)) }) == scope.pendingDigest else { throw Failure.invalidEvidence }
        let foodPending = captured.snapshot.history.compactMap { value -> PantryPendingStore.Entry? in
            if case .foodPending(let entry) = value, entry.command.originID == scope.inventoryOriginID { return entry }; return nil
        }
        guard foodPending.count <= 1,
              try foodPending.first.map({ digest(try ArchiveCodec.canonical($0)) }) == scope.foodPendingDigest else { throw Failure.invalidEvidence }
        var unique: Set<Data> = [], statuses: [UUID: ProjectionStatus] = [:], retiredLedgers: Set<UUID> = []
        for item in captured.evidence {
            guard unique.insert(digest(try ArchiveCodec.canonical(item))).inserted else { throw Failure.invalidEvidence }
            switch item {
            case let .inventoryRetired(_, origin, revision, _):
                guard origin == scope.inventoryOriginID, revision > 0 else { throw Failure.invalidEvidence }
            case let .sourceRetired(source, origin, _):
                guard origin == scope.inventoryOriginID, (1...256).contains(source.sourceID.utf8.count) else { throw Failure.invalidEvidence }
            case let .comparisonRetired(_, origin, revision, _, at):
                guard origin == scope.inventoryOriginID, revision > 0, at.timeIntervalSinceReferenceDate.isFinite, at <= scope.capturedAt else { throw Failure.invalidEvidence }
            case let .ledgerRetired(origin, revision, replacement, _, at):
                guard origin != replacement, revision >= 0, at.timeIntervalSinceReferenceDate.isFinite, at <= scope.capturedAt,
                      retiredLedgers.insert(origin).inserted else { throw Failure.invalidEvidence }
            case let .projection(id, status):
                guard statuses.updateValue(status, forKey: id) == nil else { throw Failure.invalidEvidence }
            }
        }
        let projections = captured.snapshot.history.compactMap { value -> PantryArchiveCodec.ProjectionEvidence? in
            if case .projection(let evidence) = value { return evidence }; return nil
        }
        guard Set(projections.map(\.sourceIntentID)) == Set(statuses.keys) else { throw Failure.invalidEvidence }
        for value in projections {
            switch statuses[value.sourceIntentID] {
            case .applied:
                guard value.application != nil, value.binding.binding.ledgerWorkspaceID == scope.ledgerOriginID else { throw Failure.invalidEvidence }
            case .unappliedAtCapture:
                guard value.application == nil, value.binding.binding.ledgerWorkspaceID == scope.ledgerOriginID else { throw Failure.invalidEvidence }
            case .retiredLedgerOrigin:
                guard value.application == nil, retiredLedgers.contains(value.binding.binding.ledgerWorkspaceID) else { throw Failure.invalidEvidence }
            case nil: throw Failure.invalidEvidence
            }
        }
    }
}
