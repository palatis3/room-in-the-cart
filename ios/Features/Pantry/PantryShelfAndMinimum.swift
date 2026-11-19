import CoreDomain
import Foundation
import CryptoKit

struct PantryShelfCount: Codable, Equatable {
    enum Answer: String, Codable { case present, skipped, recounted }
    struct Batch: Codable, Equatable, Identifiable {
        let id: UUID
        var revision: Int64
        var answer: Answer?
    }
    let id: UUID
    let name: String
    let location: InventoryLocation
    var batches: [Batch]

    /// A committed physical edit stays saved if another window finishes this count.
    /// Only the session and batch that opened the editor may receive its progress.
    mutating func markSaved(_ lot: InventoryLot, from original: Self, adding: Bool) -> Bool {
        guard id == original.id, location == lot.location else { return false }
        let row = Batch(id: lot.id, revision: lot.revision, answer: .recounted)
        if let index = batches.firstIndex(where: { $0.id == lot.id }) {
            guard original.batches.first(where: { $0.id == lot.id }) == batches[index] else { return false }
            batches[index] = row
        } else {
            guard adding, batches.count < 128, !original.batches.contains(where: { $0.id == lot.id }) else { return false }
            batches.append(row)
        }
        return true
    }

    func answer(for lot: InventoryLot) -> Answer? {
        batches.first { $0.id == lot.id && $0.revision == lot.revision && location == lot.location }?.answer
    }
}

struct PantryPresence: Codable, Equatable {
    let lotID: UUID
    let date: Date
}

struct PantryStapleMinimum: Codable, Equatable, Identifiable {
    var id: UUID { foodID }
    let foodID: UUID
    let anchorLotID: UUID
    let target: Quantity
    let afterHolds: Bool

    func productLink(in scope: PantryDigestScope) -> UUID {
        let identity = "pantry-minimum/v1/" + scope.origin.uuidString + "/" + scope.owner + "/" + foodID.uuidString
        var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    func shortfall(lots: [InventoryLot], projection: InventoryProjection, linkedLineIDs: Set<UUID> = []) throws -> Quantity? {
        var total = Rational.zero
        let product = lots.filter { $0.foodID == foodID || linkedLineIDs.contains($0.foodID) }
        guard !product.isEmpty else { return nil }
        let availability = Dictionary(uniqueKeysWithValues: projection.lots.map { ($0.id, $0) })
        for lot in product {
            let evidence = afterHolds ? availability[lot.id]?.free : lot.count.quantity
            guard let evidence, let amount = try evidence.converted(to: target.unit) else { return nil }
            total = try total.adding(amount)
        }
        let missing = total < target.amount ? try target.amount.subtracting(total) : .zero
        return Quantity(amount: missing, unit: target.unit, originalLiteral: missing.description)
    }

    func proposal(shortfall: Quantity?, incoming: Quantity?) -> Quantity? {
        guard let shortfall, let incoming, shortfall.unit == target.unit, incoming.unit == target.unit else { return nil }
        guard let amount = try? shortfall.amount.subtractingClampedToZero(incoming.amount) else { return nil }
        return Quantity(amount: amount, unit: target.unit, originalLiteral: amount.description)
    }

    /// Only identified order lines with no recorded delivery are confirmed incoming here.
    /// A partial or substituted delivery needs a human review before another purchase.
    func incoming(_ journeys: [PickupJourney], linkedLineIDs: Set<UUID> = []) throws -> Quantity? {
        var total = Rational.zero
        let identities = linkedLineIDs.union([foodID])
        for journey in journeys where journey.closedAt == nil {
            guard let pickup = journey.pickup else { continue }
            for line in pickup.orderLines where identities.contains(line.id) {
                let receipts = pickup.receipts.filter { $0.key.orderLineID == line.id }
                guard let ordered = try line.ordered.converted(to: target.unit) else { return nil }
                if receipts.isEmpty { total = try total.adding(ordered); continue }
                var delivered = Rational.zero
                for receipt in receipts {
                    guard receipt.disposition != .wrongItem,
                          let amount = try receipt.received.converted(to: target.unit) else { return nil }
                    delivered = try delivered.adding(amount)
                }
                if delivered < ordered { return nil }
            }
        }
        return Quantity(amount: total, unit: target.unit, originalLiteral: total.description)
    }
}

/// Each placed checkout retains the exact private shopping ledger that produced its order.
/// Resolve reviewed contributions to their committed line, including merged rows.
struct PantryPlacedProductLinks {
    private(set) var byProduct: [UUID: Set<UUID>] = [:]
    private(set) var uncertain = Set<UUID>()

    init(journeys: [PickupJourney]) {
        var links: [UUID: Set<UUID>] = [:]
        for journey in journeys {
            guard let pickup = journey.pickup, let shop = journey.mealSource?.shop, shop.id == journey.id else { continue }
            let lines = Dictionary(uniqueKeysWithValues: pickup.orderLines.map { ($0.id, $0) })
            let contributions = Dictionary(uniqueKeysWithValues: shop.contributions.map { ($0.id, $0) })
            for batch in shop.importBatches where batch.undoneAt == nil {
                for row in batch.preview.lines {
                    guard let link = row.pantryProductLink, let contribution = contributions[row.id],
                          contribution.removedAt == nil, contribution.source == .imported(batchID: batch.id),
                          let line = lines[contribution.lineID] else { continue }
                    // A renamed or substituted order line needs new identity confirmation.
                    guard row.originalText == row.name, row.name == contribution.productName, line.name == row.name else {
                        uncertain.insert(link); continue
                    }
                    links[line.id, default: []].insert(link)
                }
            }
        }
        for (line, candidates) in links {
            guard candidates.count == 1, let link = candidates.first else { uncertain.formUnion(candidates); continue }
            byProduct[link, default: []].insert(line)
        }
    }
}
