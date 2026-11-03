import SwiftUI
import CoreDomain

/// A draft belongs to one offer and one pickup. Display rounding is never used to
/// reconstruct saved monetary or quantity evidence.
private struct PickupOfferDraft: Equatable {
    var lineID: UUID?
    var replacement = ""
    var required = ""
    var remaining = ""
    var priceKind = "exact"
    var price = ""
    var upper = ""
    var reason = ""
    var ceiling = ""
    var deadline = Date()
    var zone = TimeZone.current.identifier
    var fallback = ""
    var preference = ""
    var response = ""

    init(original: PickupOffer?) {
        guard let original else { return }
        lineID = original.lineID; replacement = original.replacement
        required = original.required.amount.description; remaining = original.remainingOriginal.amount.description
        switch original.price {
        case let .exact(value): price = Self.moneyLiteral(value)
        case let .bounded(lower, upper, reason):
            priceKind = "bounded"; price = Self.moneyLiteral(lower); self.upper = Self.moneyLiteral(upper); self.reason = reason
        case let .unknown(reason): priceKind = "unknown"; self.reason = reason
        }
        ceiling = original.ceiling.map(Self.moneyLiteral) ?? ""
        deadline = original.deadline.cutoff; zone = original.deadline.timeZoneID
        fallback = original.fallback; preference = original.householdPreference; response = original.retailerResponse
    }
    static func moneyLiteral(_ money: Money) -> String {
        let cents = money.minorUnits
        return "\(cents / 100).\(String(format: "%02lld", cents % 100))"
    }
    private func quantity(_ text: String, unit: UnitOfMeasure, original: Quantity?) throws -> Quantity {
        if let original, text == original.amount.description { return original }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let numerator = Int64(parts[0]), let denominator = Int64(parts[1]) {
            return Quantity(amount: try Rational(numerator, denominator), unit: unit, originalLiteral: text)
        }
        guard let value = try ComparisonModel.quantity(cleaned, unit) else { throw DomainError.invalidNumber }
        return value
    }
    func offer(id: UUID, journey: PickupJourney, original: PickupOffer?) throws -> PickupOffer {
        guard let line = journey.pickup?.orderLines.first(where: { $0.id == lineID }) else { throw PickupError.unknownOrderLine }
        let evidence: CostEvidence
        switch priceKind {
        case "bounded":
            guard let lower = try ComparisonModel.money(price), let upper = try ComparisonModel.money(upper) else { throw DomainError.invalidNumber }
            evidence = .bounded(lower: lower, upper: upper, reason: reason)
        case "unknown": evidence = .unknown(reason: reason)
        default:
            if let value = try ComparisonModel.money(price) { evidence = .exact(value) }
            else { evidence = .unknown(reason: pTr("Offered price is not confirmed.")) }
        }
        return PickupOffer(id: id, lineID: line.id, replacement: replacement,
            required: try quantity(required, unit: original?.required.unit ?? line.ordered.unit, original: original?.required),
            remainingOriginal: try quantity(remaining, unit: original?.remainingOriginal.unit ?? line.ordered.unit, original: original?.remainingOriginal),
            price: evidence, ceiling: try ComparisonModel.money(ceiling),
            deadline: try RetailerDeadline(cutoff: deadline, timeZoneID: zone), fallback: fallback,
            householdPreference: preference, retailerResponse: response)
    }
}

struct PickupOfferEditorView: View {
    @ObservedObject var model: PickupModel
    let journey: PickupJourney
    let original: PickupOffer?
    @State private var offerID: UUID
    @State private var draft: PickupOfferDraft
    @State private var forecast: PickupOfferForecastDraft
    @State private var reviewed: PickupOffer?
    @State private var approved = false
    @State private var formError: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    init(model: PickupModel, journey: PickupJourney, original: PickupOffer? = nil) {
        self.model = model; self.journey = journey; self.original = original
        _offerID = State(initialValue: original?.id ?? UUID())
        _draft = State(initialValue: PickupOfferDraft(original: original))
        _forecast = State(initialValue: PickupOfferForecastDraft(original: original, journey: journey))
    }
    private var scopeMatches: Bool { model.journey?.id == journey.id }
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            if !scopeMatches {
                Text(pTr("Reopen this pickup and review the saved offer before changing it."))
            } else if let reviewed {
                Section(pTr("Review this saved offer change")) {
                    Text(pTr(original == nil ? "This creates a separate store-offer record." : "This updates only the selected saved offer."))
                    PickupOfferFacts(offer: reviewed, journey: journey)
                    Toggle(pTr("I reviewed this offer evidence and the separate retailer response."), isOn: $approved)
                        .accessibilityIdentifier("pickup.offer.approve")
                    Button(pTr("Save offer for review")) { Task {
                        if await model.saveReviewedOffer(reviewed, journeyID: journey.id, original: original) { dismiss() }
                    } }
                    .accessibilityIdentifier("pickup.offer.save")
                    .disabled(!approved || model.saving || model.hasPendingSave)
                    Button(pTr("Return to offer draft")) { self.reviewed = nil; approved = false }
                        .frame(minHeight: 44)
                }
            } else {
                draftFields
                Button(pTr("Review offer changes")) { review() }
                    .accessibilityIdentifier("pickup.offer.review").frame(minHeight: 44)
                    .disabled(model.saving || model.hasPendingSave)
            }
            if let formError { Text(formError).foregroundStyle(.red).accessibilityIdentifier("pickup.offer.error") }
        }
        .navigationTitle(pTr(original == nil ? "New store offer" : "Review or edit saved offer"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(pTr("Cancel")) { dismiss() }.accessibilityIdentifier("pickup.offer.cancel")
            }
        }
         .onChange(of: draft) { old, new in
            reviewed = nil; approved = false; formError = nil
            if old.replacement != new.replacement || old.required != new.required || old.remaining != new.remaining || old.lineID != new.lineID {
                forecast.decisions.removeAll(); forecast.exclusionsConfirmed.removeAll()
            }
        }
         .onChange(of: forecast) { old, new in
            reviewed = nil; approved = false; formError = nil
            if old.usable != new.usable || old.usableUnit != new.usableUnit {
                forecast.decisions.removeAll(); forecast.exclusionsConfirmed.removeAll()
            }
        }
        .onChange(of: draft.lineID) { _, _ in
            forecast.included.removeAll()
            if forecast.usable.isEmpty, let line = journey.pickup?.orderLines.first(where: { $0.id == draft.lineID }) { forecast.usableUnit = line.ordered.unit }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { approved = false } }
    }
    @ViewBuilder private var draftFields: some View {
        Section(pTr("Store offer")) {
            Picker(pTr("Original line"), selection: $draft.lineID) {
                Text(pTr("Choose a line")).tag(UUID?.none)
                ForEach(journey.pickup?.orderLines ?? []) { Text($0.name).tag(Optional($0.id)) }
            }.accessibilityIdentifier("pickup.offer.line").disabled(original != nil)
            TextField(pTr("Replacement and offered pack"), text: $draft.replacement).accessibilityIdentifier("pickup.offer.replacement")
            TextField(pTr("Required usable amount"), text: $draft.required).accessibilityIdentifier("pickup.offer.required")
            TextField(pTr("Original amount still expected"), text: $draft.remaining).accessibilityIdentifier("pickup.offer.remaining")
            if let line = journey.pickup?.orderLines.first(where: { $0.id == draft.lineID }) {
                Text("\(pTr("Original order quantity")): \(pQuantity(line.ordered))")
                Text("\(pTr("Required amount unit")): \(pTr((original?.required.unit ?? line.ordered.unit).rawValue))")
                Text("\(pTr("Remaining amount unit")): \(pTr((original?.remainingOriginal.unit ?? line.ordered.unit).rawValue))")
            }
            Text(pTr("Use original units. Exact fractions such as 1/3 are accepted; no unit conversion is assumed."))
        }
        Section(pTr("Offered price")) {
            Picker(pTr("Price evidence"), selection: $draft.priceKind) {
                Text(pTr("Exact price")).tag("exact")
                Text(pTr("Bounded price")).tag("bounded")
                Text(pTr("Unknown price")).tag("unknown")
            }.accessibilityIdentifier("pickup.offer.price.kind")
            if draft.priceKind != "unknown" {
                TextField(pTr(draft.priceKind == "bounded" ? "Lower offered price (USD)" : "Offered price (USD)"), text: $draft.price)
                    .keyboardType(.decimalPad).accessibilityIdentifier(draft.priceKind == "bounded" ? "pickup.offer.price.lower" : "pickup.offer.price")
            }
            if draft.priceKind == "bounded" {
                TextField(pTr("Upper offered price (USD)"), text: $draft.upper).keyboardType(.decimalPad).accessibilityIdentifier("pickup.offer.price.upper")
            }
            if draft.priceKind != "exact" {
                TextField(pTr("Why the offered price is unresolved"), text: $draft.reason).accessibilityIdentifier("pickup.offer.price.reason")
            }
            TextField(pTr("Reviewed offer-specific maximum price"), text: $draft.ceiling).keyboardType(.decimalPad).accessibilityIdentifier("pickup.offer.ceiling")
            Text(pTr("A line ceiling does not establish that the whole checkout fits. Review combined charges separately."))
        }
        PickupOfferForecastEditor(draft: $forecast, journey: journey, lineID: draft.lineID, offerID: offerID)
        Section(pTr("Retailer response")) {
            DatePicker(pTr("Retailer response cutoff"), selection: $draft.deadline)
                .environment(\.timeZone, TimeZone(identifier: draft.zone) ?? .current)
                .accessibilityIdentifier("pickup.offer.cutoff")
            TextField(pTr("Time zone"), text: $draft.zone)
            TextField(pTr("Fallback if short"), text: $draft.fallback)
            TextField(pTr("Household preference (not retailer acceptance)"), text: $draft.preference).accessibilityIdentifier("pickup.offer.preference")
            TextField(pTr("Retailer response (leave blank if pending)"), text: $draft.response).accessibilityIdentifier("pickup.offer.response")
            Text(pTr("Saving or copying an offer does not confirm retailer acceptance, received food, or usable meal portions."))
        }
    }
    private func review() {
        do {
            var offer = try draft.offer(id: offerID, journey: journey, original: original)
            guard let line = journey.pickup?.orderLines.first(where: { $0.id == offer.lineID }) else { throw PickupError.unknownOrderLine }
            try PickupOfferReview.validate(offer, ordered: line.ordered)
            if forecast.enabled {
                offer.evaluation = try PickupOfferEvaluation.review(offer: offer, inputs: forecast.inputs(offer: offer, journey: journey), journey: journey, at: Date())
            }
            reviewed = offer; approved = false; formError = nil
        } catch { formError = pTr("Check the offer amounts, original remaining quantity, price, and retailer deadline. Nothing was changed.") }
    }
}

struct PickupOfferFacts: View {
    let offer: PickupOffer
    let journey: PickupJourney
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(offer.replacement).font(.headline)
            if let line = journey.pickup?.orderLines.first(where: { $0.id == offer.lineID }) { Text("\(pTr("Original line")): \(line.name)") }
            Text("\(pTr("Required usable")): \(pQuantity(offer.required))")
            Text("\(pTr("Original amount still expected")): \(pQuantity(offer.remainingOriginal))")
            Text("\(pTr("Offered price")): \(pickupOfferPriceText(offer.price))")
            Text("\(pTr("Maximum price")): \(offer.ceiling.map(pMoney) ?? pTr("Unresolved"))")
            Text(pickupOfferAssessmentText(offer)).accessibilityIdentifier("pickup.offer.assessment")
            Text(pTr("A line ceiling does not establish that the whole checkout fits. Review combined charges separately."))
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(pTr((try? offer.deadline.status(at: context.date)) == .awaitPickup ? "Await pickup · fill still unknown" : "Decision pending before cutoff"))
            }
            Text("\(pickupOfferCutoffText(offer)) · \(offer.deadline.timeZoneID)")
            Text("\(pTr("Household preference")): \(offer.householdPreference.isEmpty ? pTr("Unresolved") : offer.householdPreference)")
            Text("\(pTr("Retailer response")): \(offer.retailerResponse.isEmpty ? pTr("Pending") : offer.retailerResponse)")
            Text("\(pTr("If short")): \(offer.fallback)")
            PickupOfferForecastResults(offer: offer, journey: journey)
            let needs = journey.needs.filter { $0.orderLineID == offer.lineID }
            Text(pTr("Linked meal needs to review")).font(.headline)
            if needs.isEmpty { Text(pTr("No linked meal needs are saved for this line. Meal suitability remains unresolved.")) }
            ForEach(needs) { need in
                Text("\(need.name): \(pQuantity(need.amount))")
                if need.priority == .protected { Text(pTr("Protected")) }
                if let detail = journey.needDetails.first(where: { $0.id == need.id }) {
                    Text(detail.mealName)
                    if !detail.exclusions.isEmpty { Text("\(pTr("Keep these exclusions")): \(detail.exclusions.joined(separator: ", "))") }
                }
            }
            Text(pTr("Saving or copying an offer does not confirm retailer acceptance, received food, or usable meal portions."))
        }
    }
}

func pickupOfferPriceText(_ price: CostEvidence) -> String {
    switch price {
    case let .exact(value): return pMoney(value)
    case let .bounded(lower, upper, reason): return "\(pMoney(lower)) – \(pMoney(upper)) · \(reason)"
    case let .unknown(reason): return "\(pTr("Unresolved")) · \(reason)"
    }
}
func pickupOfferAssessmentText(_ offer: PickupOffer) -> String {
    guard let assessment = try? PickupOfferReview.assess(price: offer.price, ceiling: offer.ceiling) else { return pTr("Price evidence is invalid. Reopen and review this offer.") }
    switch assessment {
    case .within: return pTr("Offered price is within this offer-specific ceiling.")
    case .over: return pTr("Offered price exceeds this offer-specific ceiling.")
    case .conditional: return pTr("The offered price range crosses this ceiling. The result is conditional.")
    case .unknown: return pTr("Offered price is unresolved; this ceiling cannot be checked.")
    case .noCeiling: return pTr("No offer-specific ceiling is saved; affordability remains unresolved.")
    }
}
func pickupOfferCutoffText(_ offer: PickupOffer) -> String {
    let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
    formatter.timeZone = TimeZone(identifier: offer.deadline.timeZoneID)
    return formatter.string(from: offer.deadline.cutoff)
}
/// Deliberately excludes private meal names, exclusions, household preferences,
/// whole-checkout caps, and funds. Copy is not a retailer response or fill event.
func pickupOfferRetailerNote(_ offer: PickupOffer) -> String {
    let maximum = offer.evaluation.map { $0.effectiveNoteCeiling } ?? offer.ceiling
    return "\(offer.replacement)\n\(pTr("Required usable")): \(pQuantity(offer.required))\n\(pTr("Maximum price")): \(maximum.map(pMoney) ?? pTr("Unresolved"))\n\(pTr("Cutoff")): \(pickupOfferCutoffText(offer)) · \(offer.deadline.timeZoneID)\n\(pTr("If short")): \(offer.fallback)"
}
