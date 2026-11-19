import Foundation
import CoreDomain

struct DinnerBasketGroceryDraft: Identifiable {
    struct Label: Hashable {
        let name: String
        let dimension: UnitDimension?
        let notes: String
        let exclusions: [String]
    }
    let id = UUID()
    let label: Label
    var existingLine: UUID?
    var existingQuantity: Quantity?
    var members: [(ThreeDinnerBasket.Member, String)] = []
    var combine = false
    var amount = ""
    var unit: UnitOfMeasure = .count
    var price = ""
    var source = ""
    var observed = Date()
    var selectedOffer: PackOffer?

    static func prepare(recipes: [AcceptedDinner], shop: ShoppingLedger, history: [LedgerPackSelection],
                        workspace: UUID) throws -> [Self] {
        var rows: [Self] = []
        var indices: [Label: [Int]] = [:]
        for line in shop.lines where !line.isTrashed && !line.isHandled {
            let sources = shop.contributions(forLineID: line.id)
            let quantity = try shop.quantity(forLineID: line.id)
            let label = Label(name: line.name, dimension: quantity?.unit.dimension, notes: line.notes, exclusions: Array(Set(sources.flatMap(\.exclusions))).sorted())
            var row = Self(label: label, existingLine: line.id, existingQuantity: quantity, unit: quantity?.unit ?? .count)
            if let quote = history.last(where: { $0.sourceWorkspaceID == workspace && $0.shopID == shop.id &&
                $0.shopRevisionID == shop.revisionID && $0.basisRevision == shop.basisRevision &&
                $0.lineID == line.id && $0.request.itemName == line.name }) {
                let offer = quote.selectedOfferID == quote.request.offerA.id ? quote.request.offerA : quote.request.offerB
                row.amount = offer.usableQuantity?.amount.description ?? ""
                row.unit = offer.usableQuantity?.unit ?? .count
                if let cents = offer.price?.minorUnits { row.price = String(format: "%lld.%02lld", cents / 100, cents % 100) }
                row.source = [shop.basis.branch, quote.source, offer.label].filter { !$0.isEmpty }.joined(separator: " · ")
                row.observed = quote.reviewedAt
                row.selectedOffer = offer
            }
            if !line.isChecked, !sources.isEmpty, sources.allSatisfy({ $0.notes == label.notes && Set($0.exclusions) == Set(label.exclusions) }) {
                indices[label, default: []].append(rows.count)
            }
            rows.append(row)
        }
        var recipeRows: [Label: Int] = [:]
        for recipe in recipes {
            for ingredient in recipe.template.ingredients {
                let label = Label(name: ingredient.name, dimension: ingredient.quantity?.unit.dimension, notes: ingredient.notes,
                                  exclusions: Array(Set(recipe.template.exclusions + ingredient.exclusions)).sorted())
                let index: Int
                if let matches = indices[label], matches.count == 1 { index = matches[0] }
                else if let previous = recipeRows[label] { index = previous }
                else {
                    index = rows.count
                    recipeRows[label] = index
                    rows.append(Self(label: label, unit: ingredient.quantity?.unit ?? .count))
                }
                rows[index].members.append((.init(recipe.id, ingredient.id), recipe.template.title))
            }
        }
        return rows
    }

    func resolved() throws -> [ThreeDinnerBasket.Food] {
        let split = !combine && members.count + (existingLine == nil ? 0 : 1) > 1
        let quantity = try DinnerEntry.quantity(amount, unit: unit)
        let price = try DinnerEntry.money(price)
        let hasOffer = quantity != nil || price != nil || !source.isEmpty
        if hasOffer {
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, observed <= Date(),
                  quantity?.amount != .zero else { throw DinnerPlanningError.reviewRequired("packEvidence") }
        }
        let offer = hasOffer ? PackOffer(id: id.uuidString, label: label.name, usableQuantity: quantity, price: price,
            confirmedConversion: selectedOffer?.usableQuantity?.amount == quantity?.amount && selectedOffer?.usableQuantity?.unit == unit
                ? selectedOffer?.confirmedConversion : nil) : nil
        var result: [ThreeDinnerBasket.Food] = []
        if !split || existingLine != nil {
            result.append(.init(id: id, name: label.name, existingLine: existingLine, existingQuantity: existingQuantity,
                members: split ? [] : Set(members.map(\.0)), offer: offer, source: source, observedAt: observed))
        }
        if split {
            result += members.map { member, _ in .init(name: label.name, members: [member]) }
        }
        return result
    }
}
