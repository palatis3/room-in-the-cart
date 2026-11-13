import SwiftUI
import CoreDomain

struct PickupOfferCostDraft: Equatable {
    var kind = "unknown"
    var lower = ""
    var upper = ""
    var reason = pTr("Not yet reviewed.")
    init(_ evidence: CostEvidence? = nil) {
        guard let evidence else { return }
        switch evidence {
        case .exact(let amount): kind = "exact"; lower = Self.literal(amount)
        case .bounded(let lower, let upper, let reason):
            kind = "bounded"; self.lower = Self.literal(lower); self.upper = Self.literal(upper); self.reason = reason
        case .unknown(let reason): self.reason = reason
        }
    }
    static func literal(_ money: Money) -> String {
        "\(money.minorUnits / 100).\(String(format: "%02lld", money.minorUnits % 100))"
    }
    func evidence() throws -> CostEvidence {
        switch kind {
        case "exact":
            guard let amount = try ComparisonModel.money(lower) else { throw DomainError.invalidNumber }
            return .exact(amount)
        case "bounded":
            guard let low = try ComparisonModel.money(lower), let high = try ComparisonModel.money(upper) else { throw DomainError.invalidNumber }
            return .bounded(lower: low, upper: high, reason: reason)
        default: return .unknown(reason: reason)
        }
    }
}

struct PickupOfferConversionScope: Hashable {
    let lineID: UUID?
    let replacement: String
    let originalItem: String?
    let targetUnit: UnitOfMeasure?

    init(lineID: UUID?, replacement: String, journey: PickupJourney) {
        self.lineID = lineID
        self.replacement = replacement
        let line = journey.pickup?.orderLines.first { $0.id == lineID }
        originalItem = line?.name
        targetUnit = line?.ordered.unit
    }
}

struct PickupOfferForecastDraft: Equatable {
    var enabled: Bool
    var usable = ""
    var usableUnit: UnitOfMeasure = .count {
        didSet { if usableUnit != oldValue { conversion = nil } }
    }
    var conversion: ComparisonConversion? {
        didSet {
            if conversion != oldValue { decisions.removeAll(); exclusionsConfirmed.removeAll() }
        }
    }
    var retained = PickupOfferCostDraft()
    var lineAllowance = ""
    var decisions: [UUID: PickupOfferDishDecision] = [:]
    var exclusionsConfirmed: Set<UUID> = []
    var included: Set<UUID> = []
    var otherCost = PickupOfferCostDraft()
    var wholeCap = ""
    var source = pTr("Manual offer review")
    var observedAt = Date()
    private var originalUsable: Quantity?
    private var originalConversion: ComparisonConversion?
    private var conversionScope: PickupOfferConversionScope?

    init(original: PickupOffer?, journey: PickupJourney) {
        enabled = original == nil || original?.evaluation != nil
        guard let input = original?.evaluation?.inputs else { return }
        originalUsable = input.offeredUsable
        usable = input.offeredUsable?.amount.description ?? ""
        usableUnit = input.offeredUsable?.unit ?? .count
        if let basis = input.offeredUsable?.confirmedConversion {
            conversion = ComparisonConversion(sourceLiteral: basis.sourceLiteral ?? "1",
                targetLiteral: basis.targetLiteral ?? basis.targetAmountPerSourceUnit.description,
                sourceUnit: basis.sourceUnit, targetUnit: basis.targetUnit, sourceNote: basis.sourceNote)
            originalConversion = conversion
        }
        if let original {
            conversionScope = .init(lineID: original.lineID, replacement: original.replacement, journey: journey)
        }
        retained = PickupOfferCostDraft(input.retainedOriginalCharge)
        lineAllowance = input.lineAllowance.map(PickupOfferCostDraft.literal) ?? ""
        for rule in input.dishRules {
            decisions[rule.needID] = rule.decision
            if rule.exclusionsConfirmed { exclusionsConfirmed.insert(rule.needID) }
        }
        included = Set(input.includedOfferIDs)
        otherCost = PickupOfferCostDraft(input.otherCheckoutCost)
        wholeCap = input.wholeCheckoutCap.map(PickupOfferCostDraft.literal) ?? ""
        source = input.checkoutSource; observedAt = input.checkoutObservedAt
        if let original, (try? PickupOfferEvaluation.isCurrent(offer: original, journey: journey)) != true {
            decisions.removeAll(); exclusionsConfirmed.removeAll()
        }
    }
    mutating func updateConversionScope(_ scope: PickupOfferConversionScope) {
        if conversionScope != scope { conversion = nil }
        conversionScope = scope
    }

    func inputs(offer: PickupOffer, journey: PickupJourney) throws -> PickupOfferEvaluationInputs {
        var amount: Quantity?
        if usable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { amount = nil }
        else if let originalUsable, usable == originalUsable.amount.description, usableUnit == originalUsable.unit { amount = originalUsable }
        else {
            let pieces = usable.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
            if pieces.count == 2, let n = Int64(pieces[0]), let d = Int64(pieces[1]) {
                amount = Quantity(amount: try Rational(n, d), unit: usableUnit, originalLiteral: usable)
            } else { amount = try ComparisonModel.quantity(usable, usableUnit) }
        }
        if let usableAmount = amount {
            var basis: UnitBasis?
            let currentScope = PickupOfferConversionScope(lineID: offer.lineID, replacement: offer.replacement, journey: journey)
            if conversionScope == currentScope, let conversion {
                if conversion == originalConversion, usableUnit == originalUsable?.unit {
                    basis = originalUsable?.confirmedConversion
                } else if conversion.sourceUnit == usableUnit, conversion.targetUnit == currentScope.targetUnit {
                    basis = try conversion.unitBasis()
                }
            }
            amount = Quantity(amount: usableAmount.amount, unit: usableAmount.unit,
                              originalLiteral: usableAmount.originalLiteral, confirmedConversion: basis)
        }
        let rules = journey.needs.filter { $0.orderLineID == offer.lineID }.map { need in
            PickupOfferDishRule(needID: need.id, decision: decisions[need.id] ?? .unreviewed, exclusionsConfirmed: exclusionsConfirmed.contains(need.id))
        }
        return PickupOfferEvaluationInputs(offeredUsable: amount, retainedOriginalCharge: try retained.evidence(),
            lineAllowance: try ComparisonModel.money(lineAllowance), dishRules: rules,
            includedOfferIDs: Array(included.union([offer.id])).sorted { $0.uuidString < $1.uuidString },
            otherCheckoutCost: try otherCost.evidence(), wholeCheckoutCap: try ComparisonModel.money(wholeCap),
            checkoutSource: source, checkoutObservedAt: observedAt)
    }
}

struct PickupOfferForecastEditor: View {
    @Binding var draft: PickupOfferForecastDraft
    let journey: PickupJourney
    let lineID: UUID?
    let offerID: UUID
    let replacement: String
    private var conversionScope: PickupOfferConversionScope {
        .init(lineID: lineID, replacement: replacement, journey: journey)
    }
    var body: some View {
        Group {
            Section(pTr("Meal and checkout forecast")) {
                Toggle(pTr("Review usable yield, meal suitability, and combined cost"), isOn: $draft.enabled)
                    .accessibilityIdentifier("pickup.offer.forecast.enabled")
                Text(pTr("This is a forecast of expected food and charges. It does not record received food or retailer acceptance."))
            }
            if draft.enabled {
                yieldSection
                dishesSection
                simultaneousSection
                checkoutSection
            } else {
                Text(pTr("This saved offer has no reviewed meal or combined-cost forecast. Its suitability and joint affordability remain unresolved."))
            }
        }
        .onChange(of: conversionScope, initial: true) { _, scope in draft.updateConversionScope(scope) }
    }
    private var yieldSection: some View {
        Section(pTr("Expected usable yield and remaining original charge")) {
            Text(pTr("Expected usable amount from the whole offered pack (blank if unknown)")).font(.caption)
            TextField(pTr("Expected usable amount from the whole offered pack (blank if unknown)"), text: $draft.usable)
                .accessibilityIdentifier("pickup.offer.usable")
            Picker(pTr("Expected usable unit"), selection: $draft.usableUnit) {
                ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pTr($0.rawValue)).tag($0) }
            }.accessibilityIdentifier("pickup.offer.usable.unit")
            if let target = conversionScope.targetUnit {
                PackConversionControl(packLabel: replacement, sourceUnit: draft.usableUnit, targetUnit: target,
                                      conversion: $draft.conversion, identifier: "pickup.offer.conversion")
                    .id(conversionScope)
                    .id(draft.usableUnit)
            }
            Text(pTr("Enter the total usable yield covered by the offered price. A package count or label is not a confirmed edible yield. Missing mass-to-volume conversions stay unresolved."))
            PickupOfferCostEditor(title: pTr("Charge for the original amount still expected"), draft: $draft.retained, identifier: "pickup.offer.retained")
            Text(pTr("Inherited allowance for this original line (USD, optional)")).font(.caption)
            TextField(pTr("Inherited allowance for this original line (USD, optional)"), text: $draft.lineAllowance)
                .keyboardType(.decimalPad).accessibilityIdentifier("pickup.offer.lineAllowance")
            Text(pTr("The retained original charge consumes this line allowance. It is separate from the maximum price authorized for the replacement."))
        }
    }
    private var dishesSection: some View {
        Section(pTr("Per-dish replacement suitability")) {
            let needs = journey.needs.filter { $0.orderLineID == lineID }
            if needs.isEmpty { Text(pTr("No linked meal needs are saved for this line. Meal suitability remains unresolved.")) }
            ForEach(needs) { need in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(need.name): \(pQuantity(need.amount))").font(.headline)
                    if need.priority == .protected { Text(pTr("Protected portions are allocated first.")) }
                    if let detail = journey.needDetails.first(where: { $0.id == need.id }) {
                        Text(detail.mealName)
                        if !detail.exclusions.isEmpty {
                            Text("\(pTr("Keep these exclusions")): \(detail.exclusions.joined(separator: ", "))")
                            Toggle(pTr("I checked this replacement against all saved exclusions for this dish."), isOn: Binding(
                                get: { draft.exclusionsConfirmed.contains(need.id) },
                                set: { if $0 { draft.exclusionsConfirmed.insert(need.id) } else { draft.exclusionsConfirmed.remove(need.id) } }))
                                .accessibilityIdentifier("pickup.offer.exclusions.\(need.id.uuidString)")
                        }
                    }
                    Picker(pTr("Use this replacement for this dish"), selection: Binding(
                        get: { draft.decisions[need.id] ?? .unreviewed }, set: { draft.decisions[need.id] = $0 })) {
                        Text(pTr("Not reviewed")).tag(PickupOfferDishDecision.unreviewed)
                        Text(pTr("Approved for this dish")).tag(PickupOfferDishDecision.accepted)
                        Text(pTr("Excluded from this dish")).tag(PickupOfferDishDecision.declined)
                    }.accessibilityIdentifier("pickup.offer.dish.\(need.id.uuidString)")
                }
            }
            Text(pTr("Changing the replacement, required quantity, remaining original quantity, or expected yield clears dish approvals and exclusion checks. Review them again."))
            Text(pTr("Dish approval is a private planning choice. It does not certify allergen safety or send acceptance to the retailer."))
        }
    }
    private var simultaneousSection: some View {
        Section(pTr("Simultaneous offers sharing this checkout")) {
            Text(pTr("This offer is included. Select other saved offers that must fit the same checkout allowance. Each original line can have only one selected replacement."))
            ForEach(journey.offers.filter { $0.id != offerID && $0.lineID != lineID }) { other in
                let conflicts = journey.offers.contains { $0.id != other.id && $0.lineID == other.lineID && draft.included.contains($0.id) }
                Toggle(other.replacement, isOn: Binding(get: { draft.included.contains(other.id) }, set: {
                    if $0 { draft.included.insert(other.id) } else { draft.included.remove(other.id) }
                })).disabled(conflicts || other.evaluation == nil)
                    .accessibilityIdentifier("pickup.offer.simultaneous.\(other.id.uuidString)")
                if other.evaluation == nil { Text(pTr("Review and save this other offer's forecast before including it.")) }
            }
        }
    }
    private var checkoutSection: some View {
        Section(pTr("Combined checkout evidence")) {
            PickupOfferCostEditor(title: pTr("Net cost of everything outside the selected offers"), draft: $draft.otherCost, identifier: "pickup.offer.otherCost")
            Text(pTr("Include unaffected items and all applicable fees, tax, deposits, and discounts once. Exclude every selected replacement and its retained original charge; those are added separately. A later shortfall does not create a new placement fee."))
            Text(pTr("Whole-checkout allowance (USD, optional)")).font(.caption)
            TextField(pTr("Whole-checkout allowance (USD, optional)"), text: $draft.wholeCap)
                .keyboardType(.decimalPad).accessibilityIdentifier("pickup.offer.wholeCap")
            Text(pTr("Source of this checkout evidence")).font(.caption)
            TextField(pTr("Source of this checkout evidence"), text: $draft.source).accessibilityIdentifier("pickup.offer.checkoutSource")
            DatePicker(pTr("Checkout evidence recorded at"), selection: $draft.observedAt)
            Text(pTr("Do not copy an inclusive retailer total into the unaffected-cost field unless it already excludes all selected affected charges. Leave it unknown when the breakdown is unavailable."))
        }
    }
}

private struct PickupOfferCostEditor: View {
    let title: String
    @Binding var draft: PickupOfferCostDraft
    let identifier: String
    var body: some View {
        Text(title).font(.headline)
        Picker(pTr("Price evidence"), selection: $draft.kind) {
            Text(pTr("Exact price")).tag("exact")
            Text(pTr("Bounded price")).tag("bounded")
            Text(pTr("Unknown price")).tag("unknown")
        }.accessibilityIdentifier(identifier + ".kind")
        if draft.kind != "unknown" {
            Text(pTr(draft.kind == "bounded" ? "Lower amount (USD)" : "Amount (USD)")).font(.caption)
            TextField(pTr(draft.kind == "bounded" ? "Lower amount (USD)" : "Amount (USD)"), text: $draft.lower)
                .keyboardType(.decimalPad).accessibilityIdentifier(identifier + ".lower")
        }
        if draft.kind == "bounded" {
            Text(pTr("Upper amount (USD)")).font(.caption)
            TextField(pTr("Upper amount (USD)"), text: $draft.upper).keyboardType(.decimalPad).accessibilityIdentifier(identifier + ".upper")
        }
        if draft.kind != "exact" {
            Text(pTr("Why this charge is unresolved")).font(.caption)
            TextField(pTr("Why this charge is unresolved"), text: $draft.reason).accessibilityIdentifier(identifier + ".reason")
        }
    }
}

struct PickupOfferForecastResults: View {
    let offer: PickupOffer
    let journey: PickupJourney
    var body: some View {
        if offer.evaluation == nil {
            Text(pTr("No saved meal or combined-cost forecast. Reopen this offer to review it."))
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let result = try? PickupOfferEvaluation.evaluate(offer: offer, journey: journey, at: context.date) {
                    results(result)
                } else {
                    Text(pTr("The saved forecast cannot be evaluated. Reopen this offer and review its evidence."))
                }
            }
        }
    }
    private func results(_ result: PickupOfferEvaluationResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pTr("Combined-cost forecast")).font(.headline)
            if let input = offer.evaluation?.inputs {
                Text("\(pTr("Evidence source")): \(input.checkoutSource)")
                Text("\(pTr("Evidence recorded at")): \(input.checkoutObservedAt.formatted())")
                Text("\(pTr("Net unaffected checkout cost")): \(pickupOfferPriceText(input.otherCheckoutCost))")
                Text("\(pTr("Reviewed whole-checkout allowance")): \(input.wholeCheckoutCap.map(pMoney) ?? pTr("Unresolved"))")
                Text("\(pTr("Inherited line allowance")): \(input.lineAllowance.map(pMoney) ?? pTr("Unresolved"))")
                ForEach(selectedOffers(input)) { selected in
                    Text(selected.replacement).font(.headline)
                    Text("\(pTr("Retained original charge")): \(selected.evaluation.map { pickupOfferPriceText($0.inputs.retainedOriginalCharge) } ?? pTr("Unresolved"))")
                    Text("\(pTr("Replacement charge")): \(pickupOfferPriceText(selected.price))")
                    Text("\(pTr("Maximum price")): \(selected.ceiling.map(pMoney) ?? pTr("Unresolved"))")
                    Text(pickupOfferAssessmentText(selected))
                    if let assessment = result.selectedOffers.first(where: { $0.id == selected.id }) {
                        Text(lineAssessmentText(assessment.lineAssessment))
                            .accessibilityIdentifier("pickup.offer.forecast.lineAssessment.\(selected.id.uuidString)")
                        Text("\(pTr("Maximum replacement price after retained original charge")): \(assessment.lineMaximum.map(pMoney) ?? pTr("Unresolved"))")
                    }
                    Text("\(pTr("Expected offered usable yield")): \(selected.evaluation?.inputs.offeredUsable.map { pQuantity($0) } ?? pTr("Unresolved"))")
                    if let basis = selected.evaluation?.inputs.offeredUsable?.confirmedConversion {
                        Text(ComparisonConversion.readableText(for: basis))
                            .accessibilityIdentifier("pickup.offer.forecast.conversion.\(selected.id.uuidString)")
                    }
                }
            }
            if !result.isCurrent { Text(pTr("This forecast is stale. Review current offers, meal needs, and checkout evidence before using it.")) }
            Text("\(pTr("Combined expected cost")): \(combinedCostText(result))")
                .accessibilityIdentifier("pickup.offer.forecast.combined")
            Text(checkoutAssessment(result.checkoutAssessment)).accessibilityIdentifier("pickup.offer.forecast.checkout")
            if let overage = result.minimumOverage {
                Text("\(pTr("Minimum forecast overage")): \(pMoney(overage))").accessibilityIdentifier("pickup.offer.forecast.overage")
            }
            Text("\(pTr("Maximum replacement price after retained original charge")): \(result.lineMaximum.map(pMoney) ?? pTr("Unresolved"))")
                .accessibilityIdentifier("pickup.offer.forecast.lineMaximum")
            Text("\(pTr("Maximum replacement price after shared allowance")): \(result.replacementMaximum.map(pMoney) ?? pTr("Unresolved"))")
                .accessibilityIdentifier("pickup.offer.forecast.maximum")
            Text(pTr("The saved offer-specific ceiling also applies. A combined checkout that fits does not authorize exceeding that ceiling."))
            Text("\(pTr("Reviewed maximum in the retailer note")): \(offer.evaluation?.effectiveNoteCeiling.map(pMoney) ?? pTr("Unresolved"))")
                .accessibilityIdentifier("pickup.offer.forecast.noteCeiling")
            Text(pTr("The retailer note uses the lowest reviewed maximum from your explicit offer ceiling, the inherited line allowance after retained charges, and any known shared allowance. An unknown shared allowance still leaves joint affordability unresolved."))
            ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in Text(issueText(issue)) }
            Text(pTr("Forecast uncovered meal quantities")).font(.headline)
            ForEach(result.dishes, id: \.needID) { dish in
                VStack(alignment: .leading, spacing: 6) {
                    Text(dish.name).font(.headline)
                    Text(decisionText(dish.decision))
                    if dish.priority == .protected { Text(pTr("Protected portions are allocated first.")) }
                    Text("\(pTr("Expected original allocated")): \(quantityText(dish.originalAllocated, dish.unit))")
                    Text("\(pTr("Expected replacement allocated")): \(quantityText(dish.replacementAllocated, dish.unit))")
                    Text("\(pTr("Still uncovered in this forecast")): \(quantityText(dish.shortfall, dish.unit))")
                        .accessibilityIdentifier("pickup.offer.forecast.shortfall.\(dish.needID.uuidString)")
                    ForEach(Array(dish.issues.enumerated()), id: \.offset) { _, issue in Text(issueText(issue)) }
                }
            }
            Text(pTr("Expected quantities can change at pickup. Confirm actual arrival and usable food separately; this forecast does not fill a meal."))
        }
    }
    private func combinedCostText(_ result: PickupOfferEvaluationResult) -> String {
        if let maximum = result.maximumCost {
            if maximum == result.minimumCost { return pMoney(maximum) }
            return "\(pMoney(result.minimumCost)) – \(pMoney(maximum))"
        }
        return "\(pTr("At least")) \(pMoney(result.minimumCost)) · \(pTr("Remaining charges unresolved"))"
    }
    private func selectedOffers(_ input: PickupOfferEvaluationInputs) -> [PickupOffer] {
        input.includedOfferIDs.compactMap { id in id == offer.id ? offer : journey.offers.first(where: { $0.id == id }) }
    }
    private func quantityText(_ amount: Rational?, _ unit: UnitOfMeasure) -> String {
        guard let amount else { return pTr("Unresolved") }
        return pQuantity(amount, unit: unit)
    }
    private func decisionText(_ decision: PickupOfferDishDecision) -> String {
        switch decision {
        case .accepted: return pTr("Approved for this dish")
        case .declined: return pTr("Excluded from this dish")
        case .unreviewed: return pTr("Not reviewed")
        }
    }
    private func lineAssessmentText(_ assessment: PickupOfferCeilingAssessment) -> String {
        switch assessment {
        case .within: return pTr("This replacement and its retained original charge fit their inherited line allowance.")
        case .over: return pTr("This replacement and its retained original charge exceed their inherited line allowance.")
        case .conditional: return pTr("This line's cost range crosses its inherited allowance.")
        case .unknown: return pTr("This line's combined charge is unresolved; its inherited allowance cannot be confirmed.")
        case .noCeiling: return pTr("No inherited allowance is saved for this selected line.")
        }
    }
    private func checkoutAssessment(_ assessment: PickupOfferCeilingAssessment) -> String {
        switch assessment {
        case .within: return pTr("The combined forecast is within the reviewed whole-checkout allowance.")
        case .over: return pTr("The combined forecast exceeds the reviewed whole-checkout allowance.")
        case .conditional: return pTr("The combined cost range crosses the allowance. Joint affordability is conditional.")
        case .unknown: return pTr("Combined cost is unresolved. Joint affordability cannot be confirmed.")
        case .noCeiling: return pTr("No whole-checkout allowance was entered. Joint affordability remains unresolved.")
        }
    }
    private func issueText(_ issue: PickupOfferEvaluationIssue) -> String {
        switch issue {
        case .unknownUsable: return pTr("Offered usable yield is unknown.")
        case .conversionUnknown: return pTr("A required unit conversion is not confirmed.")
        case .dishUnreviewed: return pTr("Replacement suitability for this dish has not been reviewed.")
        case .exclusionsUnreviewed: return pTr("Saved exclusions have not been confirmed for this replacement.")
        case .missingOfferEvidence: return pTr("A selected simultaneous offer lacks reviewed evidence.")
        case .noLinkedNeeds: return pTr("No linked meal needs are available for this offer.")
        case .unknownCost: return pTr("Some selected charges remain unknown or bounded.")
        case .staleSource: return pTr("Saved source evidence changed. Reopen and review the forecast.")
        }
    }
}
