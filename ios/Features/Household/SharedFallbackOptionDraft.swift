import CoreDomain
import Foundation
import HouseholdClient

struct FallbackPackDraft: Equatable {
    let id: UUID
    var label = ""
    var exclusions = ""
    var amount = ""
    var unit: UnitOfMeasure
    var price = ""
    var availability = ""

    init(unit: UnitOfMeasure) { self.id = UUID(); self.unit = unit }

    func offer() throws -> SharedFallbackOffer {
        guard let qty = try DinnerEntry.quantity(amount, unit: unit), qty.amount > .zero,
              qty.amount.numerator <= 1_000_000_000, qty.amount.denominator <= 1_000_000_000,
              let money = try DinnerEntry.money(price), money.minorUnits >= 0,
              let cents = Int(exactly: money.minorUnits), let packs = Int(availability), packs >= 0,
              !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.configuration }
        return .init(label: label, exclusionTags: DinnerEntry.list(exclusions),
                     usablePerPack: .init(amount: .init(numerator: Int(qty.amount.numerator), denominator: Int(qty.amount.denominator)),
                                         unit: qty.unit.rawValue, originalLiteral: qty.originalLiteral),
                     priceMinor: cents, availablePacks: packs, packId: id)
    }
}

struct CandidateFoodReview: Identifiable, Equatable {
    let id: UUID
    let name: String
    var sources = Set<UUID>()
    var hasOwnPack = false
    var sharedPackID: UUID?
    var pack: FallbackPackDraft
    init(_ ingredient: SharedFallbackRecipe.Ingredient) {
        id = ingredient.id
        name = ingredient.name
        pack = .init(unit: ingredient.quantity.flatMap { UnitOfMeasure(rawValue: $0.unit) } ?? .count)
    }
}

struct CandidateReviewDraft: Identifiable, Equatable {
    let candidate: SharedFallbackLibrary.Candidate
    var id: UUID { candidate.id }
    var selected = false
    var remaining: String
    var stepsComplete = false
    var ingredients: [CandidateFoodReview]
    init(_ candidate: SharedFallbackLibrary.Candidate) {
        self.candidate = candidate
        remaining = candidate.recipe.elapsedMinutes.map(String.init) ?? ""
        ingredients = candidate.recipe.ingredients.map(CandidateFoodReview.init)
    }

    func review(includeOffers: Bool) throws -> SharedFallbackReview {
        let availablePacks = ingredients.filter { $0.hasOwnPack && $0.sharedPackID == nil }.map(\.pack)
        let rows = try ingredients.map { item -> SharedFallbackReview.Ingredient in
            let offer: SharedFallbackOffer?
            if !includeOffers { offer = nil }
            else if let id = item.sharedPackID {
                guard let pack = availablePacks.first(where: { $0.id == id }) else { throw ClientError.configuration }
                offer = try pack.offer()
            } else { offer = item.hasOwnPack ? try item.pack.offer() : nil }
            return .init(ingredientId: item.id, sourceIds: item.sources.sorted { $0.uuidString < $1.uuidString }, offer: offer)
        }
        return .init(candidateId: candidate.id, revision: candidate.revision, remainingElapsedMinutes: try DinnerEntry.minutes(remaining),
                     advanceStepsCompleted: stepsComplete, ingredients: rows)
    }
}

struct FallbackTripDraft: Equatable {
    var include = false
    var minutes = ""
    var budget = ""
    var charges = ""
    func trip() throws -> SharedFallbackTrip? {
        guard include else { return nil }
        guard let time = try DinnerEntry.minutes(minutes), let ceiling = try DinnerEntry.money(budget),
              let other = try DinnerEntry.money(charges), ceiling.minorUnits >= 0, other.minorUnits >= 0,
              let limit = Int(exactly: ceiling.minorUnits), let fee = Int(exactly: other.minorUnits) else { throw ClientError.configuration }
        return .init(minutes: time, budgetMinor: limit, chargesMinor: fee, currency: "USD")
    }
}
