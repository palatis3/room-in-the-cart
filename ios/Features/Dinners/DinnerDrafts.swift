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
    static func quantity(_ text: String, unit: UnitOfMeasure, preserving original: Quantity? = nil) throws -> Quantity? {
        if let original, text == original.amount.description, unit == original.unit { return original }
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
    static func minutes(_ text: String, maximum: Int = 525_600) throws -> Int? {
        guard !text.isEmpty else { return nil }
        guard let value = Int(text), (0...maximum).contains(value) else { throw DomainError.invalidNumber }; return value
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
    private var originalQuantity: Quantity?
    init(_ value: MealIngredient? = nil) {
        id = value?.id ?? UUID(); name = value?.name ?? ""; amount = value?.quantity?.amount.description ?? ""
        unit = value?.quantity?.unit ?? .count; notes = value?.notes ?? ""; exclusions = value?.exclusions.joined(separator: "\n") ?? ""
        originalQuantity = value?.quantity
    }
    func reviewedQuantity() throws -> Quantity? {
        try DinnerEntry.quantity(amount, unit: unit, preserving: originalQuantity)
    }
    func ingredient() throws -> MealIngredient {
        MealIngredient(id: id, name: name, quantity: try reviewedQuantity(), notes: notes, exclusions: DinnerEntry.list(exclusions))
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
    private let original: DinnerPortionBinding?
    init(contribution: LedgerContribution, group: ServingGroup, existing: DinnerPortionBinding?) {
        id = existing?.id ?? UUID(); contributionID = contribution.id; groupID = group.id
        product = contribution.productName; self.group = group
        amount = existing?.quantity.amount.description ?? ""; unit = existing?.quantity.unit ?? contribution.quantity?.unit ?? .count
        original = existing
    }
    var protectedQuantity: Quantity? { original?.quantity }
    func binding(occurrenceID: UUID, servings: Rational? = nil) throws -> DinnerPortionBinding {
        let quantity: Quantity
        if let original, amount == original.quantity.amount.description, unit == original.quantity.unit {
            quantity = original.quantity
        } else {
            guard let entered = try DinnerEntry.quantity(amount, unit: unit) else { throw DinnerPlanningError.reviewRequired("quantity") }
            quantity = entered
        }
        return DinnerPortionBinding(id: id, occurrenceID: occurrenceID, contributionID: contributionID, groupID: groupID, quantity: quantity, servings: servings ?? group.servings)
    }
}
struct DinnerCommitmentDraft: Identifiable {
    var id = UUID(); var name = ""; var portions = ""; var kind = DinnerCommitment.Kind.dinner; var isProtected = false
    private var saved: DinnerCommitment?
    init() {}
    init(_ saved: DinnerCommitment) {
        self.saved = saved; id = saved.id; name = saved.name; portions = saved.portions.description
        kind = saved.kind; isProtected = saved.protected
    }
    func commitment() throws -> DinnerCommitment {
        DinnerCommitment(id: id, name: name, kind: kind, portions: try DinnerEntry.positive(portions), protected: isProtected, day: saved?.day, reviewedPortion: saved?.reviewedPortion)
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
    private var saved: StoreQuoteOption?
    var writtenSlot: String?
    private static let unreviewedCharges = "Included charges are unreviewed"
    private static let unknownTotal = "Checkout total is unknown"

    init() {}
    init(_ saved: StoreQuoteOption) {
        self.saved = saved
        let context = saved.quote.context
        id = saved.id; label = saved.label; storeID = context.storeID; branch = context.branchID; mode = context.mode
        if let date = Self.slotDate(context.slot) { slot = date }
        else { writtenSlot = context.slot }
        observedAt = context.observedAt; source = context.source
        eligibilityTerms = saved.eligibilityTerms ?? ""; itemSubtotal = Self.amount(saved.observedItemSubtotal)
        quantitiesMatched = saved.quantitiesMatched; singleStore = saved.singleStore
        availability = saved.available.map { $0 ? 1 : 2 } ?? 0
        extraMinutes = saved.trip.extraMinutes.map(String.init) ?? ""; alreadyPlanned = saved.trip.tripAlreadyPlanned
        if case .exact(let cash) = saved.trip.incrementalCash { tripCash = Self.amount(cash) }
        if case .inclusiveTotal(let checkout) = saved.quote.pricing {
            switch checkout {
            case .exact(let money): total = Self.amount(money); allChargesIncluded = true
            case .bounded: allChargesIncluded = true
            case .unknown(let reason):
                allChargesIncluded = reason == Self.unknownTotal
                total = Self.amount(saved.unreviewedInclusiveTotal)
            }
        }
    }
    private static func amount(_ money: Money?) -> String {
        money.map { NSDecimalNumber(decimal: Decimal($0.minorUnits) / 100).stringValue } ?? ""
    }
    private static func slotDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text)
    }
    var retainedCheckout: CheckoutQuote? {
        guard let quote = saved?.quote else { return nil }
        switch quote.pricing {
        case .components, .inclusiveTotal(.bounded): return quote
        default: return quote.scope == .wholeCheckout ? nil : quote
        }
    }
    var tripRange: (Money, Money, String)? {
        guard case let .bounded(lower, upper, reason) = saved?.trip.incrementalCash else { return nil }
        return (lower, upper, reason)
    }

    func option(commitments: DinnerCommitmentSet, basis: ShopBasis) throws -> StoreQuoteOption {
        let amount = try DinnerEntry.money(total)
        let evidence: CostEvidence
        if case .inclusiveTotal(.unknown(let reason)) = saved?.quote.pricing,
           allChargesIncluded == (reason == Self.unknownTotal), amount == saved?.unreviewedInclusiveTotal {
            evidence = .unknown(reason: reason)
        } else if allChargesIncluded {
            evidence = amount.map(CostEvidence.exact) ?? .unknown(reason: Self.unknownTotal)
        } else {
            evidence = .unknown(reason: Self.unreviewedCharges)
        }
        let slotText: String
        if let writtenSlot { slotText = writtenSlot }
        else if let original = saved?.quote.context.slot, Self.slotDate(original) == slot { slotText = original }
        else { slotText = ISO8601DateFormatter().string(from: slot) }
        let context = CheckoutContext(storeID: storeID, branchID: branch, mode: mode,
            slot: slotText, commitmentsID: commitments.id, observedAt: observedAt, source: source)
        var adopted = basis; adopted.branch = branch; adopted.mode = FulfillmentMode(rawValue: mode.rawValue) ?? .pickup
        if saved?.quote.context.slot == slotText { adopted.slot = saved?.adoptionBasis?.slot }
        else { adopted.slot = writtenSlot == nil ? slot : nil }
        adopted.retailerPreview = nil
        if let original = saved?.adoptionBasis {
            adopted.timeZoneIdentifier = original.timeZoneIdentifier
            adopted.knownFees = original.knownFees
        }
        let enteredCash = try DinnerEntry.money(tripCash)
        let cash: CostEvidence
        switch saved?.trip.incrementalCash {
        case let .bounded(lower, upper, reason): cash = .bounded(lower: lower, upper: upper, reason: reason)
        case let .unknown(reason) where enteredCash == nil: cash = .unknown(reason: reason)
        default: cash = enteredCash.map(CostEvidence.exact) ?? .unknown(reason: "Trip cash is unknown")
        }
        let cap = basis.cap.map { CheckoutCap(scope: basis.capScope == .wholeShop ? .wholeCheckout : basis.capScope == .dinnersOnly ? .dinner : .item, commitmentsID: commitments.id, amount: $0) }
        return StoreQuoteOption(id: id, label: label, commitments: commitments,
            quote: CheckoutQuote(scope: saved?.quote.scope ?? .wholeCheckout, context: context, pricing: retainedCheckout?.pricing ?? .inclusiveTotal(evidence)),
            available: availability == 0 ? nil : availability == 1, quantitiesMatched: quantitiesMatched, singleStore: singleStore,
            trip: StoreTripEvidence(incrementalCash: cash,
                extraMinutes: try DinnerEntry.minutes(extraMinutes), tripAlreadyPlanned: alreadyPlanned), cap: cap, adoptionBasis: saved != nil && saved?.adoptionBasis == nil ? nil : adopted, observedItemSubtotal: try DinnerEntry.money(itemSubtotal),
            eligibilityTerms: eligibilityTerms.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : eligibilityTerms,
            unreviewedInclusiveTotal: allChargesIncluded ? nil : amount)
    }
}

/// Revisions share an unchanged commitment set. Separate imported sets retain their distinct coverage.
struct DinnerQuoteEditDraft {
    var commitments = [DinnerCommitmentDraft()]
    var secondCommitments: [DinnerCommitmentDraft] = []
    var first = DinnerStoreDraft(), second = DinnerStoreDraft()
    private var saved: TwoStoreQuotePair?
    var hasSeparateCommitments: Bool { saved.map { $0.first.commitments != $0.second.commitments } ?? false }

    init() {}
    init(_ saved: TwoStoreQuotePair) {
        self.saved = saved
        commitments = saved.first.commitments.commitments.map(DinnerCommitmentDraft.init)
        if hasSeparateCommitments { secondCommitments = saved.second.commitments.commitments.map(DinnerCommitmentDraft.init) }
        first = DinnerStoreDraft(saved.first); second = DinnerStoreDraft(saved.second)
    }
    func pair(for shop: ShoppingLedger) throws -> TwoStoreQuotePair {
        guard saved == nil || saved?.shopID == shop.id else { throw DinnerPlanningError.stalePreview }
        func set(_ rows: [DinnerCommitmentDraft], original: DinnerCommitmentSet?) throws -> DinnerCommitmentSet {
            let values = try rows.map { try $0.commitment() }
            if let original, original.commitments == values { return original }
            return DinnerCommitmentSet(commitments: values)
        }
        let a = try set(commitments, original: saved?.first.commitments)
        let b = try hasSeparateCommitments ? set(secondCommitments, original: saved?.second.commitments) : a
        return try TwoStoreQuotePair(shopID: shop.id, baseRevisionID: shop.revisionID, basisRevision: shop.basisRevision,
            first: first.option(commitments: a, basis: shop.basis), second: second.option(commitments: b, basis: shop.basis))
    }
}
