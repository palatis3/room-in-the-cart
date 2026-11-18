import CryptoKit
import Foundation
import CoreDomain
import LocalStore

/// Private pantry access only. Composition supplies current workspace/persona authorization;
/// knowing a database UUID is never authorization. Migration activation is a separate operation.
@MainActor
final class PantryRepository {
    enum Failure: Error, Equatable {
        case inactive, unauthorized, wrongWorkspace, inconsistentSnapshot, invalidProvenance, pendingUnavailable
    }

    struct ReadLimits {
        let payloadBytes: Int
        let observations: Int
        static let standard = ReadLimits(payloadBytes: 32 * 1_024 * 1_024, observations: 100_000)
    }

    struct Snapshot {
        let state: InventoryState
        let lots: [InventoryLot]
        let reservations: [InventoryReservation]
        let availability: InventoryProjection
        var receiptAcquiredLots: Set<UUID> = []
        let loadedPayloadBytes: Int
        fileprivate let observationCount: Int
        fileprivate let lotPayloadBytes: [UUID: Int]
        fileprivate let reservationPayloadBytes: [UUID: Int]
    }

    struct Review {
        let command: InventoryCommand
        let before: Snapshot
        let proposedLot: InventoryLot
        let proposedAvailability: InventoryProjection

        /// Includes newly unresolved or shortfall-backed commitments, not just numeric changes.
        var affectedReservations: [InventoryReservationCoverage] {
            let previous = Dictionary(uniqueKeysWithValues: before.availability.reservations.map { ($0.id, $0) })
            let editedID: UUID?
            if case .reservation(let edit) = command.change { editedID = edit.id } else { editedID = nil }
            return proposedAvailability.reservations.filter { $0.id != editedID && previous[$0.id] != $0 }
        }
    }

    struct Result {
        let receipt: LocalStore.InventoryOperationReceipt
        let current: Snapshot
        let replayed: Bool
    }

    enum PendingRecovery {
        case waiting(PantryPendingStore.Entry, Snapshot)
        case committed(PantryPendingStore.Entry?, Result)
        case cleared(Snapshot)
    }

    /// Nil is supported for component fixtures/read-only adapters only. App-owned
    /// standalone editors must share a configured journal and mutation gate.
    let aliasPersonaID: UUID?
    let pendingStore: PantryPendingStore?
    private let store: ComparisonStore
    private let authorize: () -> Bool
    private let limits: ReadLimits
    private let mutationGate: PantryMutationGate?
    var originID: UUID { store.workspaceID }
    func observeErasure(_ observer: any PantryErasureObserver) { mutationGate?.observeErasure(observer) }

    init(store: ComparisonStore, limits: ReadLimits = .standard, mutationGate: PantryMutationGate? = nil,
         pendingStore: PantryPendingStore? = nil, aliasPersonaID: UUID? = nil,
         authorize: @escaping () -> Bool) {
        self.store = store
        self.authorize = authorize
        self.limits = limits
        self.mutationGate = mutationGate
        self.aliasPersonaID = aliasPersonaID
        self.pendingStore = pendingStore
    }

    /// Read every live claim, including other shops. Never publish partially read pages.
    func load(at now: Date) async throws -> Snapshot {
        try requireAccess()
        let initial = try await store.inventoryState()
        try requireAccess()
        guard initial.active else { throw Failure.inactive }
        // Bound the complete read and fetch history in pages, rather than doing
        // two actor/database round trips per lot. Capacity failure publishes no stock.
        var remainingBytes = limits.payloadBytes
        let lotRows = try await records(.lot, maximum: InventoryProjection.maximumLots, maximumBytes: remainingBytes)
        remainingBytes -= lotRows.reduce(0) { $0 + $1.payload.count }
        let claimRows = try await records(.reservation, maximum: InventoryProjection.maximumReservations, maximumBytes: remainingBytes)
        remainingBytes -= claimRows.reduce(0) { $0 + $1.payload.count }
        let sourceRows = try await records(.sourceLink, maximum: InventoryProjection.maximumLots, maximumBytes: remainingBytes)
        remainingBytes -= sourceRows.reduce(0) { $0 + $1.payload.count }
        let observationRows = try await records(.observation, maximum: limits.observations, maximumBytes: remainingBytes)
        let lots = try lotRows.map(PantryPersistenceCodec.lot)
        remainingBytes -= observationRows.reduce(0) { $0 + $1.payload.count }
        let acquiredLots = try await confirmedReceiptLots(lots, maximumBytes: remainingBytes)
        remainingBytes -= acquiredLots.bytes
        let final = try await store.inventoryState()
        try requireAccess()
        guard initial == final else { throw Failure.inconsistentSnapshot }
        let claims = try claimRows.map(PantryPersistenceCodec.reservation)
        let sourceLinks = try sourceRows.map(PantryPersistenceCodec.sourceLink)
        let observations = try observationRows.map(PantryPersistenceCodec.observation)
        let sources = Dictionary(uniqueKeysWithValues: sourceLinks.map { ($0.lotID, $0) })
        let histories = Dictionary(grouping: observations, by: \.lotID)
        let lotIDs = Set(lots.map(\.id))
        guard Set(sources.keys) == lotIDs, Set(histories.keys) == lotIDs else { throw Failure.invalidProvenance }
        for lot in lots {
            let history = (histories[lot.id] ?? []).sorted { $0.revision < $1.revision }
            var predecessor: InventoryObservation?
            for observation in history {
                guard observation.supersedesID == predecessor?.id,
                      observation.revision <= lot.revision,
                      predecessor.map({ $0.revision < observation.revision && $0.observedAt <= observation.observedAt }) ?? true else {
                    throw Failure.invalidProvenance
                }
                predecessor = observation
            }
            guard let latest = predecessor, latest.id == lot.observationID,
                  latest.count == lot.count, latest.observedAt == lot.confirmedAt,
                  sources[lot.id]?.source == lot.source else { throw Failure.invalidProvenance }
        }
        return Snapshot(state: final, lots: lots, reservations: claims,
            availability: try InventoryProjection.build(originID: final.workspaceID, lots: lots, reservations: claims, at: now),
            receiptAcquiredLots: acquiredLots.ids, loadedPayloadBytes: limits.payloadBytes - remainingBytes,
            observationCount: observationRows.count,
            lotPayloadBytes: Dictionary(uniqueKeysWithValues: lotRows.map { ($0.key.id, $0.payload.count) }),
            reservationPayloadBytes: Dictionary(uniqueKeysWithValues: claimRows.map { ($0.key.id, $0.payload.count) }))
    }

    /// A receipt captured directly in My Pantry has no delivered Pickup
    /// fragment. Only its verified original acquisition can establish that source.
    private func confirmedReceiptLots(_ lots: [InventoryLot], maximumBytes: Int) async throws -> (ids: Set<UUID>, bytes: Int) {
        var candidates: [UUID: InventoryLot] = [:]
        for lot in lots {
            guard case .receipt(_, let key) = lot.source,
                  key.sourceEventID.hasPrefix("receipt-acquisition/") else { continue }
            guard candidates.updateValue(lot, forKey: key.orderLineID) == nil else { throw Failure.invalidProvenance }
        }
        let ids = Array(candidates.keys), limit = InventoryPersistenceLimits.pageItems
        var confirmed = Set<UUID>(), bytes = 0
        for start in stride(from: 0, to: ids.count, by: limit) {
            let page = Array(ids[start..<min(start + limit, ids.count)])
            let rows = try await store.acquisitionRows(lineIDs: page, firstRevisionOnly: true, limit: page.count)
            try requireAccess()
            for row in rows {
                bytes += row.payload.count
                guard bytes <= maximumBytes else { throw InventoryError.capacity }
                let fact = try PantryAcquisitionCodec.record(row)
                try PantryAcquisitionCodec.validateLot(fact, lot: candidates[fact.lineID])
                if case .added = fact.stock { confirmed.insert(fact.lotID) }
            }
        }
        return (confirmed, bytes)
    }

    func review(_ command: InventoryCommand, at now: Date) async throws -> Review {
        try requireAccess()
        guard command.originID == store.workspaceID else { throw Failure.wrongWorkspace }
        let before = try await load(at: now)
        return try preparedChange(command, before: before, at: now).review
    }

    private func preparedChange(_ command: InventoryCommand, before: Snapshot, at now: Date) throws
        -> (review: Review, writes: [InventoryWrite]) {
        let lot: InventoryLot
        let after: InventoryProjection
        let writes: [InventoryWrite]
        if case let .reservation(edit) = command.change {
            guard let current = before.lots.first(where: { $0.id == command.lotID }) else { throw InventoryError.stale }
            let (claim, projection) = try edit.prepare(command: command, lots: before.lots, reservations: before.reservations,
                                                       before: before.availability, at: now)
            lot = current
            after = projection
            writes = [try PantryPersistenceCodec.write(claim, expectedRevision: edit.previousRevision)]
        } else {
            let prepared = try InventoryEngine.prepare(command, current: before.lots.first { $0.id == command.lotID }, at: now)
            lot = prepared.lot
            after = try InventoryProjection.build(originID: before.state.workspaceID,
                lots: before.lots.filter { $0.id != command.lotID } + [lot], reservations: before.reservations, at: now)
            writes = try PantryPersistenceCodec.writes(prepared)
        }
        try validateCapacity(of: writes, replacing: before)
        return (Review(command: command, before: before, proposedLot: lot, proposedAvailability: after), writes)
    }

    /// The original command and reviewed global revision are the durable retry input.
    /// A stale review is never silently rebased. A successful old receipt reloads today's
    /// heads rather than restoring the old proposed count over intervening changes.
    func apply(_ command: InventoryCommand, reviewedInventoryRevision: Int64, at now: Date) async throws -> Result {
        try requireAccess()
        let lease = try mutationGate?.beginWrite()
        defer { if let lease { mutationGate?.endWrite(lease) } }
        return try await applyUnlocked(command, reviewedInventoryRevision: reviewedInventoryRevision, at: now)
    }

    private func applyUnlocked(_ command: InventoryCommand, reviewedInventoryRevision: Int64, at now: Date,
                               checkPending: () throws -> Void = {}) async throws -> Result {
        try requireAccess()
        try checkPending()
        guard command.originID == store.workspaceID else { throw Failure.wrongWorkspace }
        let request = try PantryPersistenceCodec.request(command, inventoryRevision: reviewedInventoryRevision)
        if let prior = try await store.inventoryCommittedOperation(id: command.id, request: request) {
            try requireAccess()
            return Result(receipt: prior, current: try await load(at: now), replayed: true)
        }
        let current = try await load(at: now)
        guard current.state.revision == reviewedInventoryRevision else { throw ComparisonStoreError.staleInventory }
        let writes = try preparedChange(command, before: current, at: now).writes
        let batch = InventoryBatch(workspaceID: current.state.workspaceID, operationID: command.id,
            expectedRevision: reviewedInventoryRevision, request: request, writes: writes)
        try requireAccess()
        try checkPending()
        let receipt = try await store.commitInventory(batch, at: now)
        try requireAccess()
        return Result(receipt: receipt, current: try await load(at: now), replayed: false)
    }

    /// An editor may publish an editable snapshot only after checking the journal
    /// under the same lease as this complete read. Competing confirmations fail
    /// closed and are restored on the next load.
    func loadForEditing(at now: Date) async throws -> Snapshot {
        try requireAccess()
        guard let pendingStore else { return try await load(at: now) }
        guard let mutationGate, pendingStore.inventoryWorkspaceID == store.workspaceID else { throw Failure.pendingUnavailable }
        let lease = try mutationGate.beginExclusiveWrite(); defer { mutationGate.endExclusiveWrite(lease) }
        guard try pendingStore.read() == nil else { throw PantryPendingStore.Failure.occupied }
        let current = try await load(at: now)
        try requireAccess()
        guard try pendingStore.read() == nil else { throw PantryPendingStore.Failure.occupied }
        return current
    }

    func readPending() throws -> PantryPendingStore.Entry? {
        try requireAccess()
        guard let pendingStore else { return nil }
        guard pendingStore.inventoryWorkspaceID == store.workspaceID, mutationGate != nil else { throw Failure.pendingUnavailable }
        return try pendingStore.read()
    }

    /// Persist reviewed identities before the first possible database mutation.
    /// A failed atomic-write/attribute step is reconciled by readPending; never
    /// replace a possibly written intent with a newly generated command.
    func stagePending(_ command: InventoryCommand, reviewedInventoryRevision: Int64) throws -> PantryPendingStore.Entry {
        try requireAccess()
        guard let pendingStore, let mutationGate,
              pendingStore.inventoryWorkspaceID == store.workspaceID else { throw Failure.pendingUnavailable }
        let lease = try mutationGate.beginExclusiveWrite(); defer { mutationGate.endExclusiveWrite(lease) }
        return try pendingStore.save(command: command, reviewedInventoryRevision: reviewedInventoryRevision)
    }

    /// Restore/recognize before editable state. A cached intent whose journal was
    /// cleared by another model is reconciled against SQLite, never recreated.
    /// Discard proves receipt absence while the same lease excludes resumed writers.
    func recoverPending(_ expected: PantryPendingStore.Entry, at now: Date,
                        commitIfUnapplied: Bool = false, discardIfUnapplied: Bool = false) async throws -> PendingRecovery {
        try requireAccess()
        guard let pendingStore, let mutationGate,
              pendingStore.inventoryWorkspaceID == store.workspaceID,
              expected.command.originID == store.workspaceID else { throw Failure.pendingUnavailable }
        let lease = try mutationGate.beginExclusiveWrite(); defer { mutationGate.endExclusiveWrite(lease) }
        let original = try pendingStore.read()
        if let original {
            guard original.hasSameOriginal(as: expected),
                  expected.acknowledgment == nil || expected.acknowledgment == original.acknowledgment else {
                throw PantryPendingStore.Failure.operationConflict
            }
            try pendingStore.ensureProtected(expected: original)
        }
        func unchanged() throws {
            try requireAccess()
            guard try pendingStore.read() == original else { throw PantryPendingStore.Failure.operationConflict }
        }
        let request = try PantryPersistenceCodec.request(expected.command, inventoryRevision: expected.reviewedInventoryRevision)
        let receipt = try await store.inventoryCommittedOperation(id: expected.operationID, request: request)
        try unchanged()
        if let receipt {
            let current = try await load(at: now)
            try unchanged()
            return .committed(original, Result(receipt: receipt, current: current, replayed: true))
        }
        guard expected.acknowledgment == nil, original?.acknowledgment == nil else {
            throw PantryPendingStore.Failure.operationConflict
        }
        guard let original else {
            let current = try await load(at: now)
            try unchanged()
            return .cleared(current)
        }
        if discardIfUnapplied {
            try unchanged()
            try pendingStore.discardUnapplied(expected: original)
            let current = try await load(at: now)
            try requireAccess()
            guard try pendingStore.read() == nil else { throw PantryPendingStore.Failure.operationConflict }
            return .cleared(current)
        }
        if commitIfUnapplied {
            let result = try await applyUnlocked(original.command, reviewedInventoryRevision: original.reviewedInventoryRevision,
                                                 at: now, checkPending: unchanged)
            try unchanged()
            return .committed(original, result)
        }
        let current = try await load(at: now)
        try unchanged()
        return .waiting(original, current)
    }

    /// Only after the model adopts current state, persist recognition before
    /// cleanup. A failed removal retains the acknowledged exact original intent.
    func finishPendingAdoption(_ expected: PantryPendingStore.Entry, result: Result) throws {
        try requireAccess()
        guard let pendingStore, let mutationGate,
              pendingStore.inventoryWorkspaceID == store.workspaceID else { throw Failure.pendingUnavailable }
        let lease = try mutationGate.beginExclusiveWrite(); defer { mutationGate.endExclusiveWrite(lease) }
        let acknowledged = try pendingStore.acknowledgeAdoption(expected: expected, receipt: result.receipt,
                                                              currentInventoryRevision: result.current.state.revision)
        try requireAccess()
        try pendingStore.clearAcknowledged(expected: acknowledged)
        try requireAccess()
    }

    /// Shared by single-food edits and atomic shopping deltas. Call after validating
    /// the proposed graph and before committing against this exact global revision.
    /// Observation/source rows are append-only; mutable heads replace their old bytes.
    func validateCapacity(of writes: [InventoryWrite], replacing snapshot: Snapshot, additionalPayloadBytes: Int = 0) throws {
        try requireAccess()
        guard snapshot.state.workspaceID == store.workspaceID else { throw Failure.wrongWorkspace }
        var seen = Set<InventoryRecordKey>()
        var bytes = snapshot.loadedPayloadBytes + additionalPayloadBytes
        var observations = snapshot.observationCount
        var lots = snapshot.lots.count
        var reservations = snapshot.reservations.count
        for write in writes {
            let record = write.record
            guard seen.insert(record.key).inserted else { throw InventoryError.duplicateIdentity }
            switch record.key.kind {
            case .lot:
                let old = snapshot.lotPayloadBytes[record.key.id]
                bytes += record.payload.count - (old ?? 0)
                if old == nil { lots += 1 }
            case .reservation:
                let old = snapshot.reservationPayloadBytes[record.key.id]
                bytes += record.payload.count - (old ?? 0)
                if old == nil { reservations += 1 }
            case .observation:
                guard write.expectedRevision == 0 else { throw Failure.invalidProvenance }
                observations += 1
                bytes += record.payload.count
            case .sourceLink:
                guard write.expectedRevision == 0 else { throw Failure.invalidProvenance }
                bytes += record.payload.count
            case .event, .intent: break
            }
        }
        guard observations <= limits.observations, bytes <= limits.payloadBytes,
              lots <= InventoryProjection.maximumLots,
              reservations <= InventoryProjection.maximumReservations else { throw InventoryError.capacity }
    }

    private func records(_ kind: InventoryRecordKind, maximum: Int, maximumBytes: Int) async throws -> [InventoryRecord] {
        var result: [InventoryRecord] = []
        var cursor: UUID?
        var bytes = 0
        while true {
            let page = try await store.inventoryRecords(kind: kind, after: cursor, limit: InventoryPersistenceLimits.pageItems)
            try requireAccess()
            bytes += page.reduce(0) { $0 + $1.payload.count }
            guard result.count + page.count <= maximum, bytes <= maximumBytes else { throw InventoryError.capacity }
            result.append(contentsOf: page)
            guard page.count == InventoryPersistenceLimits.pageItems else { return result }
            cursor = page.last?.key.id
        }
    }

    func pricePage(after prior: PantryPricePage? = nil) async throws -> PantryPricePage {
        try requireAccess()
        let state = try await store.inventoryState()
        guard state.active, prior.map({ $0.state == state }) ?? true else { throw PantryReceiptError.stale }
        let limit = 25
        let prices = prior == nil || prior?.nextStandalone != nil
            ? try await store.priceRows(after: prior?.nextStandalone, limit: limit + 1) : []
        try requireAccess()
        let receipts = prior == nil || prior?.nextReceipt != nil
            ? try await store.acquisitionRows(currentOnly: true, after: prior?.nextReceipt, limit: limit + 1) : []
        let current = try await store.inventoryState()
        try requireAccess()
        guard current == state else { throw PantryReceiptError.stale }
        let pricePage = prices.prefix(limit)
        let receiptPage = receipts.prefix(limit)
        return try .init(standalone: pricePage.map(PantryPriceCodec.evidence),
                         receipts: receiptPage.map { try PrivatePriceEvidence(receipt: PantryAcquisitionCodec.record($0)) },
                         nextStandalone: prices.count > limit ? pricePage.last : nil,
                         nextReceipt: receipts.count > limit ? receiptPage.last?.id : nil, state: state)
    }

    func recordedPriceRevision(_ current: PrivatePriceEvidence, revision: Int64, expected: InventoryState) async throws -> PrivatePriceEvidence {
        try requireAccess()
        guard expected.active, expected.workspaceID == originID, revision > 0, revision <= current.revision else {
            throw PantryReceiptError.stale
        }
        let result: PrivatePriceEvidence
        if case .paidReceipt(let receipt) = current.source {
            guard let row = try await store.acquisitionRows(receiptID: receipt.receiptID, lineIDs: [current.id], revision: revision, limit: 1).first else { throw PantryReceiptError.stale }
            result = try PrivatePriceEvidence(receipt: PantryAcquisitionCodec.record(row))
        } else {
            guard let row = try await store.priceRows(id: current.id, revision: revision, latestOnly: false, limit: 1).first else { throw PantryReceiptError.stale }
            result = try PantryPriceCodec.evidence(row)
        }
        guard try await store.inventoryState() == expected else { throw PantryReceiptError.stale }
        try requireAccess()
        return result
    }

    func priceAdjustments(for id: UUID, expected: InventoryState) async throws -> [PrivatePriceEvidence] {
        try requireAccess()
        var result: [PrivatePriceEvidence] = []
        var cursor: InventoryPriceRow?
        var bytes = 0
        repeat {
            let page = try await store.priceRows(adjustmentsFor: id, after: cursor)
            try requireAccess()
            for row in page {
                bytes += row.payload.count
                guard bytes <= limits.payloadBytes, result.count < limits.observations else { throw InventoryError.capacity }
                result.append(try PantryPriceCodec.evidence(row))
            }
            cursor = page.count == 100 ? page.last : nil
        } while cursor != nil
        guard try await store.inventoryState() == expected else { throw PantryReceiptError.stale }
        try requireAccess()
        return result
    }

    func savePrice(_ evidence: PrivatePriceEvidence, expected: InventoryState, at now: Date) async throws {
        try requireAccess()
        guard expected.active, expected.workspaceID == originID else { throw PantryReceiptError.stale }
        let row = try PantryPriceCodec.row(evidence)
        let existing = try await store.priceRows(id: row.id, limit: 1)
        try requireAccess()
        if existing.first == row { return }
        guard (existing.first?.revision ?? 0) < Int64.max, (existing.first?.revision ?? 0) + 1 == row.revision else { throw PantryReceiptError.stale }
        if let previous = try existing.first.map(PantryPriceCodec.evidence) {
            guard previous.source == evidence.source, previous.foodID == evidence.foodID,
                  previous.linkedLotID == evidence.linkedLotID else { throw PantryReceiptError.invalid }
        }
        if case .adjustment(let target, _, let kind) = evidence.source {
            let paid: PrivatePriceEvidence
            if let standalone = try await store.priceRows(id: target, limit: 1).first {
                paid = try PantryPriceCodec.evidence(standalone)
            } else {
                try requireAccess()
                guard let receipt = try await store.acquisitionRows(lineIDs: [target], latestForLine: true, limit: 1).first else {
                    throw PantryReceiptError.stale
                }
                paid = try .init(receipt: PantryAcquisitionCodec.record(receipt))
            }
            try requireAccess()
            try evidence.validateAdjustmentTarget(paid)
            guard let paidAmount = paid.amountMinor else { throw PantryReceiptError.stale }
            if kind != .unallocatedCredit {
                let current = try await priceAdjustments(for: target, expected: expected)
                let net = try paid.netAmount(adjustments: current.filter { $0.id != evidence.id } + [evidence])
                guard let net, (0...paidAmount).contains(net) else { throw PantryReceiptError.invalid }
            }
        }
        let id = ReceiptAcquisition.identity(["price-evidence", originID.uuidString, row.id.uuidString, String(row.revision)])
        let batch = InventoryBatch(workspaceID: originID, operationID: id, expectedRevision: expected.revision,
                                   request: Data(SHA256.hash(data: row.payload)), price: row)
        try await commitReviewedBatch(batch, workspaceID: expected.workspaceID, revision: expected.revision, at: now)
    }

    func acquisitionHistory(receiptID: UUID? = nil, after: UUID? = nil, limit: Int = 30) async throws -> [ReceiptAcquisition] {
        try requireAccess()
        let rows = try await store.acquisitionRows(receiptID: receiptID, after: after, limit: limit)
        try requireAccess()
        return try rows.map(PantryAcquisitionCodec.record)
    }

    func reviewReceipt(_ draft: ReceiptImportDraft, expected: InventoryState, at now: Date) async throws -> PantryReceiptReview {
        let before = try await loadForEditing(at: now)
        guard before.state == expected else { throw PantryReceiptError.stale }
        var matched = Set<UUID>()
        for identity in draft.evidenceIdentities {
            if let id = try await store.acquisitionReceiptID(for: identity) { matched.insert(id) }
            try requireAccess()
        }
        guard matched.count < 2 else { throw PantryReceiptError.changedEvidence }
        let receiptID = matched.first ?? draft.receiptID
        if draft.lines.contains(where: { $0.treatment != .skip && $0.appliedAlias != nil }) {
            let allowed = try await receiptAliases(merchant: draft.merchant, language: draft.language)
            for line in draft.lines where line.treatment != .skip {
                guard let alias = line.appliedAlias else { continue }
                guard allowed.contains(alias), alias.product == line.name,
                      ReceiptImportDraft.containsWording(alias.wording, in: line.original) else { throw PantryReceiptError.stale }
            }
        }
        let facts = try draft.facts(receiptID: receiptID, snapshot: before, at: now)
        var prior: [UUID: ReceiptAcquisition] = [:], cursor: UUID?
        repeat {
            let page = try await acquisitionHistory(receiptID: receiptID, after: cursor, limit: 200)
            for value in page where value.revision == 1 {
                guard value.merchant == facts.first?.merchant, value.purchaseDate == facts.first?.purchaseDate else { throw PantryReceiptError.changedEvidence }
                if let old = value.transactionReference, let new = facts.first?.transactionReference, old != new { throw PantryReceiptError.changedEvidence }
                prior[value.lineID] = value
            }
            cursor = page.count == 200 ? page.last?.id : nil
        } while cursor != nil
        var writes: [InventoryWrite] = [], rows: [InventoryAcquisitionRow] = []
        var existing = Set<UUID>(), acquisitionBytes = 0
        for fact in facts {
            if let old = prior[fact.lineID] {
                // Another image of the same confirmed transaction can differ.
                // Never silently replace the original evidence or increase stock.
                guard old.name == fact.name, old.originalLine == fact.originalLine, old.received == fact.received,
                      old.usable == fact.usable, old.paidLineTotal == fact.paidLineTotal, old.stock == fact.stock,
                      old.purchaseDate == fact.purchaseDate, old.merchant == fact.merchant else { throw PantryReceiptError.changedEvidence }
                existing.insert(fact.lineID)
                continue
            }
            if case .added(let location) = fact.stock {
                let key = ReceiptKey(sourceEventID: "receipt-acquisition/" + fact.receiptID.uuidString, orderLineID: fact.lineID,
                    branchID: fact.merchant, segmentID: String(fact.ordinal))
                let command = InventoryCommand(id: ReceiptAcquisition.identity(["create", fact.lineID.uuidString]),
                    originID: originID, lotID: fact.lotID, eventID: ReceiptAcquisition.identity(["event", fact.lineID.uuidString]),
                    expectedRevision: nil, occurredAt: now, change: .create(.init(foodID: fact.foodID, name: fact.name,
                        source: .receipt(originID: originID, key: key), location: location, unit: fact.usable.unit,
                        count: .exact(fact.usable), observedAt: now), observationID: ReceiptAcquisition.identity(["count", fact.lineID.uuidString])))
                writes += try PantryPersistenceCodec.writes(InventoryEngine.prepare(command, current: nil, at: now))
            }
            let row = try PantryAcquisitionCodec.row(fact)
            if case .added = fact.stock { acquisitionBytes += row.payload.count }
            rows.append(row)
        }
        try validateCapacity(of: writes, replacing: before, additionalPayloadBytes: acquisitionBytes)
        try requireAccess()
        guard try await store.inventoryState() == before.state else { throw PantryReceiptError.stale }
        try requireAccess()
        let id = UUID()
        let batch = rows.isEmpty ? nil : try InventoryBatch(workspaceID: originID, operationID: id,
            expectedRevision: expected.revision, request: Data(SHA256.hash(data: PantryAcquisitionCodec.data(rows))),
            writes: writes, acquisitions: rows)
        return .init(id: id, workspaceID: originID, revision: expected.revision, facts: facts, existing: existing, batch: batch)
    }

    func applyReceipt(_ review: PantryReceiptReview, at now: Date) async throws {
        try requireAccess()
        try await commitReviewedBatch(review.batch, workspaceID: review.workspaceID, revision: review.revision, at: now)
    }

    private func commitReviewedBatch(_ batch: InventoryBatch?, workspaceID: UUID, revision: Int64, at now: Date) async throws {
        try requireAccess()
        guard workspaceID == originID else { throw PantryReceiptError.stale }
        let lease = try mutationGate?.beginExclusiveWrite()
        defer { if let lease { mutationGate?.endExclusiveWrite(lease) } }
        if let pendingStore, try pendingStore.read() != nil { throw Failure.pendingUnavailable }
        guard let batch else {
            guard try await store.inventoryState().revision == revision else { throw PantryReceiptError.stale }
            try requireAccess()
            return
        }
        _ = try await store.commitInventory(batch, at: now)
        try requireAccess()
    }

    func receiptAliases(merchant: String? = nil, language: String? = nil) async throws -> [InventoryReceiptAlias] {
        try requireAccess()
        guard let aliasPersonaID else { throw Failure.unauthorized }
        let aliases = try await store.receiptAliases(personaID: aliasPersonaID, merchant: merchant, language: language)
        try requireAccess()
        return aliases
    }

    func rememberReceiptAlias(_ source: ReceiptAcquisition, wording: String, language: String, expected: InventoryState, at now: Date) async throws {
        try requireAccess()
        guard let aliasPersonaID, expected.workspaceID == originID else { throw Failure.unauthorized }
        let records = try await store.acquisitionRows(receiptID: source.receiptID, lineIDs: [source.lineID], firstRevisionOnly: true, limit: 1)
        try requireAccess()
        guard let row = records.first else { throw PantryReceiptError.stale }
        let original = try PantryAcquisitionCodec.record(row)
        let trimmed = wording.trimmingCharacters(in: .whitespacesAndNewlines)
        guard source.lotID == original.lotID, source.foodID == original.foodID, source.name == original.name,
              source.originalLine == original.originalLine, original.merchant == source.merchant,
              trimmed.unicodeScalars.contains(where: CharacterSet.letters.contains),
              ReceiptImportDraft.containsWording(trimmed, in: original.originalLine) else { throw PantryReceiptError.invalid }
        let alias = InventoryReceiptAlias(personaID: aliasPersonaID, merchant: original.merchant, language: language, wording: trimmed,
            product: original.name, foodID: original.foodID, sourceID: original.id, lotID: original.lotID)
        let prior = try await receiptAliases(merchant: original.merchant, language: language)
        if let existing = prior.first(where: { InventoryReceiptAlias.key($0.wording) == InventoryReceiptAlias.key(trimmed) }) {
            guard try await store.inventoryState() == expected else { throw PantryReceiptError.stale }
            try requireAccess()
            guard existing.foodID == alias.foodID, existing.product == alias.product else { throw PantryReceiptError.changedEvidence }
            return
        }
        try await editReceiptAlias(.remember(alias), expected: expected, at: now)
    }

    func forgetReceiptAliases(_ aliases: [InventoryReceiptAlias], expected: InventoryState, at now: Date) async throws {
        try requireAccess()
        guard let aliasPersonaID, aliases.allSatisfy({ $0.personaID == aliasPersonaID }) else { throw Failure.unauthorized }
        try await editReceiptAlias(.forget(personaID: aliasPersonaID, ids: aliases.map(\.id)), expected: expected, at: now)
    }

    private func editReceiptAlias(_ edit: InventoryReceiptAliasEdit, expected: InventoryState, at now: Date) async throws {
        let id = UUID()
        let request = try Data(SHA256.hash(data: PantryAcquisitionCodec.data(edit)))
        let batch = InventoryBatch(workspaceID: originID, operationID: id, expectedRevision: expected.revision, request: request, aliasEdit: edit)
        try await commitReviewedBatch(batch, workspaceID: expected.workspaceID, revision: expected.revision, at: now)
    }

    func latestReceiptRevision(_ original: ReceiptAcquisition) async throws -> ReceiptAcquisition {
        try requireAccess()
        let rows = try await store.acquisitionRows(receiptID: original.receiptID, lineIDs: [original.lineID], latestForLine: true, limit: 1)
        try requireAccess()
        guard let row = rows.first else { throw PantryReceiptError.stale }
        return try PantryAcquisitionCodec.record(row)
    }

    func correctPaidTotal(_ original: ReceiptAcquisition, total: Money?, state: InventoryState, at now: Date) async throws {
        try requireAccess()
        let corrected = try original.correctingPaidTotal(total)
        let latest = try await latestReceiptRevision(original)
        guard latest == original || latest == corrected else { throw PantryReceiptError.stale }
        let row = try PantryAcquisitionCodec.row(corrected)
        let batch = try InventoryBatch(workspaceID: state.workspaceID, operationID: corrected.id,
            expectedRevision: state.revision, request: PantryAcquisitionCodec.data(corrected), writes: [], acquisitions: [row])
        try await applyReceipt(.init(id: corrected.id, workspaceID: state.workspaceID, revision: state.revision,
            facts: [corrected], existing: [], batch: batch), at: now)
    }

    var permitsReceiptSource: Bool { authorize() }

    private func requireAccess() throws {
        guard authorize() else { throw Failure.unauthorized }
        guard (1...ReadLimits.standard.payloadBytes).contains(limits.payloadBytes),
              (1...ReadLimits.standard.observations).contains(limits.observations) else {
            throw InventoryError.invalid("readLimits")
        }
    }
}
