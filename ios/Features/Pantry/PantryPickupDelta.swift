import Foundation
import CryptoKit
import CoreDomain
import LocalStore

extension PantryLegacyMigration.SourceHead {
    init(id: UUID, revision: Int64, payload: Data, savedAt: Date) {
        self.id = id; self.revision = revision; self.payload = payload; self.savedAt = savedAt
    }
}

/// Prepares one atomic legacy/canonical write from complete before/after source
/// sets. Mapped legacy values identify deltas; they never replace today's pantry.
@MainActor enum PantryPickupDelta {
    enum Failure: Error, Equatable {
        case invalidSource, staleSource, inactive, missingCanonicalSource, ambiguousPhysicalChange
        case removedSourceHead, invalidReceiptHistory, multipleObservations, capacity
    }
    struct Request: Codable, Equatable {
        let version: Int
        let operationID: UUID
        let originID: UUID
        let inventoryRevision: Int64
        let priorDigest: Data
        let proposedDigest: Data
        let ledgerOriginID: UUID?
        let ledgerRevision: Int64?
        let ledgerDigest: Data?
    }
    struct Review {
        let request: Request
        let preparedAt: Date
        let changedHeads: [PantryLegacyMigration.SourceHead]
        let batch: InventoryBatch
        let lots: [InventoryLot]
        let reservations: [InventoryReservation]
        let availability: InventoryProjection
        let affectedReservations: [InventoryReservationCoverage]
    }
    private struct HeadBinding: Codable {
        let id: UUID
        let revision: Int64
        let savedAt: Date
        let payloadDigest: Data
    }
    private struct ReceiptEvidence: Equatable {
        let fragment: ReceiptFragment
        let observations: [UsableObservation]
    }

    /// Persist these immutable bytes with the caller's pending command. On retry,
    /// look up inventoryCommittedOperation before recomputing against new heads.
    static func request(operationID: UUID, originID: UUID, inventoryRevision: Int64,
                        prior: [PantryLegacyMigration.SourceHead], proposed: [PantryLegacyMigration.SourceHead],
                        ledger: PantryLegacyMigration.LedgerContext) throws -> Request {
        guard inventoryRevision >= 0 else { throw Failure.invalidSource }
        func fingerprint(_ heads: [PantryLegacyMigration.SourceHead]) throws -> Data {
            guard heads.count <= PantryLegacyMigration.maximumHeads,
                  heads.reduce(0, { $0 + $1.payload.count }) <= PantryLegacyMigration.maximumSourceBytes,
                  Set(heads.map(\.id)).count == heads.count else { throw Failure.capacity }
            let bindings = heads.sorted { $0.id.uuidString < $1.id.uuidString }.map {
                HeadBinding(id: $0.id, revision: $0.revision, savedAt: $0.savedAt, payloadDigest: digest($0.payload))
            }
            return digest(try encode(bindings))
        }
        let ledgerOrigin: UUID?, ledgerRevision: Int64?, ledgerDigest: Data?
        switch ledger {
        case .available(let origin, let revision, let workspace):
            guard revision >= 0 else { throw Failure.invalidSource }
            try workspace.validate()
            ledgerOrigin = origin; ledgerRevision = revision; ledgerDigest = digest(try encode(workspace))
        case .unavailable: ledgerOrigin = nil; ledgerRevision = nil; ledgerDigest = nil
        }
        return Request(version: 1, operationID: operationID, originID: originID, inventoryRevision: inventoryRevision,
            priorDigest: try fingerprint(prior), proposedDigest: try fingerprint(proposed),
            ledgerOriginID: ledgerOrigin, ledgerRevision: ledgerRevision, ledgerDigest: ledgerDigest)
    }
    static func requestBytes(_ request: Request) throws -> Data {
        let bytes = try encode(request)
        guard bytes.count <= InventoryPersistenceLimits.requestBytes else { throw Failure.capacity }
        return bytes
    }

    /// Caller must provide the complete current source set and retain the reviewed
    /// ledger binding under its mutation gate. Capacity is checked by the repository
    /// commit wrapper with validateCapacity(of:replacing:) before committing batch.
    static func prepare(operationID: UUID, originID: UUID,
                        prior: [PantryLegacyMigration.SourceHead], proposed: [PantryLegacyMigration.SourceHead],
                        inventory: PantryRepository.Snapshot, ledger: PantryLegacyMigration.LedgerContext,
                        at now: Date) throws -> Review {
        guard inventory.state.active, inventory.state.workspaceID == originID else { throw Failure.inactive }
        let request = try request(operationID: operationID, originID: originID, inventoryRevision: inventory.state.revision,
            prior: prior, proposed: proposed, ledger: ledger)
        let beforePlan = try PantryLegacyMigration.map(originID: originID, heads: prior, ledger: ledger, at: now)
        let afterPlan = try PantryLegacyMigration.map(originID: originID, heads: proposed, ledger: ledger, at: now)
        let beforeHeads = Dictionary(uniqueKeysWithValues: prior.map { ($0.id, $0) })
        let afterHeads = Dictionary(uniqueKeysWithValues: proposed.map { ($0.id, $0) })
        guard Set(beforeHeads.keys).isSubset(of: Set(afterHeads.keys)) else { throw Failure.removedSourceHead }
        let before = try journeys(prior), after = try journeys(proposed)
        let changed = proposed.filter { beforeHeads[$0.id] != $0 }
        guard !changed.isEmpty else { throw Failure.invalidSource }
        for head in changed {
            let oldRevision = beforeHeads[head.id]?.revision ?? 0
            let oldJourneyRevision = before[head.id]?.revision ?? 0
            guard oldRevision < Int64.max, head.revision == oldRevision + 1,
                  oldJourneyRevision < Int64.max, after[head.id]?.revision == oldJourneyRevision + 1,
                  head.savedAt == now else { throw Failure.staleSource }
        }
        var lots = Dictionary(uniqueKeysWithValues: inventory.lots.map { ($0.id, $0) })
        var sourceIDs = Dictionary(uniqueKeysWithValues: inventory.lots.map { ($0.source, $0.id) })
        let beforeSources = Set(beforePlan.lots.map(\.source))
        var revisions: [InventorySource: InventoryLotRevision] = [:]
        var manualChanges: [InventorySource: ConfirmedStockLot] = [:]
        var affectedNeedIDs = Set<UUID>()
        for head in changed {
            let old = before[head.id], next = after[head.id]!
            let oldManual = Dictionary(uniqueKeysWithValues: (old?.stockLots ?? []).map { ($0.id, $0) })
            for lot in next.stockLots {
                // A new reference to an existing physical ID is a carried copy,
                // not proof that its old numeric amount supersedes today's count.
                guard let previous = oldManual[lot.id], previous != lot else { continue }
                let source = InventorySource.manual(originID: originID, sourceID: lot.id)
                if let another = manualChanges[source], another != lot { throw Failure.ambiguousPhysicalChange }
                manualChanges[source] = lot
                let observation: InventoryCountRevision?
                if previous.usable != lot.usable || previous.confirmedAt != lot.confirmedAt {
                    observation = .init(count: .exact(lot.usable), observationID: try identity(operationID, "observation", source), observedAt: lot.confirmedAt)
                } else { observation = nil }
                let patch = InventoryLotRevision(observation: observation,
                    foodID: previous.foodID == lot.foodID ? nil : lot.foodID,
                    name: previous.name == lot.name ? nil : lot.name,
                    useFirst: (previous.useFirst == true) == (lot.useFirst == true) ? nil : lot.useFirst == true,
                    location: previous.source == lot.source ? nil : (lot.source == .freezer ? .freezer : .cupboard))
                if patch.observation != nil || patch.foodID != nil || patch.name != nil || patch.useFirst != nil || patch.location != nil {
                    revisions[source] = patch
                }
            }
            let oldNeeds = Dictionary(uniqueKeysWithValues: (old?.physicalStockNeeds ?? []).map { ($0.id, $0) })
            let newNeeds = Dictionary(uniqueKeysWithValues: next.physicalStockNeeds.map { ($0.id, $0) })
            for id in Set(oldNeeds.keys).union(newNeeds.keys) where oldNeeds[id] != newNeeds[id] { affectedNeedIDs.insert(id) }
            let oldCarryovers = Dictionary(uniqueKeysWithValues: (old?.awayCarryovers ?? []).map { ($0.id, $0) })
            let newCarryovers = Dictionary(uniqueKeysWithValues: next.awayCarryovers.map { ($0.id, $0) })
            for id in Set(oldCarryovers.keys).union(newCarryovers.keys) where oldCarryovers[id] != newCarryovers[id] {
                if let value = oldCarryovers[id] { affectedNeedIDs.insert(value.intent.plan.link.reservationID) }
                if let value = newCarryovers[id] { affectedNeedIDs.insert(value.intent.plan.link.reservationID) }
            }
        }
        let oldReceipts = try receiptEvidence(before), newReceipts = try receiptEvidence(after)
        guard Set(oldReceipts.keys).isSubset(of: Set(newReceipts.keys)) else { throw Failure.invalidReceiptHistory }
        for (key, current) in newReceipts {
            guard let original = oldReceipts[key] else { continue }
            guard original.fragment == current.fragment else { throw Failure.invalidReceiptHistory }
            let oldValues = Dictionary(uniqueKeysWithValues: original.observations.map { ($0.id, $0) })
            let newValues = Dictionary(uniqueKeysWithValues: current.observations.map { ($0.id, $0) })
            guard oldValues.allSatisfy({ newValues[$0.key] == $0.value }) else { throw Failure.invalidReceiptHistory }
            let appended = current.observations.filter { oldValues[$0.id] == nil }
            guard appended.count <= 1 else { throw Failure.multipleObservations }
            guard let observation = appended.first else { continue }
            guard observation.supersedesID == (try latestReceiptObservation(original.observations))?.id,
                  (try latestReceiptObservation(current.observations))?.id == observation.id else { throw Failure.invalidReceiptHistory }
            let source = InventorySource.receipt(originID: originID, key: key)
            let count: InventoryCount = observation.confirmedMatchToOrderLine && current.fragment.disposition != .wrongItem
                ? .exact(observation.usable) : .unknown
            revisions[source] = .init(observation: .init(count: count,
                observationID: try identity(operationID, "observation", source), observedAt: observation.confirmedAt))
        }
        var writes: [InventoryWrite] = []
        for mapped in afterPlan.lots.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            if let id = sourceIDs[mapped.source] {
                guard let revision = revisions[mapped.source], let current = lots[id] else { continue }
                let command = InventoryCommand(id: operationID, originID: originID, lotID: id,
                    eventID: try identity(operationID, "event", mapped.source), expectedRevision: current.revision,
                    occurredAt: now, change: .revise(revision))
                let prepared = try InventoryEngine.prepare(command, current: current, at: now)
                writes += try PantryPersistenceCodec.writes(prepared); lots[id] = prepared.lot
            } else {
                guard !beforeSources.contains(mapped.source), lots[mapped.id] == nil else { throw Failure.missingCanonicalSource }
                let seed = InventoryLotSeed(foodID: mapped.foodID, name: mapped.name, source: mapped.source,
                    location: mapped.location, unit: mapped.unit, count: mapped.count, useFirst: mapped.useFirst, observedAt: mapped.confirmedAt)
                let command = InventoryCommand(id: operationID, originID: originID, lotID: mapped.id,
                    eventID: try identity(operationID, "event", mapped.source), expectedRevision: nil, occurredAt: now,
                    change: .create(seed, observationID: try identity(operationID, "observation", mapped.source)))
                let prepared = try InventoryEngine.prepare(command, current: nil, at: now)
                writes += try PantryPersistenceCodec.writes(prepared); lots[mapped.id] = prepared.lot; sourceIDs[mapped.source] = mapped.id
            }
        }
        var claims = Dictionary(uniqueKeysWithValues: inventory.reservations.map { ($0.id, $0) })
        let afterClaims = Dictionary(uniqueKeysWithValues: afterPlan.reservations.map { ($0.id, $0) })
        let links = beforePlan.claimLinks + afterPlan.claimLinks
        let affectedClaims = Set(links.filter { affectedNeedIDs.contains($0.legacyNeedID) }.map(\.reservationID))
        for id in affectedClaims.sorted(by: { $0.uuidString < $1.uuidString }) {
            let current = claims[id], proposed: InventoryReservation
            let revision = (current?.revision ?? 0).addingReportingOverflow(1)
            guard !revision.overflow else { throw DomainError.overflow }
            if let mapped = afterClaims[id] {
                let pin: UUID?
                if let oldID = mapped.lotID {
                    guard let source = afterPlan.lots.first(where: { $0.id == oldID })?.source,
                          let resolved = sourceIDs[source] else { throw Failure.missingCanonicalSource }
                    pin = resolved
                } else { pin = nil }
                proposed = InventoryReservation(id: id, originID: originID, revision: revision.partialValue,
                    foodID: mapped.foodID, lotID: pin, name: mapped.name, amount: mapped.amount,
                    priority: mapped.priority, state: mapped.state)
            } else {
                // Only a claim removed by an explicit surviving-source edit is
                // released. Removing an archived source head is refused above.
                guard let current else { throw Failure.missingCanonicalSource }
                proposed = InventoryReservation(id: id, originID: originID, revision: revision.partialValue,
                    foodID: current.foodID, lotID: current.lotID, name: current.name, amount: current.amount,
                    priority: current.priority, state: .released)
            }
            if let current, sameClaim(current, proposed) { continue }
            try proposed.validate()
            writes.append(.init(record: .init(key: .init(.reservation, id), revision: proposed.revision,
                payload: try encode(proposed), lotID: proposed.lotID), expectedRevision: current?.revision ?? 0))
            claims[id] = proposed
        }
        let resultingLots = lots.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let resultingClaims = claims.values.sorted { $0.id.uuidString < $1.id.uuidString }
        let availability = try InventoryProjection.build(originID: originID, lots: resultingLots, reservations: resultingClaims, at: now)
        let priorCoverage = Dictionary(uniqueKeysWithValues: inventory.availability.reservations.map { ($0.id, $0) })
        let comparisons = changed.map { InventoryComparisonEffect(action: .save, id: $0.id,
            expectedRevision: beforeHeads[$0.id]?.revision ?? 0, title: "Pickup", payload: $0.payload) }
        let batch = InventoryBatch(workspaceID: originID, operationID: operationID, expectedRevision: inventory.state.revision,
            request: try requestBytes(request), writes: writes, comparisons: comparisons)
        guard writes.count + comparisons.count <= InventoryPersistenceLimits.batchItems,
              writes.allSatisfy({ $0.record.payload.count <= InventoryPersistenceLimits.recordBytes }),
              batch.request.count + writes.reduce(0, { $0 + $1.record.payload.count + ($1.record.source?.sourceID.utf8.count ?? 0) }) +
                comparisons.reduce(0, { $0 + $1.payload.count + $1.title.utf8.count }) <= InventoryPersistenceLimits.batchBytes else { throw Failure.capacity }
        return Review(request: request, preparedAt: now, changedHeads: changed, batch: batch, lots: resultingLots, reservations: resultingClaims, availability: availability,
            affectedReservations: availability.reservations.filter { priorCoverage[$0.id] != $0 })
    }

    private static func journeys(_ heads: [PantryLegacyMigration.SourceHead]) throws -> [UUID: PickupJourney] {
        Dictionary(uniqueKeysWithValues: try heads.map { ($0.id, try JSONDecoder().decode(PickupJourney.self, from: $0.payload)) })
    }
    private static func receiptEvidence(_ journeys: [UUID: PickupJourney]) throws -> [ReceiptKey: ReceiptEvidence] {
        var result: [ReceiptKey: ReceiptEvidence] = [:]
        for journey in journeys.values {
            for receipt in journey.pickup?.receipts ?? [] {
                let values = journey.pickup?.usableObservations.filter { $0.receipt == receipt.key } ?? []
                if let previous = result[receipt.key] {
                    guard previous.fragment == receipt else { throw Failure.invalidReceiptHistory }
                    var observations = Dictionary(uniqueKeysWithValues: previous.observations.map { ($0.id, $0) })
                    for value in values {
                        if let old = observations[value.id], old != value { throw Failure.invalidReceiptHistory }
                        observations[value.id] = value
                    }
                    result[receipt.key] = ReceiptEvidence(fragment: receipt, observations: Array(observations.values))
                } else { result[receipt.key] = ReceiptEvidence(fragment: receipt, observations: values) }
            }
        }
        return result
    }
    /// Copied histories may repeat an observation, but never turn two branches
    /// into a new numeric count. Supersession, not array order, selects the head.
    private static func latestReceiptObservation(_ values: [UsableObservation]) throws -> UsableObservation? {
        guard !values.isEmpty else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        let roots = values.filter { $0.supersedesID == nil }
        guard roots.count == 1 else { throw Failure.invalidReceiptHistory }
        var current = roots[0], visited: Set<UUID> = [current.id]
        while true {
            let next = values.filter { $0.supersedesID == current.id }
            guard next.count <= 1 else { throw Failure.invalidReceiptHistory }
            guard let value = next.first else { break }
            guard visited.insert(value.id).inserted, value.confirmedAt >= current.confirmedAt else { throw Failure.invalidReceiptHistory }
            current = value
        }
        guard visited.count == byID.count else { throw Failure.invalidReceiptHistory }
        return current
    }
    private static func sameClaim(_ a: InventoryReservation, _ b: InventoryReservation) -> Bool {
        a.id == b.id && a.originID == b.originID && a.foodID == b.foodID && a.lotID == b.lotID &&
            a.name == b.name && a.amount == b.amount && a.priority == b.priority && a.state == b.state
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private static func identity<T: Encodable>(_ operation: UUID, _ role: String, _ value: T) throws -> UUID {
        var bytes = Array(SHA256.hash(data: Data("room-in-the-cart/pantry-pickup-delta/v1/\(operation.uuidString)/\(role)/".utf8) + (try encode(value))).prefix(16))
        bytes[6] = (bytes[6] & 15) | 128; bytes[8] = (bytes[8] & 63) | 128
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
