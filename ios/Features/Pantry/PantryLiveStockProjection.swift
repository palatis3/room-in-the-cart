import Foundation
import CoreDomain

/// A read-only bridge from one complete canonical allocation to a legacy journey.
/// This never reallocates stock, rewrites a journey, or treats copied lot amounts
/// as current. Composition must read mapping heads and inventory under its gate.
@MainActor
struct PantryLiveStockProjection {
    enum Failure: Error, Equatable {
        case inactive, wrongOrigin, missingJourney, invalidMapping, missingCanonicalClaim
        case missingCanonicalLot, ambiguousNeedMapping, ambiguousLotAlias, invalidClock
    }
    enum Issue: Equatable {
        case inventory(InventoryAvailabilityIssue)
        case receiptEvidenceUnresolved, receiptIneligible, receiptNotCurrent, releasedClaim
    }
    struct HeadRevision: Equatable { let journeyID: UUID; let storeRevision: Int64 }
    struct Basis: Equatable {
        let originID: UUID
        let inventoryRevision: Int64
        let journeyID: UUID?
        let sourceHeads: [HeadRevision]
    }
    struct Lot: Identifiable {
        /// Stable canonical identity; aliases are never additional physical lots.
        let id: UUID
        let readerID: UUID
        let current: InventoryLot
        let availability: InventoryLotAvailability
        let scopedLegacyLotIDs: [UUID]
        let scopedLegacyObservationIDs: [UUID]
        let receiptKey: ReceiptKey?
        let issues: [Issue]
        var free: Quantity? { issues.isEmpty ? availability.free : nil }
        var currentObservationID: UUID { current.observationID }
    }
    struct Demand: Identifiable {
        /// Original need identity understood by the selected journey's readers.
        let id: UUID
        let reservation: InventoryReservation
        let coverage: InventoryReservationCoverage?
        let legacyUnit: UnitOfMeasure
        let issues: [Issue]
        var canonicalReservationID: UUID { reservation.id }
        var pinnedCanonicalLotID: UUID? { reservation.lotID }
        var requested: Quantity? { reservation.amount }
        var confirmedBacked: Quantity? { issues.isEmpty ? coverage?.backed : nil }
        var shortfall: Quantity? { issues.isEmpty ? coverage?.shortfall : nil }
    }
    struct Allocation {
        let canonicalLotID: UUID
        let readerLotID: UUID
        let canonicalReservationID: UUID
        let legacyNeedID: UUID
        let foodID: UUID
        let quantity: Quantity
        let receiptKey: ReceiptKey?
        /// False edges explain provisional backing only. They cannot prove coverage.
        let isUsableForCoverage: Bool
    }

    let basis: Basis
    let asOf: Date
    let lots: [Lot]
    let demands: [Demand]
    /// Zero needs intentionally have no canonical reservation. Preserve their
    /// known zero requirement without inventing a physical lot or claim.
    let zeroNeeds: [StockNeed]
    let allocations: [Allocation]

    /// Already free after ALL shops' commitments. Feed these only to new-demand
    /// previews, without subtracting existing needs/pins from them a second time.
    var globallyFreeLots: [ConfirmedStockLot] { freeLots(identifiedBy: \.readerID) }
    var canonicalFreeLots: [ConfirmedStockLot] { freeLots(identifiedBy: \.id) }

    private func freeLots(identifiedBy id: KeyPath<Lot, UUID>) -> [ConfirmedStockLot] {
        lots.compactMap { row in
            guard let free = row.free, free.amount > .zero else { return nil }
            return ConfirmedStockLot(id: row[keyPath: id], foodID: row.current.foodID, name: row.current.name,
                usable: free, confirmedAt: row.current.confirmedAt,
                source: row.current.location == .freezer ? .freezer : .pantry, useFirst: row.current.useFirst)
        }
    }

    func lot(canonicalID: UUID) -> Lot? { lots.first { $0.id == canonicalID } }
    func lot(readerID: UUID) -> Lot? { lots.first { $0.readerID == readerID } }

    /// Quantity already backing the exact original need; never a second allocation
    /// of this shop's raw stock. Unknown/held/ineligible backing remains nil.
    func confirmedQuantity(for legacyNeedID: UUID) -> Quantity? {
        if let demand = demands.first(where: { $0.id == legacyNeedID }) { return demand.confirmedBacked }
        return zeroNeeds.first { $0.id == legacyNeedID }?.amount
    }

    /// Compatibility result for cook/repair readers. It contains existing backing
    /// and global free balances, not inputs for allocating the full stock again.
    /// An unknown balance's zero is a *zero allocatable credit* sentinel with issues;
    /// the actual physical count remains unknown in `lots` and is never replaced.
    func legacyAllocation() throws -> StockAllocationResult {
        var coverages: [StockDemandCoverage] = []
        for demand in demands {
            var issues = Self.legacyIssues(demand.issues)
            let unit = demand.legacyUnit
            let needed = try demand.requested?.converted(to: unit)
            var allocated = try demand.confirmedBacked?.converted(to: unit, using: demand.requested?.confirmedConversion)
            var shortfall = try demand.shortfall?.converted(to: unit, using: demand.requested?.confirmedConversion)
            if issues.isEmpty && (needed == nil || allocated == nil || shortfall == nil) {
                issues.append(.conversionUnknown)
            }
            if !issues.isEmpty { allocated = nil; shortfall = nil }
            coverages.append(.init(id: demand.id, foodID: demand.reservation.foodID, unit: unit,
                needed: needed, allocated: allocated, shortfall: shortfall, issues: issues))
        }
        coverages += zeroNeeds.map { .init(id: $0.id, foodID: $0.foodID, unit: $0.amount.unit,
            needed: .zero, allocated: .zero, shortfall: .zero, issues: []) }
        let edges: [StockAllocationEdge] = allocations.filter(\.isUsableForCoverage).map {
            .init(lotID: $0.readerLotID, needID: $0.legacyNeedID, foodID: $0.foodID,
                unit: $0.quantity.unit, amount: $0.quantity.amount)
        }
        let balances: [StockLotBalance] = try lots.map { row in
            var issues = Self.legacyIssues(row.issues)
            let free = try row.free?.converted(to: row.current.unit)
            if free == nil && issues.isEmpty { issues.append(.usableUnverified) }
            return .init(lotID: row.readerID, foodID: row.current.foodID, unit: row.current.unit,
                remainingUnallocated: free ?? .zero, issues: issues)
        }
        return .init(demands: coverages, allocations: edges, remainingLots: balances)
    }

    private static func legacyIssues(_ issues: [Issue]) -> [PickupIssue] {
        var result: [PickupIssue] = []
        for issue in issues {
            let value: PickupIssue
            switch issue {
            case .inventory(.conversionUnknown): value = .conversionUnknown
            case .inventory, .releasedClaim: value = .usableUnverified
            case .receiptEvidenceUnresolved, .receiptNotCurrent: value = .receiptUnverified
            case .receiptIneligible: value = .identityMatchUnconfirmed
            }
            if !result.contains(value) { result.append(value) }
        }
        return result
    }

    static func build(snapshot: PantryRepository.Snapshot, mapping: PantryLegacyMigration.Plan,
                      journeyID: UUID, at now: Date) throws -> Self {
        try build(snapshot: snapshot, mapping: mapping, scope: journeyID, at: now)
    }

    /// A genuine all-shop view, including a pantry with no saved pickup. Physical
    /// lot IDs stay canonical; no arbitrary journey supplies aliases or demands.
    static func buildGlobal(snapshot: PantryRepository.Snapshot, mapping: PantryLegacyMigration.Plan,
                            at now: Date) throws -> Self {
        try build(snapshot: snapshot, mapping: mapping, scope: nil, at: now)
    }

    private static func build(snapshot: PantryRepository.Snapshot, mapping: PantryLegacyMigration.Plan,
                              scope journeyID: UUID?, at now: Date) throws -> Self {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidClock }
        guard snapshot.state.active else { throw Failure.inactive }
        guard snapshot.state.workspaceID == mapping.originID else { throw Failure.wrongOrigin }
        guard Set(mapping.sourceHeads.map(\.id)).count == mapping.sourceHeads.count else { throw Failure.invalidMapping }
        var journeys: [UUID: PickupJourney] = [:]
        for head in mapping.sourceHeads {
            let journey = try JSONDecoder().decode(PickupJourney.self, from: head.payload)
            guard journey.id == head.id, head.revision > 0, journey.savedAt == head.savedAt else { throw Failure.invalidMapping }
            journeys[head.id] = journey
        }
        let selected = journeyID.flatMap { journeys[$0] }
        if journeyID != nil && selected == nil { throw Failure.missingJourney }
        let receiptEvidence = Self.receiptEvidence(in: Array(journeys.values))
        var selectedLatest: [ReceiptKey: UsableObservation] = [:]
        for observation in selected?.pickup?.usableObservations ?? [] { selectedLatest[observation.receipt] = observation }
        let edgesByClaim = Dictionary(grouping: snapshot.availability.allocations, by: \.needID)
        let canonicalLots = Dictionary(uniqueKeysWithValues: snapshot.lots.map { ($0.id, $0) })
        let roots = try InventoryLot.splitRoots(in: snapshot.lots)
        let canonicalBySource = Dictionary(uniqueKeysWithValues: snapshot.lots.map { ($0.source, $0.id) })
        let available = Dictionary(uniqueKeysWithValues: snapshot.availability.lots.map { ($0.id, $0) })
        guard Set(available.keys) == Set(canonicalLots.keys) else { throw Failure.invalidMapping }
        var linksBySource: [InventorySource: PantryLegacyMigration.SourceLink] = [:]
        for link in mapping.sourceLinks {
            guard link.source.originID == mapping.originID, linksBySource[link.source] == nil else { throw Failure.invalidMapping }
            linksBySource[link.source] = link
        }
        // Missing mapped physical sources are an erasure/reconciliation boundary,
        // not permission to resurrect a legacy count from the mapping plan.
        guard mapping.sourceLinks.allSatisfy({ canonicalBySource[$0.source] != nil }) else { throw Failure.missingCanonicalLot }
        var rows: [Lot] = []
        for current in snapshot.lots.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard current.source.originID == mapping.originID, current.confirmedAt <= now, current.updatedAt <= now,
                  let availability = available[current.id] else { throw Failure.invalidClock }
            let references = linksBySource[current.source]?.references.filter { $0.journeyID == journeyID } ?? []
            var issues = availability.issues.map(Issue.inventory)
            let aliases: [UUID], observationAliases: [UUID], receiptKey: ReceiptKey?, readerID: UUID
            switch current.source {
            case .manual(_, let sourceID):
                guard references.allSatisfy({ $0.receiptKey == nil && $0.legacyLotID == sourceID }) else { throw Failure.invalidMapping }
                aliases = Array(Set(references.compactMap(\.legacyLotID))).sorted { $0.uuidString < $1.uuidString }
                observationAliases = []; receiptKey = nil; readerID = aliases.first ?? current.id
            case .receipt(_, let key):
                guard references.allSatisfy({ $0.receiptKey == key && $0.legacyLotID == nil }) else { throw Failure.invalidMapping }
                aliases = []; receiptKey = key
                observationAliases = Array(Set(references.flatMap(\.observationIDs))).sorted { $0.uuidString < $1.uuidString }
                // Keep an old reader's exact local observation alias, but always
                // expose the independent canonical head above as freshness evidence.
                readerID = selectedLatest[key]?.id ?? current.id
            }
            if let rootID = roots[current.id], let root = canonicalLots[rootID],
               case .receipt(_, let originalKey) = root.source, !snapshot.receiptAcquiredLots.contains(rootID) {
                issues += receiptIssues(receiptEvidence[originalKey], at: now)
            }
            rows.append(Lot(id: current.id, readerID: readerID, current: current, availability: availability,
                scopedLegacyLotIDs: aliases, scopedLegacyObservationIDs: observationAliases, receiptKey: receiptKey, issues: issues))
        }
        guard Set(rows.map(\.readerID)).count == rows.count else { throw Failure.ambiguousLotAlias }
        // If canonical backing used receipt evidence this reader cannot accept,
        // that promise is still owed. Other same-food lots must not look free just
        // because the invalid source appeared to cover it, even in another shop.
        // Unknown stock already withheld by the canonical graph has no edges and
        // does not trigger this additional hold on independent confirmed stock.
        let ineligibleReceiptIDs = Set(rows.filter { row in
            row.issues.contains { issue in
                switch issue {
                case .receiptEvidenceUnresolved, .receiptIneligible, .receiptNotCurrent: return true
                default: return false
                }
            }
        }.map(\.id))
        let unbackedFoods = Set(snapshot.availability.allocations.filter {
            ineligibleReceiptIDs.contains($0.lotID)
        }.map(\.foodID))
        rows = rows.map { row in
            guard unbackedFoods.contains(row.current.foodID), !row.issues.contains(.receiptEvidenceUnresolved) else { return row }
            return Lot(id: row.id, readerID: row.readerID, current: row.current, availability: row.availability,
                scopedLegacyLotIDs: row.scopedLegacyLotIDs, scopedLegacyObservationIDs: row.scopedLegacyObservationIDs,
                receiptKey: row.receiptKey, issues: row.issues + [.receiptEvidenceUnresolved])
        }
        let indexedRows = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let claims = Dictionary(uniqueKeysWithValues: snapshot.reservations.map { ($0.id, $0) })
        let coverage = Dictionary(uniqueKeysWithValues: snapshot.availability.reservations.map { ($0.id, $0) })
        let scopedLinks = mapping.claimLinks.filter { link in journeyID.map { link.journeyIDs.contains($0) } ?? false }
        guard Set(scopedLinks.map(\.reservationID)).count == scopedLinks.count,
              Set(scopedLinks.map(\.legacyNeedID)).count == scopedLinks.count else { throw Failure.ambiguousNeedMapping }
        let mappedNeedIDs = Set(scopedLinks.map(\.legacyNeedID))
        let legacyNeeds = Dictionary(uniqueKeysWithValues: (selected?.physicalStockNeeds ?? []).map { ($0.id, $0) })
        guard (selected?.physicalStockNeeds ?? []).filter({ $0.amount.amount > .zero }).allSatisfy({ mappedNeedIDs.contains($0.id) }) else {
            throw Failure.invalidMapping
        }
        var demandRows: [Demand] = []
        for link in scopedLinks.sorted(by: { $0.legacyNeedID.uuidString < $1.legacyNeedID.uuidString }) {
            guard let claim = claims[link.reservationID], claim.originID == mapping.originID else { throw Failure.missingCanonicalClaim }
            if let legacy = legacyNeeds[link.legacyNeedID] {
                guard legacy.foodID == claim.foodID,
                      claim.state != .active || (legacy.amount == claim.amount && legacy.priority == claim.priority) else {
                    throw Failure.invalidMapping
                }
            }
            let pendingUnit = selected?.awayCarryovers.first { $0.intent.plan.link.reservationID == link.legacyNeedID }?.intent.plan.link.quantity.unit
            guard let unit = legacyNeeds[link.legacyNeedID]?.amount.unit ?? claim.amount?.unit ?? pendingUnit else {
                throw Failure.invalidMapping
            }
            let result = coverage[claim.id]
            guard claim.state == .released || result != nil else { throw Failure.invalidMapping }
            var issues = result?.issues.map(Issue.inventory) ?? [.releasedClaim]
            if claim.state == .released { issues = [.releasedClaim] }
            // Do not convert canonical provisional edges into confident legacy
            // coverage when the original receipt is ineligible for this reader.
            for edge in edgesByClaim[claim.id] ?? [] {
                guard let lot = indexedRows[edge.lotID], edge.foodID == claim.foodID, lot.current.foodID == claim.foodID else {
                    throw Failure.invalidMapping
                }
                for issue in lot.issues where !issues.contains(issue) { issues.append(issue) }
            }
            demandRows.append(Demand(id: link.legacyNeedID, reservation: claim, coverage: result, legacyUnit: unit, issues: issues))
        }
        let indexedDemands = Dictionary(uniqueKeysWithValues: demandRows.map { ($0.canonicalReservationID, $0) })
        var edges: [Allocation] = []
        for edge in snapshot.availability.allocations {
            guard let demand = indexedDemands[edge.needID] else { continue }
            guard let lot = indexedRows[edge.lotID] else { throw Failure.invalidMapping }
            edges.append(Allocation(canonicalLotID: lot.id, readerLotID: lot.readerID,
                canonicalReservationID: demand.canonicalReservationID, legacyNeedID: demand.id, foodID: edge.foodID,
                quantity: Quantity(amount: edge.amount, unit: edge.unit, originalLiteral: edge.amount.description),
                receiptKey: lot.receiptKey, isUsableForCoverage: demand.issues.isEmpty && lot.issues.isEmpty))
        }
        return Self(basis: Basis(originID: mapping.originID, inventoryRevision: snapshot.state.revision, journeyID: journeyID,
            sourceHeads: mapping.sourceHeads.map { HeadRevision(journeyID: $0.id, storeRevision: $0.revision) }
                .sorted { $0.journeyID.uuidString < $1.journeyID.uuidString }),
            asOf: now, lots: rows, demands: demandRows,
            zeroNeeds: (selected?.physicalStockNeeds ?? []).filter { $0.amount.amount == .zero && !mappedNeedIDs.contains($0.id) }, allocations: edges)
    }

    private struct ReceiptEvidence {
        var fragment: ReceiptFragment?
        var orderID: UUID?
        var observations: [UUID: UsableObservation] = [:]
        var conflicting = false

        var currentObservation: UsableObservation? {
            let superseded = Set(observations.values.compactMap(\.supersedesID))
            let heads = observations.values.filter { !superseded.contains($0.id) }
            return heads.count == 1 ? heads.first : nil
        }
    }

    /// Build once per authorized paired read. Current physical counts come only
    /// from the canonical editor when a receipt is selected.
    static func recentPurchases(snapshot: PantryRepository.Snapshot, mapping: PantryLegacyMigration.Plan,
                                journeys: [PickupJourney]) -> [PantryRecentPurchase] {
        guard snapshot.state.active, snapshot.state.workspaceID == mapping.originID else { return [] }
        let evidence = receiptEvidence(in: journeys)
        let links = Dictionary(grouping: mapping.sourceLinks, by: \.source)
        let unresolved = Set(mapping.issues.filter { $0.kind == .receiptBranch || $0.kind == .unconfirmedReceipt }.compactMap(\.lotID))
        return snapshot.lots.compactMap { lot -> PantryRecentPurchase? in
            guard case let .receipt(origin, key) = lot.source, origin == mapping.originID, !unresolved.contains(lot.id),
                  let matches = links[lot.source], matches.count == 1, let link = matches.first, link.lotID == lot.id,
                  let arrival = evidence[key], !arrival.conflicting, let fragment = arrival.fragment,
                  fragment.disposition != .wrongItem, fragment.disposition != .noFill, fragment.received.amount > .zero,
                  let usable = arrival.currentObservation, usable.confirmedMatchToOrderLine, usable.usable.amount > .zero,
                  link.references.contains(where: { $0.receiptKey == key && $0.observationIDs.contains(usable.id) }) else { return nil }
            return PantryRecentPurchase(id: lot.id, receiptKey: key,
                reviewedFood: .init(id: lot.foodID, name: lot.name, inventoryWorkspaceID: origin, inventoryRevision: snapshot.state.revision),
                receivedAt: fragment.receivedAt, usableObservationID: usable.id, confirmedAt: usable.confirmedAt, received: fragment.received)
        }.sorted { lhs, rhs in
            lhs.receivedAt != rhs.receivedAt ? lhs.receivedAt > rhs.receivedAt : lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Build once for all receipt lots, including copies in different journeys.
    /// Equal printed keys from different original orders remain a conflict.
    private static func receiptEvidence(in journeys: [PickupJourney]) -> [ReceiptKey: ReceiptEvidence] {
        var result: [ReceiptKey: ReceiptEvidence] = [:]
        for journey in journeys {
            guard let pickup = journey.pickup else { continue }
            for fragment in pickup.receipts {
                var row = result[fragment.key] ?? ReceiptEvidence()
                if let previous = row.fragment, previous != fragment { row.conflicting = true }
                if let orderID = row.orderID, orderID != pickup.orderID { row.conflicting = true }
                row.fragment = fragment; row.orderID = pickup.orderID
                result[fragment.key] = row
            }
            for observation in pickup.usableObservations {
                if let old = result[observation.receipt]?.observations[observation.id], old != observation {
                    result[observation.receipt, default: ReceiptEvidence()].conflicting = true
                }
                result[observation.receipt, default: ReceiptEvidence()].observations[observation.id] = observation
            }
        }
        return result
    }

    private static func receiptIssues(_ evidence: ReceiptEvidence?, at now: Date) -> [Issue] {
        guard let evidence, !evidence.conflicting, let first = evidence.fragment else { return [.receiptEvidenceUnresolved] }
        guard first.disposition != .wrongItem, first.disposition != .noFill else { return [.receiptIneligible] }
        guard first.receivedAt <= now else { return [.receiptNotCurrent] }
        guard let current = evidence.currentObservation else { return [.receiptEvidenceUnresolved] }
        guard current.confirmedAt <= now else { return [.receiptNotCurrent] }
        return current.confirmedMatchToOrderLine ? [] : [.receiptIneligible]
    }
}
