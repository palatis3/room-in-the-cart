import Foundation
import CoreDomain

extension BasketPlan {
    /// A cancelled line still identifies its earlier arrivals, meals, offers and any later physical receipt.
    /// Keep its last known label and unit with zero currently ordered.
    func physicalOrderLines(branch: String) -> [PickupOrderLine] {
        var orderedIDs: [UUID] = [], last: [UUID: BasketLine] = [:]
        for lines in [reportedOrderLines ?? []] + amendments.map(\.lines) {
            for line in lines {
                if last[line.id] == nil { orderedIDs.append(line.id) }
                last[line.id] = line
            }
        }
        let active = Set((effectiveOrderLines ?? []).map(\.id))
        return orderedIDs.compactMap { id in
            guard let line = last[id] else { return nil }
            let quantity = active.contains(id) ? line.quantity : Quantity(amount: .zero, unit: line.quantity.unit, originalLiteral: "0")
            return PickupOrderLine(id: id, branchID: branch, name: line.name, ordered: quantity)
        }
    }
}

struct PickupAmendmentBase: Equatable {
    let workspaceID: UUID
    let shopID: UUID
    let actorID: UUID
    let placementID: UUID
    let revision: Int64
    let predecessor: UUID?
    let lines: [BasketLine]

    init?(journey: PickupJourney, workspaceID: UUID?, actorID: UUID) {
        guard let workspaceID, let basket = journey.basket,
              let placement = basket.placements.first, let lines = basket.effectiveOrderLines else { return nil }
        self.workspaceID = workspaceID; self.shopID = journey.id; self.actorID = actorID
        placementID = placement.id; revision = journey.revision; predecessor = basket.amendments.last?.id
        self.lines = lines
    }
}

struct PickupAmendmentReview: Equatable {
    let base: PickupAmendmentBase
    let event: ConfirmedAmendment

    func validate(in basket: BasketPlan, now: Date) throws {
        guard event.placementID == base.placementID, event.previousAmendmentID == base.predecessor,
              event.recordedByLocalActorID == base.actorID, basket.id == base.shopID,
              basket.effectiveOrderLines == base.lines, basket.amendments.last?.id == base.predecessor,
              event.confirmedAt.timeIntervalSinceReferenceDate.isFinite, event.confirmedAt <= now,
              basket.amendments.last.map({ $0.confirmedAt <= event.confirmedAt }) ?? true,
              !event.retailerReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              event.lines != base.lines, Set(event.lines.map(\.id)).count == event.lines.count else {
            throw CheckoutError.invalidAmendment
        }
        guard !PickupAmendmentDelta.differences(from: base.lines, to: event.lines).isEmpty else { throw CheckoutError.invalidAmendment }
        let current = Dictionary(uniqueKeysWithValues: base.lines.map { ($0.id, $0) })
        let historical = Set((basket.reportedOrderLines ?? []).map(\.id)).union(basket.amendments.flatMap { $0.lines.map(\.id) })
        for line in event.lines {
            guard !line.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CheckoutError.invalidAmendment }
            if let previous = current[line.id] {
                // A changed food or incompatible unit needs a separate identity. Earlier receipts must retain their meaning.
                guard previous.name == line.name, previous.quantity.unit.dimension == line.quantity.unit.dimension else {
                    throw CheckoutError.invalidAmendment
                }
                if previous == line { continue }
            } else if historical.contains(line.id) { throw CheckoutError.invalidAmendment }
            guard line.quantity.amount > .zero else { throw CheckoutError.invalidAmendment }
        }
    }
}

struct PickupAmendmentDelta: Identifiable {
    let id: UUID
    let before: BasketLine?
    let after: BasketLine?

    static func differences(from before: [BasketLine], to after: [BasketLine]) -> [Self] {
        let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let new = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        return (before.map(\.id) + after.filter { old[$0.id] == nil }.map(\.id)).compactMap { id in
            guard old[id] != new[id] else { return nil }
            return Self(id: id, before: old[id], after: new[id])
        }
    }
}

extension PickupJourney {
    var retailerOrderLines: [PickupOrderLine] {
        guard let basket, !basket.amendments.isEmpty else { return pickup?.orderLines ?? [] }
        let active = Set((basket.effectiveOrderLines ?? []).map(\.id))
        return pickup?.orderLines.filter { active.contains($0.id) } ?? []
    }
}
