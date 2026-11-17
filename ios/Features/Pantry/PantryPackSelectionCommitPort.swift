import Foundation
import CoreDomain
import LocalStore

/// Ledger-only pack mutation. The shared gate excludes cooperating app writers;
/// final source checks and ledger CAS do not promise cross-process atomicity.
@MainActor final class PantryPackSelectionCommitPort {
    enum Failure: Error, Equatable { case unauthorized, actionUnauthorized, invalidRequest, wrongOrigin, operationConflict, staleReview, missingHead, missingJournal }
    static let maximumRequestBytes = 512 * 1_024
    /// Admission for a first gross-only save, not food availability evidence.
    /// It binds a complete authorized read and the absence of this shop's source.
    struct GrossBasis: Codable, Equatable {
        let originID: UUID
        let inventoryRevision: Int64
        let sourceHeads: [LedgerCanonicalPackStockEvidence.SourceHead]

        @MainActor static func review(context: PantryPackStockReview.Context, absentJourneyID: UUID) throws -> Self {
            guard context.snapshot.state.active, context.snapshot.state.workspaceID == context.mapping.originID else { throw Failure.staleReview }
            let result = Self(originID: context.snapshot.state.workspaceID, inventoryRevision: context.snapshot.state.revision,
                sourceHeads: context.mapping.sourceHeads.map { .init(journeyID: $0.id, revision: $0.revision) }
                    .sorted { $0.journeyID.uuidString < $1.journeyID.uuidString })
            try result.validate(absentJourneyID: absentJourneyID)
            return result
        }
        @MainActor func validate(absentJourneyID: UUID) throws {
            guard inventoryRevision >= 0, sourceHeads.count <= PantryLegacyMigration.maximumHeads,
                  Set(sourceHeads.map(\.journeyID)).count == sourceHeads.count,
                  sourceHeads.allSatisfy({ $0.revision > 0 && $0.journeyID != absentJourneyID }),
                  sourceHeads == sourceHeads.sorted(by: { $0.journeyID.uuidString < $1.journeyID.uuidString }) else { throw Failure.invalidRequest }
        }
    }
    struct Request: Codable, Equatable {
        let version: Int
        let inventoryWorkspaceID: UUID
        let ledgerWorkspaceID: UUID
        let selection: LedgerPackSelection
        let reviewedLedgerRevision: Int64
        let requiresActionAuthorization: Bool
        let grossBasis: GrossBasis?
        init(version: Int = 1, inventoryWorkspaceID: UUID, ledgerWorkspaceID: UUID, selection: LedgerPackSelection,
             reviewedLedgerRevision: Int64, requiresActionAuthorization: Bool = false, grossBasis: GrossBasis? = nil) {
            self.version = version; self.inventoryWorkspaceID = inventoryWorkspaceID; self.ledgerWorkspaceID = ledgerWorkspaceID
            self.selection = selection; self.reviewedLedgerRevision = reviewedLedgerRevision
            self.requiresActionAuthorization = requiresActionAuthorization; self.grossBasis = grossBasis
        }
    }
    typealias Entry = PantryPackSelectionPendingStore.Entry
    struct Current { let record: LedgerRecord?; let workspace: LedgerWorkspace }
    struct Result { let receipt: LedgerRecord; let current: LedgerRecord; let workspace: LedgerWorkspace; let replayed: Bool }
    enum Preparation { case completed(Result), pending(Entry) }
    enum PendingRecovery { case waiting(Entry, Current), committed(Entry?, Result), cleared(Current) }
    let ledgerWorkspaceID: UUID
    let inventoryWorkspaceID: UUID
    private let ledger: LedgerStore
    private let gate: PantryMutationGate
    private let pendingStore: PantryPackSelectionPendingStore
    private let reader: PantryCanonicalReader
    private let authorize: (UUID, UUID) -> Bool
    private let authorizeAction: (UUID) -> Bool
    private let clock: () -> Date
    init(store: ComparisonStore, ledger: LedgerStore, pendingStore: PantryPackSelectionPendingStore,
         gate: PantryMutationGate, authorize: @escaping (UUID, UUID) -> Bool,
         authorizeAction: @escaping (UUID) -> Bool = { _ in true }, clock: @escaping () -> Date = Date.init) {
        self.ledger = ledger; self.gate = gate; self.pendingStore = pendingStore; self.authorize = authorize
        self.authorizeAction = authorizeAction; self.clock = clock
        inventoryWorkspaceID = store.workspaceID; ledgerWorkspaceID = ledger.workspaceID
        reader = PantryCanonicalReader(store: store, authorize: { authorize(store.workspaceID, ledger.workspaceID) })
    }
    /// Recheck current private authority even when a nested reader threw its own error type.
    var hasReadAccess: Bool {
        authorize(inventoryWorkspaceID, ledgerWorkspaceID) &&
            pendingStore.inventoryWorkspaceID == inventoryWorkspaceID && pendingStore.ledgerWorkspaceID == ledgerWorkspaceID
    }
    func matchesGate(_ other: PantryMutationGate) -> Bool { gate === other }
    /// Read guard for an ordinary ledger edit using reviewed pantry supply. The
    /// caller holds this same gate's write lease for the whole ledger operation.
    func assertCurrentLedgerBasis(_ basis: LedgerCanonicalPackStockEvidence.Basis) async throws {
        try access()
        guard basis.originID == inventoryWorkspaceID else { throw Failure.wrongOrigin }
        let read = try await reader.load(at: clock()); try access()
        let actual = LedgerCanonicalPackStockEvidence.Basis(originID: read.snapshot.state.workspaceID,
            inventoryRevision: read.snapshot.state.revision,
            sourceHeads: read.sources.map { .init(journeyID: $0.id, revision: $0.revision) }
                .sorted { $0.journeyID.uuidString < $1.journeyID.uuidString })
        guard actual == basis else { throw Failure.staleReview }
        try await reader.assertCurrent(read); try access()
    }
    func readPending() throws -> Entry? { try access(); return try pendingStore.read() }

    /// Fixture/crash-boundary primitive. Production must call prepare so a changed
    /// body reusing a completed ID cannot create a poisoned pending journal.
    func stage(_ request: Request) throws -> Entry {
        try validateOrigin(request); try actionAccess(request)
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        return try pendingStore.save(request)
    }
    func prepare(_ request: Request) async throws -> Preparation {
        try validateOrigin(request); try access()
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        let receipt = try await ledger.savedOperation(id: request.selection.id); try access()
        if let receipt {
            try Self.validateReceipt(receipt, request: request)
            if let existing = try pendingStore.read() {
                guard existing.request == request else { throw Failure.operationConflict }
                return .pending(existing)
            }
            return .completed(try await result(receipt, replayed: true))
        }
        try actionAccess(request)
        return .pending(try pendingStore.save(request))
    }

    /// Expected may be absent on launch. Supplying the original Entry allows a
    /// completed operation to be recognized after successful journal cleanup.
    func recover(_ expected: Entry? = nil, commitIfUnapplied: Bool = false,
                 discardIfUnapplied: Bool = false) async throws -> PendingRecovery {
        guard !(commitIfUnapplied && discardIfUnapplied) else { throw Failure.invalidRequest }
        try access()
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        let live = try pendingStore.read()
        if let expected { try validateOrigin(expected.request) }
        if let expected, let live { guard expected.hasSameOriginal(as: live) else { throw Failure.operationConflict } }
        guard let entry = live ?? expected else { return .cleared(try await current()) }
        try validateOrigin(entry.request)
        let receipt = try await ledger.savedOperation(id: entry.operationID); try access()
        if let receipt {
            try Self.validateReceipt(receipt, request: entry.request)
            let result = try await result(receipt, replayed: true)
            let retained = try matchingLive(entry)
            return .committed(retained, result)
        }
        // An acknowledgment without its real receipt is not authority to reapply.
        guard entry.acknowledgment == nil else { throw Failure.operationConflict }
        guard let retained = try matchingLive(entry) else { return .cleared(try await current()) }
        if discardIfUnapplied {
            let head = try await current(); try access()
            guard let exact = try matchingLive(retained), exact.acknowledgment == nil else { throw Failure.missingJournal }
            try pendingStore.discardUnapplied(expected: exact)
            return .cleared(head)
        }
        guard commitIfUnapplied else { return .waiting(retained, try await current()) }
        let applied = try await apply(retained)
        return .committed(try matchingLive(retained), applied)
    }

    /// Call after adopting Result.current. Cleanup failure leaves the acknowledged
    /// original file for the same recovery; no uncommitted phase is recreated.
    @discardableResult func finishAdoption(_ entry: Entry, result: Result) throws -> Entry? {
        try validateOrigin(entry.request); try access()
        let lease = try gate.beginExclusiveWrite(); defer { gate.endExclusiveWrite(lease) }
        try Self.validateReceipt(result.receipt, request: entry.request)
        guard result.current.workspaceID == ledgerWorkspaceID,
              result.current.revision >= result.receipt.revision,
              try LedgerModel.validatePayload(result.current.payload) == result.workspace else { throw Failure.operationConflict }
        guard let live = try matchingLive(entry) else { return nil }
        let acknowledged = try pendingStore.acknowledgeAdoption(expected: live, receipt: result.receipt,
            currentLedgerRevision: result.current.revision)
        try access()
        try pendingStore.clearAcknowledged(expected: acknowledged)
        return nil
    }

    private func apply(_ entry: Entry) async throws -> Result {
        try requireApplicable(entry)
        let request = entry.request, selection = request.selection
        let now = clock()
        guard now.timeIntervalSinceReferenceDate.isFinite, selection.reviewedAt <= now else { throw Failure.invalidRequest }
        let actual = try await current(); try requireApplicable(entry)
        guard (actual.record?.revision ?? 0) == request.reviewedLedgerRevision,
              let shop = actual.workspace.shops.first(where: { $0.id == selection.shopID }) else { throw Failure.staleReview }
        let read = try await reader.load(at: now); try requireApplicable(entry)
        var candidate = actual.workspace
        if let gross = request.grossBasis {
            // No synthetic journey or allocation is needed. Exact absence and
            // reviewed revisions admit only the original gross-only save.
            let currentGross = GrossBasis(originID: read.snapshot.state.workspaceID,
                inventoryRevision: read.snapshot.state.revision,
                sourceHeads: read.sources.map { .init(journeyID: $0.id, revision: $0.revision) }
                    .sorted { $0.journeyID.uuidString < $1.journeyID.uuidString })
            guard currentGross == gross, selection.isGrossOnlyPurchase else { throw Failure.staleReview }
            try currentGross.validate(absentJourneyID: selection.shopID)
            guard try candidate.recordPackSelection(selection, workspaceID: ledgerWorkspaceID) else { throw Failure.operationConflict }
        } else {
            let mapping = try PantryLegacyMigration.map(originID: inventoryWorkspaceID, heads: read.sources, ledger: .unavailable, at: now)
            let proof = try PantryPackStockReview.currentEvidence(for: selection, shop: shop,
                bindings: actual.workspace.dinnerPlanning.portionBindings,
                context: .init(snapshot: read.snapshot, mapping: mapping, asOf: now))
            guard proof == selection.canonicalStockEvidence else { throw Failure.staleReview }
            guard try candidate.recordPackSelection(selection, workspaceID: ledgerWorkspaceID,
                currentCanonicalEvidence: proof) else { throw Failure.operationConflict }
        }
        let payload = try await Self.encodeCandidate(candidate); try requireApplicable(entry)
        guard payload.count <= LedgerStore.maximumPayloadBytes else { throw LedgerStoreError.payloadTooLarge }
        try await reader.assertCurrent(read); try requireApplicable(entry)
        let receipt = try await ledger.save(payload: payload, expectedRevision: request.reviewedLedgerRevision,
            operationID: selection.id, savedAt: selection.reviewedAt)
        try access()
        try Self.validateReceipt(receipt, request: request)
        return try await result(receipt, replayed: false)
    }
    private func requireApplicable(_ entry: Entry) throws {
        try actionAccess(entry.request)
        guard let current = try matchingLive(entry), current.acknowledgment == nil else { throw Failure.missingJournal }
    }
    private func matchingLive(_ entry: Entry) throws -> Entry? {
        try access()
        guard let current = try pendingStore.read() else { return nil }
        guard current.hasSameOriginal(as: entry) else { throw Failure.operationConflict }
        return current
    }
    private func current() async throws -> Current {
        try access()
        let record = try await ledger.load(); try access()
        return Current(record: record, workspace: try record.map { try LedgerModel.validatePayload($0.payload) } ?? LedgerWorkspace())
    }
    private func result(_ receipt: LedgerRecord, replayed: Bool) async throws -> Result {
        let head = try await current()
        guard let record = head.record, record.workspaceID == receipt.workspaceID,
              record.revision >= receipt.revision else { throw Failure.missingHead }
        return Result(receipt: receipt, current: record, workspace: head.workspace, replayed: replayed)
    }
    private func validateOrigin(_ request: Request) throws {
        try Self.validate(request)
        guard request.inventoryWorkspaceID == inventoryWorkspaceID, request.ledgerWorkspaceID == ledgerWorkspaceID,
              pendingStore.inventoryWorkspaceID == inventoryWorkspaceID, pendingStore.ledgerWorkspaceID == ledgerWorkspaceID else { throw Failure.wrongOrigin }
    }
    private func access() throws {
        guard hasReadAccess else { throw Failure.unauthorized }
        guard pendingStore.inventoryWorkspaceID == inventoryWorkspaceID, pendingStore.ledgerWorkspaceID == ledgerWorkspaceID else { throw Failure.wrongOrigin }
    }
    private func actionAccess(_ request: Request) throws {
        try access()
        guard !request.requiresActionAuthorization || authorizeAction(request.selection.id) else { throw Failure.actionUnauthorized }
    }
    static func validate(_ request: Request) throws {
        try request.selection.validate()
        guard request.version == 1,
              request.selection.sourceWorkspaceID == request.ledgerWorkspaceID,
              request.reviewedLedgerRevision >= 0, request.reviewedLedgerRevision < Int64.max,
              request.selection.reviewedAt.timeIntervalSinceReferenceDate.isFinite,
              try encoded(request).count <= maximumRequestBytes else { throw Failure.invalidRequest }
        if request.selection.isGrossOnlyPurchase {
            guard let gross = request.grossBasis, gross.originID == request.inventoryWorkspaceID else { throw Failure.invalidRequest }
            try gross.validate(absentJourneyID: request.selection.shopID)
        } else {
            guard request.selection.formatVersion == 3, request.grossBasis == nil,
                  request.selection.canonicalStockEvidence?.basis.originID == request.inventoryWorkspaceID else { throw Failure.invalidRequest }
        }
    }
    /// Gross selections have ledger-scoped mutation identity. Their absence basis
    /// admits the first write only; a later exact receipt wins over new pantry or
    /// journey state. The current ordered origin pair still requires live access.
    static func validateReceipt(_ record: LedgerRecord, request: Request) throws {
        try validate(request)
        guard record.workspaceID == request.ledgerWorkspaceID, record.operationID == request.selection.id,
              record.revision == request.reviewedLedgerRevision + 1, record.savedAt == request.selection.reviewedAt,
              try LedgerModel.validatePayload(record.payload).packSelections.first(where: { $0.id == request.selection.id }) == request.selection else {
            throw Failure.operationConflict
        }
    }
    @concurrent private static func encodeCandidate(_ workspace: LedgerWorkspace) async throws -> Data {
        struct Document: Encodable { let formatVersion: Int; let workspace: LedgerWorkspace }
        return try encoded(Document(formatVersion: 1, workspace: workspace))
    }
    nonisolated private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
