import Foundation
import CoreDomain

/// Parsing and arithmetic stay out of views. Empty amounts preserve uncertainty.
enum DinnerEntry {
    static func rational(_ text: String) throws -> Rational {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 64 else { throw DomainError.invalidNumber }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard let numerator = Int64(parts[0]), let denominator = Int64(parts[1]) else { throw DomainError.invalidNumber }
            return try Rational(numerator, denominator)
        }
        // A single comma is the Spanish decimal separator. Grouped numbers and
        // mixed separators are rejected, never guessed.
        return try Rational(decimal: value.replacingOccurrences(of: ",", with: "."))
    }
    static func quantity(_ text: String, unit: UnitOfMeasure) throws -> Quantity? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Quantity(amount: try rational(text), unit: unit, originalLiteral: text)
    }
    static func money(_ text: String) throws -> Money? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let cents = try rational(text).multiplied(by: Rational(100))
        guard cents.denominator == 1 else { throw DomainError.invalidNumber }
        return Money(minorUnits: cents.numerator)
    }
    static func positive(_ text: String) throws -> Rational {
        let value = try rational(text); guard value > .zero else { throw DomainError.invalidNumber }; return value
    }
    static func minutes(_ text: String) throws -> Int? {
        guard !text.isEmpty else { return nil }
        guard let value = Int(text), (0...525_600).contains(value) else { throw DomainError.invalidNumber }; return value
    }
    static func list(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    static func date(_ date: Date, zone: String, scheduled: Bool) throws -> MealDay? {
        try scheduled ? MealDay(date: date, timeZoneIdentifier: zone) : nil
    }
}
struct DinnerIngredientDraft: Identifiable {
    var id: UUID; var name: String; var amount: String; var unit: UnitOfMeasure; var notes: String; var exclusions: String
    init(_ value: MealIngredient? = nil) {
        id = value?.id ?? UUID(); name = value?.name ?? ""; amount = value?.quantity?.amount.description ?? ""
        unit = value?.quantity?.unit ?? .count; notes = value?.notes ?? ""; exclusions = value?.exclusions.joined(separator: "\n") ?? ""
    }
    func ingredient() throws -> MealIngredient {
        MealIngredient(id: id, name: name, quantity: try DinnerEntry.quantity(amount, unit: unit), notes: notes, exclusions: DinnerEntry.list(exclusions))
    }
}
struct DinnerGroupDraft: Identifiable {
    var id: UUID; var name: String; var servings: String; var isProtected: Bool
    init(_ group: ServingGroup? = nil) {
        id = group?.id ?? UUID(); name = group?.name ?? ""; servings = group?.servings.description ?? ""; isProtected = group?.isProtected ?? false
    }
    func group() throws -> ServingGroup { ServingGroup(id: id, name: name, servings: try DinnerEntry.positive(servings), isProtected: isProtected) }
}
/// Keep field context at the parser boundary; unrelated numeric errors must not
/// be described as a servings problem.
enum DinnerDraftValidationError: Error, Equatable { case totalServings }

struct DinnerTemplateDraft {
    let id: UUID
    let original: MealTemplate?
    var title: String; var servings: String; var ingredients: [DinnerIngredientDraft]; var groups: [DinnerGroupDraft]
    var notes: String; var source: String; var exclusions: String; var lead: String; var completed: String
    init(_ template: MealTemplate? = nil) {
        original = template; id = template?.id ?? UUID(); title = template?.title ?? ""; servings = template?.servings.description ?? ""
        ingredients = template?.ingredients.map(DinnerIngredientDraft.init) ?? [DinnerIngredientDraft()]
        groups = template?.servingGroups.map(DinnerGroupDraft.init) ?? []
        notes = template?.notes ?? ""; source = template?.sourceURL ?? ""; exclusions = template?.exclusions.joined(separator: "\n") ?? ""
        lead = template?.leadTimeMinutes.map(String.init) ?? ""; completed = template?.completedSteps.joined(separator: "\n") ?? ""
    }
    func template(validate: Bool = true) throws -> MealTemplate {
        let enteredServings: Rational
        do { enteredServings = try DinnerEntry.positive(servings) }
        catch { throw DinnerDraftValidationError.totalServings }
        var value = MealTemplate(id: id, title: title, servings: enteredServings, ingredients: try ingredients.map { try $0.ingredient() },
            notes: notes, sourceURL: source.isEmpty ? nil : source, exclusions: DinnerEntry.list(exclusions),
            revision: original?.revision ?? 0, servingGroups: try groups.map { try $0.group() }, leadTimeMinutes: try DinnerEntry.minutes(lead), completedSteps: DinnerEntry.list(completed), sourceEvidence: original?.sourceEvidence)
        if let original, original != value {
            let (revision, overflow) = original.revision.addingReportingOverflow(1)
            guard !overflow else { throw DomainError.overflow }; value.revision = revision
        }
        if validate { try value.validate() }; return value
    }
}
struct DinnerBindingDraft: Identifiable {
    let id: UUID; let contributionID: UUID; let groupID: UUID; let product: String; let group: ServingGroup
    var amount: String; var unit: UnitOfMeasure
    init(contribution: LedgerContribution, group: ServingGroup, existing: DinnerPortionBinding?) {
        id = existing?.id ?? UUID(); contributionID = contribution.id; groupID = group.id
        product = contribution.productName; self.group = group
        amount = existing?.quantity.amount.description ?? ""; unit = existing?.quantity.unit ?? contribution.quantity?.unit ?? .count
    }
    func binding(occurrenceID: UUID) throws -> DinnerPortionBinding {
        guard let quantity = try DinnerEntry.quantity(amount, unit: unit) else { throw DinnerPlanningError.reviewRequired("quantity") }
        return DinnerPortionBinding(id: id, occurrenceID: occurrenceID, contributionID: contributionID, groupID: groupID, quantity: quantity, servings: group.servings)
    }
}
struct DinnerCommitmentDraft: Identifiable {
    var id = UUID(); var name = ""; var portions = ""; var kind = DinnerCommitment.Kind.dinner; var isProtected = false
    func commitment() throws -> DinnerCommitment {
        DinnerCommitment(id: id, name: name, kind: kind, portions: try DinnerEntry.positive(portions), protected: isProtected)
    }
}
/// An inclusive retailer total is accepted only after the user confirms its scope.
/// Blank total/trip cash remain unknown. No fees or availability are invented.
struct DinnerStoreDraft {
    var id = UUID(); var label = ""; var storeID = ""; var branch = ""; var mode = ShoppingMode.pickup
    var slot = Date(); var observedAt = Date(); var source = ""; var total = ""; var allChargesIncluded = false
    var quantitiesMatched = false; var availability = 0; var singleStore = false
    var itemSubtotal = ""; var eligibilityTerms = ""
    var tripCash = ""; var extraMinutes = ""; var alreadyPlanned = false
    func option(commitments: DinnerCommitmentSet, basis: ShopBasis) throws -> StoreQuoteOption {
        let amount = try DinnerEntry.money(total)
        let evidence: CostEvidence = allChargesIncluded ? amount.map(CostEvidence.exact) ?? .unknown(reason: "Checkout total is unknown") : .unknown(reason: "Included charges are unreviewed")
        let context = CheckoutContext(storeID: storeID, branchID: branch, mode: mode,
            slot: ISO8601DateFormatter().string(from: slot), commitmentsID: commitments.id, observedAt: observedAt, source: source)
        var adopted = basis; adopted.branch = branch; adopted.mode = FulfillmentMode(rawValue: mode.rawValue) ?? .pickup
        adopted.slot = slot; adopted.retailerPreview = nil
        let cap = basis.cap.map { CheckoutCap(scope: basis.capScope == .wholeShop ? .wholeCheckout : basis.capScope == .dinnersOnly ? .dinner : .item, commitmentsID: commitments.id, amount: $0) }
        return StoreQuoteOption(id: id, label: label, commitments: commitments,
            quote: CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(evidence)),
            available: availability == 0 ? nil : availability == 1, quantitiesMatched: quantitiesMatched, singleStore: singleStore,
            trip: StoreTripEvidence(incrementalCash: try DinnerEntry.money(tripCash).map(CostEvidence.exact) ?? .unknown(reason: "Trip cash is unknown"),
                extraMinutes: try DinnerEntry.minutes(extraMinutes), tripAlreadyPlanned: alreadyPlanned), cap: cap, adoptionBasis: adopted, observedItemSubtotal: try DinnerEntry.money(itemSubtotal),
            eligibilityTerms: eligibilityTerms.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : eligibilityTerms)
    }
}
