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
    struct Scope: Codable, Equatable, Sendable {
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
        let packPendingDigest: Data?
        let capturedAt: Date
    }
    /// Payload-free archival evidence. Importing these never authorizes root erasure.
    enum Evidence: Codable, Equatable, Sendable {
        case inventoryRetired(key: InventoryRecordKey, originID: UUID, revision: Int64, operationID: UUID)
        case sourceRetired(InventorySourceIdentity, originID: UUID, operationID: UUID)
        case reservationRedacted(InventoryReservationRedaction)
        case comparisonRetired(id: UUID, originID: UUID, revision: Int64, operationID: UUID, at: Date)
        case ledgerRetired(originID: UUID, revision: Int64, replacementID: UUID, operationID: UUID, at: Date)
        case projection(sourceIntentID: UUID, status: ProjectionStatus)
    }
    enum ProjectionStatus: String, Codable, Sendable { case applied, unappliedAtCapture, retiredLedgerOrigin }
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
        let packOrigins = Set(ledgerRetirements.map(\.workspaceID)).union([ledger.workspaceID])
        let packEntries = try readPackPending(ledgerOrigins: packOrigins)
        var budget = try packEntries.reduce(0) { $0 + (try ArchiveCodec.canonical($1).count) }
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
        for entry in packEntries { history.append(.packPending(entry)) }
        let finalState = try await inventory.inventoryState(); try access()
        let finalToken = try await inventory.inventorySourceToken(); try access()
        let finalLedger = try await ledger.load(); try access()
        let finalRetired = try await ledger.tombstones(); try access()
        guard finalState == initial, finalToken == token, finalLedger == ledgerHead, finalRetired == ledgerRetirements,
              try pending.read() == pendingEntry, try foodPending.read() == foodPendingEntry,
              try readPackPending(ledgerOrigins: packOrigins) == packEntries else { throw Failure.stale }
        let snapshot = PantryArchiveCodec.Snapshot(descriptor: .init(originID: inventory.workspaceID,
            inventoryRevision: initial.revision, capturedAt: date), lots: lots, observations: observations, events: events,
            reservations: claims, sourceLinks: links, history: history)
        try PantryArchiveCodec.validate(snapshot)
        let scope = Scope(version: 1, inventoryOriginID: inventory.workspaceID, inventoryRevision: initial.revision,
            sourceToken: token, ledgerOriginID: ledger.workspaceID, ledgerRevision: ledgerHead?.revision ?? 0,
            ledgerOperationID: ledgerHead?.operationID, ledgerPayloadDigest: ledgerHead.map { Self.digest($0.payload) },
            pendingDigest: try pendingEntry.map { Self.digest(try ArchiveCodec.canonical($0)) },
            foodPendingDigest: try foodPendingEntry.map { Self.digest(try ArchiveCodec.canonical($0)) },
            packPendingDigest: try Self.packDigest(inventoryOriginID: inventory.workspaceID, ledgerOrigins: packOrigins, entries: packEntries),
            capturedAt: date)
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
        let retired = try await ledger.tombstones(); try access()
        let packOrigins = Set(retired.map(\.workspaceID)).union([ledger.workspaceID])
        let packEntries = try readPackPending(ledgerOrigins: packOrigins)
        let scope = captured.scope
        guard state.active, state.workspaceID == scope.inventoryOriginID, state.revision == scope.inventoryRevision,
              token == scope.sourceToken, ledger.workspaceID == scope.ledgerOriginID,
              (head?.revision ?? 0) == scope.ledgerRevision, head?.operationID == scope.ledgerOperationID,
              head.map({ Self.digest($0.payload) }) == scope.ledgerPayloadDigest,
              try pending.read().map({ Self.digest(try ArchiveCodec.canonical($0)) }) == scope.pendingDigest,
              try pending.makeFoodPendingStore().read().map({ Self.digest(try ArchiveCodec.canonical($0)) }) == scope.foodPendingDigest else { throw Failure.stale }
        if let expected = scope.packPendingDigest {
            guard try Self.packDigest(inventoryOriginID: inventory.workspaceID, ledgerOrigins: packOrigins, entries: packEntries) == expected else { throw Failure.stale }
        } else {
            guard packEntries.isEmpty else { throw Failure.stale }
        }
        return try storage.publish(captured, bundleID: bundleID)
    }

    /// Read only bounded, known origin pairs. A matching unknown filename is
    /// evidence we cannot account for, never permission to silently omit it.
    private func readPackPending(ledgerOrigins: Set<UUID>) throws -> [PantryPackSelectionPendingStore.Entry] {
        try access()
        guard ledgerOrigins.count <= 4_096 else { throw Failure.tooLarge }
        let directory = pending.fileURL.deletingLastPathComponent()
        let origins = ledgerOrigins.sorted { $0.uuidString < $1.uuidString }
        let stores = try origins.map {
            try PantryPackSelectionPendingStore(directory: directory, inventoryWorkspaceID: inventory.workspaceID, ledgerWorkspaceID: $0)
        }
        let expected = Set(stores.map { $0.fileURL.lastPathComponent })
        let prefix = inventory.workspaceID.uuidString.lowercased() + "."
        var enumerationFailed = false
        guard let files = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw Failure.invalidEvidence }
        var count = 0
        while let url = files.nextObject() as? URL {
            count += 1
            guard count <= 16_384 else { throw Failure.tooLarge }
            let name = url.lastPathComponent
            guard name.lowercased().hasPrefix(prefix), name.lowercased().hasSuffix(".pack.json") else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard expected.contains(name), values.isRegularFile == true, values.isSymbolicLink != true else { throw Failure.unknownHistory }
        }
        guard !enumerationFailed else { throw Failure.invalidEvidence }
        var entries: [PantryPackSelectionPendingStore.Entry] = []
        var bytes = 0
        for store in stores {
            guard let entry = try store.read() else { continue }
            let next = bytes.addingReportingOverflow(try ArchiveCodec.canonical(entry).count)
            guard !next.overflow, next.partialValue <= limits.materializedBytes else { throw Failure.tooLarge }
            bytes = next.partialValue; entries.append(entry)
        }
        return entries
    }

    private struct PackPairDigest: Encodable { let ledgerOriginID: UUID; let entryDigest: Data? }
    private struct PackJournalDigest: Encodable { let inventoryOriginID: UUID; let pairs: [PackPairDigest] }
    private static func packDigest(inventoryOriginID: UUID, ledgerOrigins: Set<UUID>,
                                   entries: [PantryPackSelectionPendingStore.Entry]) throws -> Data {
        var indexed: [UUID: PantryPackSelectionPendingStore.Entry] = [:]
        for entry in entries {
            guard entry.request.inventoryWorkspaceID == inventoryOriginID,
                  ledgerOrigins.contains(entry.request.ledgerWorkspaceID),
                  indexed.updateValue(entry, forKey: entry.request.ledgerWorkspaceID) == nil else { throw Failure.invalidEvidence }
        }
        let pairs = try ledgerOrigins.sorted { $0.uuidString < $1.uuidString }.map { origin in
            PackPairDigest(ledgerOriginID: origin, entryDigest: try indexed[origin].map { digest(try ArchiveCodec.canonical($0)) })
        }
        return digest(try ArchiveCodec.canonical(PackJournalDigest(inventoryOriginID: inventoryOriginID, pairs: pairs)))
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
            case .reservationRedacted(let value):
                guard value.workspaceID == scope.inventoryOriginID, value.throughRevision > 0 else { throw Failure.invalidEvidence }
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
        let packEntries = captured.snapshot.history.compactMap { value -> PantryPackSelectionPendingStore.Entry? in
            if case .packPending(let entry) = value, entry.request.inventoryWorkspaceID == scope.inventoryOriginID { return entry }
            return nil
        }
        if let expected = scope.packPendingDigest {
            guard expected.count == 32,
                  try packDigest(inventoryOriginID: scope.inventoryOriginID,
                      ledgerOrigins: retiredLedgers.union([scope.ledgerOriginID]), entries: packEntries) == expected else { throw Failure.invalidEvidence }
        } else {
            // Older optional scopes remain readable only when they contain no
            // live pack journal that their original capture could not bind.
            guard packEntries.isEmpty else { throw Failure.invalidEvidence }
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

extension PantryArchiveCapture {
    /// Production capture: only a page of records crosses actor boundaries. Complete
    /// history is verified on the worker's protected disk index before a handle exists.
    func captureHandle(worker: PantryArchiveWorker, at date: Date) async throws -> PantryArchiveHandle {
        try access()
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        let state = try await inventory.inventoryState(); try access()
        guard state.active, date.timeIntervalSinceReferenceDate.isFinite,
              pending.inventoryWorkspaceID == inventory.workspaceID else { throw Failure.inactive }
        let token = try await inventory.inventorySourceToken(); try access()
        let head = try await ledger.load(); try access()
        let ledgerDigest = try await worker.ledgerDigest(head, at: date); try access()
        let id = try await worker.begin(descriptor: .init(originID: state.workspaceID, inventoryRevision: state.revision, capturedAt: date))
        var published: PantryArchiveHandle?
        do {
            try access()
            try await worker.registerLedgerOrigin(ledger.workspaceID, retired: false, to: id); try access()
            var cursor: UUID?
            while true {
                let page = try await ledger.tombstonePage(expectedWorkspaceID: ledger.workspaceID,
                    expectedRevision: head?.revision ?? 0, after: cursor, limit: 200); try access()
                for value in page {
                    try await worker.registerLedgerOrigin(value.workspaceID, retired: true, to: id); try access()
                    try await worker.appendEvidence(.current(.ledgerRetired(originID: value.workspaceID,
                        revision: value.erasedRevision, replacementID: value.replacementWorkspaceID,
                        operationID: value.operationID, at: value.erasedAt)), to: id); try access()
                }
                if page.count < 200 { break }; cursor = page.last?.workspaceID
            }
            try await Self.stageInventory(inventory, revision: state.revision, token: token, worker: worker, job: id, authorize: access)
            var bindingCursor: UUID?
            while true {
                let page = try await worker.projectionBindings(id, after: bindingCursor, limit: 200); try access()
                for item in page {
                    let retired = try await worker.isRetiredLedger(item.value.binding.ledgerWorkspaceID, in: id); try access()
                    let receipt: LedgerInventoryProjectionReceipt?
                    if retired { receipt = nil }
                    else {
                        guard item.value.binding.ledgerWorkspaceID == ledger.workspaceID else { throw Failure.wrongOrigin }
                        receipt = try await ledger.inventoryProjectionReceipt(binding: item.value.binding, request: item.value.canonicalRequest); try access()
                    }
                    try await worker.completeProjection(id, intentID: item.id, receipt: receipt, retired: retired); try access()
                }
                if page.count < 200 { break }; bindingCursor = page.last?.id
            }
            let directory = pending.fileURL.deletingLastPathComponent()
            let journals = try await worker.captureJournals(to: id, directory: directory, pickupLedgerID: pending.ledgerWorkspaceID); try access()
            let finalState = try await inventory.inventoryState(); try access()
            let finalToken = try await inventory.inventorySourceToken(); try access()
            let finalHead = try await ledger.load(); try access()
            guard finalState == state, finalToken == token, finalHead == head else { throw Failure.stale }
            let checked = try await worker.captureJournals(to: id, directory: directory,
                pickupLedgerID: pending.ledgerWorkspaceID, revalidate: true); try access()
            guard checked == journals else { throw Failure.stale }
            let scope = Scope(version: 1, inventoryOriginID: state.workspaceID, inventoryRevision: state.revision,
                sourceToken: token, ledgerOriginID: ledger.workspaceID, ledgerRevision: head?.revision ?? 0,
                ledgerOperationID: head?.operationID, ledgerPayloadDigest: ledgerDigest,
                pendingDigest: journals.pickup, foodPendingDigest: journals.food, packPendingDigest: journals.pack, capturedAt: date)
            let result = try await worker.finish(id, scope: .paired(scope)); published = result; try access()
            // Raw connections are outside the app gate; detect their changes after the last await.
            guard try await inventory.inventoryState() == state else { throw Failure.stale }; try access()
            guard try await inventory.inventorySourceToken() == token else { throw Failure.stale }; try access()
            guard try await ledger.load() == head else { throw Failure.stale }; try access()
            return result
        } catch {
            try? await worker.cancel(id)
            if let published { try? await worker.discardUnregistered(published) }
            throw error
        }
    }

    /// Independent recovered copies have a new physical inventory origin and no
    /// paired ledger. Original history is carried as inert, self-contained lineage.
    static func captureIndependent(worker: PantryArchiveWorker, inventory: ComparisonStore,
        original: PantryArchiveHandle, identity: PantryArchiveWorker.RestorationContext,
        journalDirectory: URL, gate: PantryMutationGate, at date: Date,
        authorize: @escaping @MainActor () throws -> Void) async throws -> PantryArchiveHandle {
        try authorize()
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        guard identity.workspaceID == inventory.workspaceID, identity.reference == original.reference,
              identity.preparedAt <= date else { throw Failure.wrongOrigin }
        let state = try await inventory.inventoryState(); try authorize()
        guard state.active else { throw Failure.inactive }
        let token = try await inventory.inventorySourceToken(); try authorize()
        let id = try await worker.begin(descriptor: .init(originID: state.workspaceID, inventoryRevision: state.revision, capturedAt: date))
        var published: PantryArchiveHandle?
        do {
            try authorize()
            try await stageInventory(inventory, revision: state.revision, token: token, worker: worker, job: id, authorize: authorize)
            // There is no executable paired-work namespace in an independent copy.
            guard try await worker.projectionBindings(id, limit: 1).isEmpty else { throw Failure.invalidEvidence }; try authorize()
            let journals = try await worker.captureJournals(to: id, directory: journalDirectory, pickupLedgerID: nil); try authorize()
            let scope = PantryArchiveWorker.IndependentScope(copyID: identity.copyID, original: original.reference,
                originalOriginID: original.descriptor.originID, originID: state.workspaceID, inventoryRevision: state.revision,
                restorationID: identity.restorationID, restoredAt: identity.preparedAt, capturedAt: date, foodPendingDigest: journals.food)
            try await worker.appendIndependentLineage(original, scope: scope, to: id); try authorize()
            guard try await inventory.inventoryState() == state else { throw Failure.stale }; try authorize()
            guard try await inventory.inventorySourceToken() == token else { throw Failure.stale }; try authorize()
            guard try await worker.captureJournals(to: id, directory: journalDirectory, pickupLedgerID: nil, revalidate: true) == journals else { throw Failure.stale }; try authorize()
            let result = try await worker.finish(id, scope: .independent(scope)); published = result; try authorize()
            guard try await inventory.inventoryState() == state else { throw Failure.stale }; try authorize()
            guard try await inventory.inventorySourceToken() == token else { throw Failure.stale }; try authorize()
            return result
        } catch {
            try? await worker.cancel(id)
            if let published { try? await worker.discardUnregistered(published) }
            throw error
        }
    }

    private static func stageInventory(_ store: ComparisonStore, revision: Int64, token: InventorySourceToken,
        worker: PantryArchiveWorker, job: UUID, authorize: @MainActor () throws -> Void) async throws {
        for kind in InventoryRecordKind.allCases {
            var cursor: UUID?
            while true {
                let page = try await store.inventoryRecords(kind: kind, after: cursor, limit: 200); try authorize()
                try await worker.appendRecords(page, to: job); try authorize()
                if page.count < 200 { break }; cursor = page.last?.key.id
            }
            cursor = nil
            while true {
                let page = try await store.inventoryTombstones(kind: kind, expectedInventoryRevision: revision, after: cursor, limit: 200); try authorize()
                for value in page {
                    try await worker.appendEvidence(.current(.inventoryRetired(key: value.key, originID: value.workspaceID,
                        revision: value.erasedRevision, operationID: value.operationID)), to: job); try authorize()
                }
                if page.count < 200 { break }; cursor = page.last?.key.id
            }
        }
        var revisionCursor: InventoryRevisionCursor?
        while true {
            let page = try await store.inventoryRevisionPage(expectedRevision: revision, sourceToken: token, after: revisionCursor, limit: 200); try authorize()
            guard let last = page.last else { break }
            try await worker.appendRetainedRevisions(page, to: job); try authorize()
            revisionCursor = .init(kind: last.key.kind, id: last.key.id, revision: last.revision)
        }
        var comparisonCursor: InventoryComparisonRevisionCursor?
        while true {
            let page = try await store.inventoryComparisonRevisionPage(expectedRevision: revision, sourceToken: token, after: comparisonCursor, limit: 200); try authorize()
            guard let last = page.last else { break }
            try await worker.appendSources(page, originID: store.workspaceID, to: job); try authorize()
            comparisonCursor = .init(id: last.id, revision: last.revision)
        }
        var cursor: UUID?
        while true {
            let page = try await store.inventoryComparisonTombstones(token: token, after: cursor, limit: 200); try authorize()
            for value in page {
                try await worker.appendEvidence(.current(.comparisonRetired(id: value.id, originID: value.workspaceID,
                    revision: value.erasedRevision, operationID: value.operationID, at: value.erasedAt)), to: job); try authorize()
            }
            if page.count < 200 { break }; cursor = page.last?.id
        }
        cursor = nil
        while true {
            let page = try await store.inventoryReservationRedactions(expectedInventoryRevision: revision, after: cursor, limit: 200); try authorize()
            for value in page { try await worker.appendEvidence(.current(.reservationRedacted(value)), to: job); try authorize() }
            if page.count < 200 { break }; cursor = page.last?.reservationID
        }
        var sourceCursor: InventorySourceIdentity?
        while true {
            let page = try await store.inventoryRetiredSources(expectedInventoryRevision: revision, after: sourceCursor, limit: 200); try authorize()
            for value in page {
                try await worker.appendEvidence(.current(.sourceRetired(value.source, originID: value.workspaceID, operationID: value.operationID)), to: job); try authorize()
            }
            if page.count < 200 { break }; sourceCursor = page.last?.source
        }
    }
}
