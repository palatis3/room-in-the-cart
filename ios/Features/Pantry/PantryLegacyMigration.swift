import Foundation
import CryptoKit
import CoreDomain
import LocalStore

/// Maps a complete, revision-consistent legacy source set. This does not activate
/// inventory, write either database, or establish that the caller enumerated every head.
@MainActor enum PantryLegacyMigration {
    enum Failure: Error, Equatable { case capacity, invalidSource, duplicateSource, invalidClock }
    nonisolated static let maximumHeads = 1_000
    static let maximumSourceBytes = 64 * 1_024 * 1_024
    static let maximumObservations = 100_000

    struct SourceHead: Codable, Equatable {
        let id: UUID
        let revision: Int64
        let payload: Data
        let savedAt: Date
        init(_ saved: SavedComparison) {
            id = saved.id; revision = saved.revision; payload = saved.payload; savedAt = saved.savedAt
        }
    }

    enum LedgerContext {
        case available(originID: UUID, revision: Int64, workspace: LedgerWorkspace)
        case unavailable
    }

    enum IssueKind: String, Codable {
        case conflictingSource, ambiguousManualCount, receiptBranch, unconfirmedReceipt
        case missingAncestor, cyclicAncestry, conflictingClaim, missingPinnedSource, pendingCarryover, ledgerNeedsReview
    }
    struct Issue: Codable, Equatable {
        let kind: IssueKind
        let sourceIDs: [UUID]
        let lotID: UUID?
        let claimID: UUID?
    }
    struct LegacyReference: Codable, Equatable {
        let journeyID: UUID
        let legacyLotID: UUID?
        let receiptKey: ReceiptKey?
        let observationIDs: [UUID]
    }
    struct SourceLink: Codable, Equatable {
        let lotID: UUID
        let source: InventorySource
        let references: [LegacyReference]
    }
    struct ObservationLink: Codable, Equatable {
        let journeyID: UUID
        let legacyObservationID: UUID
        let observationID: UUID
        let lotID: UUID
    }
    enum LedgerDisposition: String, Codable { case applied, pendingProjection, needsReview, cancelled }
    struct PendingLineage: Codable, Equatable {
        let journeyID: UUID
        let record: AwayCarryoverRecord
        let lotID: UUID?
        let reservationID: UUID
        let ledgerDisposition: LedgerDisposition
    }
    struct ClaimLink: Codable, Equatable {
        let reservationID: UUID
        let legacyNeedID: UUID
        let journeyIDs: [UUID]
    }
    struct Plan: Equatable {
        let originID: UUID
        /// Exact source bytes, including conflicting candidates, remain available for review.
        let sourceHeads: [SourceHead]
        let ledgerOriginID: UUID?
        let ledgerRevision: Int64?
        let lots: [InventoryLot]
        let observations: [InventoryObservation]
        let reservations: [InventoryReservation]
        let sourceLinks: [SourceLink]
        let observationLinks: [ObservationLink]
        let claimLinks: [ClaimLink]
        let pendingLineage: [PendingLineage]
        let issues: [Issue]
    }

    private struct Manual { let journey: UUID; let lot: ConfirmedStockLot }
    private struct Received { let journey: UUID; let orderID: UUID; let fragment: ReceiptFragment; let observations: [UsableObservation] }
    private struct Claim { let journey: UUID; let need: StockNeed; var pin: UUID?; var unresolved: Bool }

    static func map(originID: UUID, heads: [SourceHead], ledger: LedgerContext, at now: Date) throws -> Plan {
        try mapWithJourneys(originID: originID, heads: heads, ledger: ledger, at: now).plan
    }

    /// Return the same validated heads used by the plan in canonical source ID order.
    static func mapWithJourneys(originID: UUID, heads: [SourceHead], ledger: LedgerContext, at now: Date) throws
        -> (plan: Plan, journeys: [PickupJourney]) {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidClock }
        guard heads.count <= maximumHeads,
              heads.reduce(0, { $0 + $1.payload.count }) <= maximumSourceBytes else { throw Failure.capacity }
        guard Set(heads.map(\.id)).count == heads.count else { throw Failure.duplicateSource }
        let heads = heads.sorted { key($0.id) < key($1.id) }
        let decoded = try heads.map { head -> PickupJourney in
            guard head.revision > 0, head.payload.count <= ComparisonStore.maximumPayloadBytes,
                  head.savedAt.timeIntervalSinceReferenceDate.isFinite, head.savedAt <= now else { throw Failure.invalidSource }
            let value = try JSONDecoder().decode(PickupJourney.self, from: head.payload)
            guard value.id == head.id, value.savedAt == head.savedAt else { throw Failure.invalidSource }
            try PickupModel.validate(value)
            return value
        }
        let journeys = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        let ledgerOrigin: UUID?, ledgerRevision: Int64?
        switch ledger {
        case .available(let origin, let revision, let workspace):
            guard revision >= 0 else { throw Failure.invalidSource }
            try workspace.validate(); ledgerOrigin = origin; ledgerRevision = revision
        case .unavailable: ledgerOrigin = nil; ledgerRevision = nil
        }
        var issues: [Issue] = []
        func issue(_ kind: IssueKind, _ ids: [UUID], lot: UUID? = nil, claim: UUID? = nil) {
            let row = Issue(kind: kind, sourceIDs: Array(Set(ids)).sorted { key($0) < key($1) }, lotID: lot, claimID: claim)
            if !issues.contains(row) { issues.append(row) }
        }
        var brokenAncestry = Set<UUID>()
        for id in journeys.keys.sorted(by: { key($0) < key($1) }) {
            var seen = Set<UUID>(), cursor: UUID? = id
            while let current = cursor {
                guard seen.insert(current).inserted else {
                    brokenAncestry.insert(id); issue(.cyclicAncestry, [id, current]); break
                }
                guard let value = journeys[current] else {
                    brokenAncestry.insert(id); issue(.missingAncestor, [id, current]); break
                }
                cursor = value.originShopID
            }
        }
        func ancestor(_ first: UUID, of second: UUID) -> Bool {
            guard !brokenAncestry.contains(second) else { return false }
            var cursor: UUID? = second
            while let id = cursor {
                if first == id { return true }
                cursor = journeys[id]?.originShopID
            }
            return false
        }
        func linear(_ ids: [UUID]) -> Bool {
            ids.allSatisfy { a in ids.allSatisfy { b in ancestor(a, of: b) || ancestor(b, of: a) } }
        }
        var manual: [UUID: [Manual]] = [:], received: [ReceiptKey: [Received]] = [:]
        var claims: [UUID: [Claim]] = [:]
        for head in heads {
            let journey = journeys[head.id]!
            for lot in journey.stockLots { manual[lot.id, default: []].append(.init(journey: journey.id, lot: lot)) }
            for fragment in journey.pickup?.receipts ?? [] {
                received[fragment.key, default: []].append(.init(journey: journey.id, orderID: journey.pickup!.orderID,
                    fragment: fragment, observations: journey.pickup!.usableObservations.filter { $0.receipt == fragment.key }))
            }
            // Never combine the old raw baseline with its accepted recovery replacement.
            if let history = journey.mealRecovery {
                try history.validate(); try journey.validateRecoveryRawBasis(history)
            }
            for need in try journey.remainingPhysicalNeeds() where need.amount.amount > .zero {
                claims[need.id, default: []].append(.init(journey: journey.id, need: need, pin: nil,
                    unresolved: brokenAncestry.contains(journey.id)))
            }
        }
        guard manual.count + received.count <= InventoryProjection.maximumLots else { throw Failure.capacity }
        var lots: [InventoryLot] = [], observations: [InventoryObservation] = []
        var links: [SourceLink] = [], observationLinks: [ObservationLink] = []
        var manualIDs: [UUID: UUID] = [:], receiptIDs: [ReceiptKey: UUID] = [:]
        var conflictingFoods = Set<UUID>()

        for oldID in manual.keys.sorted(by: { key($0) < key($1) }) {
            let rows = manual[oldID]!, source = InventorySource.manual(originID: originID, sourceID: oldID)
            let lotID = try identity("lot", source)
            manualIDs[oldID] = lotID
            let first = rows[0].lot, ids = rows.map(\.journey)
            // Heads prove the stable carried ID, but not that an ancestor was not
            // edited after copying. Different current counts require review.
            let conflict = !linear(ids) || rows.contains { $0.lot != first } || first.confirmedAt > now
            if conflict {
                issue(.ambiguousManualCount, ids, lot: lotID)
                conflictingFoods.formUnion(rows.map { $0.lot.foodID })
            }
            let observed = conflict ? now : first.confirmedAt
            let count: InventoryCount = conflict ? .unknown : .exact(first.usable)
            let observationID = try identity("manual-baseline", [key(lotID), try digest(rows.map(\.lot))])
            let operation = try identity("migration-observation-operation", observationID)
            observations.append(.init(id: observationID, lotID: lotID, operationID: operation, revision: 1,
                supersedesID: nil, observedAt: observed, count: count))
            lots.append(.init(id: lotID, foodID: first.foodID, name: first.name, source: source, revision: 1,
                location: first.source == .freezer ? .freezer : .cupboard, unit: first.usable.unit,
                count: count, observationID: observationID, confirmedAt: observed, updatedAt: now, useFirst: first.useFirst == true))
            links.append(.init(lotID: lotID, source: source, references: rows.map {
                .init(journeyID: $0.journey, legacyLotID: oldID, receiptKey: nil, observationIDs: [])
            }))
        }

        let keys = try received.keys.map { ($0, try digest($0)) }.sorted { $0.1 < $1.1 }.map(\.0)
        for receiptKey in keys {
            let rows = received[receiptKey]!, source = InventorySource.receipt(originID: originID, key: receiptKey)
            let lotID = try identity("lot", source)
            receiptIDs[receiptKey] = lotID
            let first = rows[0].fragment, ids = rows.map(\.journey)
            var conflict = rows.contains { $0.fragment != first || $0.orderID != rows[0].orderID }
            var values: [UUID: UsableObservation] = [:]
            for row in rows {
                for observation in row.observations {
                    if let old = values[observation.id], old != observation { conflict = true }
                    else { values[observation.id] = observation }
                }
            }
            var chain: [UsableObservation] = [], predecessor: UUID?
            while chain.count < values.count {
                let next = values.values.filter { $0.supersedesID == predecessor }
                guard next.count == 1, let value = next.first, !chain.contains(where: { $0.id == value.id }) else { conflict = true; break }
                chain.append(value); predecessor = value.id
            }
            if chain.count != values.count { conflict = true }
            if first.receivedAt > now || values.values.contains(where: { $0.confirmedAt > now }) { conflict = true }
            var mapped: [InventoryObservation] = [], previous: UUID?
            // A fork does not get linearized by timestamp. Original candidate rows
            // remain in the byte-exact source heads and reference links for review.
            if !conflict {
                for value in chain {
                    let id = try identity("receipt-observation", [key(lotID), key(value.id)])
                    let count: InventoryCount = value.confirmedMatchToOrderLine && first.disposition != .wrongItem
                        ? .exact(value.usable) : .unknown
                    mapped.append(.init(id: id, lotID: lotID, operationID: try identity("migration-observation-operation", id),
                        revision: Int64(mapped.count + 1), supersedesID: previous, observedAt: value.confirmedAt, count: count))
                    previous = id
                    for row in rows where row.observations.contains(value) {
                        observationLinks.append(.init(journeyID: row.journey, legacyObservationID: value.id, observationID: id, lotID: lotID))
                    }
                }
            }
            if mapped.isEmpty {
                let id = try identity("receipt-unresolved-baseline", lotID)
                mapped.append(.init(id: id, lotID: lotID, operationID: try identity("migration-observation-operation", id),
                    revision: 1, supersedesID: nil, observedAt: now, count: .unknown))
            }
            let head = mapped.last!
            if conflict { issue(.receiptBranch, ids, lot: lotID); conflictingFoods.insert(receiptKey.orderLineID) }
            else if head.count.quantity == nil { issue(.unconfirmedReceipt, ids, lot: lotID) }
            lots.append(.init(id: lotID, foodID: receiptKey.orderLineID, name: first.itemName, source: source,
                revision: head.revision, location: .cupboard, unit: head.count.quantity?.unit ?? first.received.unit,
                count: head.count, observationID: head.id, confirmedAt: head.observedAt, updatedAt: now))
            observations += mapped
            links.append(.init(lotID: lotID, source: source, references: rows.map {
                .init(journeyID: $0.journey, legacyLotID: nil, receiptKey: receiptKey, observationIDs: $0.observations.map(\.id))
            }))
        }
        guard observations.count <= maximumObservations else { throw Failure.capacity }

        var pending: [PendingLineage] = []
        for head in heads {
            let journey = journeys[head.id]!
            for record in journey.awayCarryovers {
                let intent = record.intent, oldClaim = intent.plan.link.reservationID
                let lotID: UUID?
                switch intent.supply {
                case .batch(let value): lotID = manualIDs[value.id]
                case .received(let fragment, _): lotID = receiptIDs[fragment.key]
                }
                let disposition = ledgerDisposition(record, ledger: ledger)
                let unresolved = record.phase == .prepared || disposition == .needsReview || lotID == nil
                if record.phase != .cancelled {
                    if record.phase == .prepared { issue(.pendingCarryover, [journey.id], lot: lotID, claim: oldClaim) }
                    if disposition == .needsReview { issue(.ledgerNeedsReview, [journey.id], lot: lotID, claim: oldClaim) }
                    if lotID == nil { issue(.missingPinnedSource, [journey.id], claim: oldClaim) }
                    if let index = claims[oldClaim]?.firstIndex(where: { $0.journey == journey.id }) {
                        claims[oldClaim]![index].pin = lotID
                        claims[oldClaim]![index].unresolved = claims[oldClaim]![index].unresolved || unresolved
                    } else {
                        claims[oldClaim, default: []].append(.init(journey: journey.id,
                            need: AwayCarryoverEngine.targetNeed(intent), pin: lotID, unresolved: true))
                    }
                }
                pending.append(.init(journeyID: journey.id, record: record, lotID: lotID,
                    reservationID: try claimIdentity(originID: originID, needID: oldClaim, foodID: intent.supply.foodID),
                    ledgerDisposition: disposition))
            }
        }
        var reservations: [InventoryReservation] = [], claimLinks: [ClaimLink] = []
        for oldID in claims.keys.sorted(by: { key($0) < key($1) }) {
            let rows = claims[oldID]!
            let foods = Set(rows.map { $0.need.foodID })
            for food in foods.sorted(by: { key($0) < key($1) }) {
                let group = rows.filter { $0.need.foodID == food }, first = group[0]
                let pins = Set(group.compactMap(\.pin))
                let id = try claimIdentity(originID: originID, needID: oldID, foodID: food)
                let pinFoodConflict = pins.contains { pin in lots.first { $0.id == pin }?.foodID != food }
                let conflicting = foods.count > 1 || !linear(group.map(\.journey)) ||
                    group.contains { $0.need != first.need } || pins.count > 1 || pinFoodConflict
                let unresolved = conflicting || conflictingFoods.contains(food) || group.contains(where: \.unresolved)
                if conflicting { issue(.conflictingClaim, rows.map(\.journey), claim: oldID) }
                reservations.append(.init(id: id, originID: originID, revision: 1, foodID: food,
                    lotID: pins.count == 1 && !pinFoodConflict ? pins.first : nil, name: first.need.name,
                    amount: conflicting ? nil : first.need.amount, priority: group.contains { $0.need.priority == .protected } ? .protected : first.need.priority,
                    state: unresolved ? .unresolved : .active))
                claimLinks.append(.init(reservationID: id, legacyNeedID: oldID, journeyIDs: group.map(\.journey)))
            }
        }
        guard reservations.count <= InventoryProjection.maximumReservations else { throw Failure.capacity }
        for lot in lots { try lot.validate() }
        for observation in observations { try observation.validate() }
        for reservation in reservations { try reservation.validate() }
        // Validate canonical projection semantics as well as individual row shapes.
        _ = try InventoryProjection.build(originID: originID, lots: lots, reservations: reservations, at: now)
        let plan = Plan(originID: originID, sourceHeads: heads, ledgerOriginID: ledgerOrigin, ledgerRevision: ledgerRevision,
            lots: lots, observations: observations, reservations: reservations, sourceLinks: links,
            observationLinks: observationLinks, claimLinks: claimLinks, pendingLineage: pending, issues: issues)
        return (plan, decoded)
    }

    private static func ledgerDisposition(_ record: AwayCarryoverRecord, ledger: LedgerContext) -> LedgerDisposition {
        if record.phase == .cancelled { return .cancelled }
        guard case let .available(origin, _, workspace) = ledger, origin == record.intent.workspaceID,
              let shop = workspace.shops.first(where: { $0.id == record.intent.plan.link.sourceShopID }) else { return .needsReview }
        let intent = record.intent
        if let target = shop.mealOccurrences.first(where: { $0.id == intent.plan.occurrenceID }) {
            return target.carryover == intent.plan.link && target.removedAt == nil ? .applied : .needsReview
        }
        guard record.phase != .completed, shop.revisionID == intent.plan.baseRevisionID,
              workspace.dinnerPlanning.revisionID == intent.planningRevisionID else { return .needsReview }
        return .pendingProjection
    }

    nonisolated private static func key(_ value: UUID) -> String { value.uuidString.lowercased() }
    nonisolated private static func bytes<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try bytes(value)).map { String(format: "%02x", $0) }.joined()
    }
    /// The same stable claim identity is used by migration, live deltas and
    /// hypothetical recovery. Planning never invents a second claim namespace.
    nonisolated static func claimIdentity(originID: UUID, needID: UUID, foodID: UUID) throws -> UUID {
        try identity("claim", [key(originID), key(needID), key(foodID)])
    }

    nonisolated private static func identity<T: Encodable>(_ kind: String, _ value: T) throws -> UUID {
        let payload = try bytes(value)
        var input = Data("room-in-the-cart/pantry-legacy/v1/\(kind)/".utf8); input.append(payload)
        var value = Array(SHA256.hash(data: input).prefix(16))
        value[6] = (value[6] & 15) | 128; value[8] = (value[8] & 63) | 128
        return UUID(uuid: (value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7],
                           value[8], value[9], value[10], value[11], value[12], value[13], value[14], value[15]))
    }
}
