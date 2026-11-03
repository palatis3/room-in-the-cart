import Foundation

public struct DinnerCommitment: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case dinner, lunch, side, staple }
    public let id: UUID
    public let name: String
    public let kind: Kind
    public let portions: Rational
    public let protected: Bool
    public let day: MealDay?
    public init(id: UUID = UUID(), name: String, kind: Kind, portions: Rational, protected: Bool = false, day: MealDay? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.portions = portions; self.protected = protected; self.day = day
    }
}
public struct DinnerCommitmentSet: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let commitments: [DinnerCommitment]
    public init(id: UUID = UUID(), commitments: [DinnerCommitment]) { self.id = id; self.commitments = commitments }
    public func validate() throws {
        guard !commitments.isEmpty, commitments.count <= 500 else { throw DinnerPlanningError.invalid("commitments") }
        try dinnerUnique(commitments.map(\.id))
        for commitment in commitments {
            try dinnerText(commitment.name); try commitment.day?.validate()
            guard commitment.portions > .zero else { throw DinnerPlanningError.invalid("portions") }
        }
    }
}
public struct DinnerDemand: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let commitmentID: UUID
    /// Assigned only by an explicit food-to-need match, never name inference.
    public let foodID: UUID
    public let name: String
    public let quantity: Quantity?
    public let exclusions: [String]
    public let acceptedDinnerID: UUID?
    /// Explicit reviewed match to the accepted recipe ingredient; never inferred from its name.
    public let ingredientID: UUID?
    public init(id: UUID = UUID(), commitmentID: UUID, foodID: UUID, name: String, quantity: Quantity?, exclusions: [String] = [], acceptedDinnerID: UUID? = nil, ingredientID: UUID? = nil) {
        self.acceptedDinnerID = acceptedDinnerID; self.ingredientID = ingredientID
        self.id = id; self.commitmentID = commitmentID; self.foodID = foodID; self.name = name; self.quantity = quantity; self.exclusions = exclusions
    }
}
public enum DinnerAvailability: Codable, Equatable, Sendable {
    case confirmed(maximumPacks: Int64?)
    case unknown
    case unavailable
}
public struct DinnerPackSelection: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let foodID: UUID
    public let offer: PackOffer
    public let availability: DinnerAvailability
    public let thresholdEligible: Bool
    public init(id: UUID = UUID(), foodID: UUID, offer: PackOffer, availability: DinnerAvailability, thresholdEligible: Bool = true) {
        self.id = id; self.foodID = foodID; self.offer = offer; self.availability = availability; self.thresholdEligible = thresholdEligible
    }
}
public struct DinnerPreparation: Codable, Equatable, Sendable {
    public let handsOnMinutes: Int?
    /// Explicit remaining elapsed duration after reviewed completed steps.
    public let remainingLeadMinutes: Int?
    public let availableMinutes: Int?
    public init(handsOnMinutes: Int?, remainingLeadMinutes: Int?, availableMinutes: Int?) {
        self.handsOnMinutes = handsOnMinutes; self.remainingLeadMinutes = remainingLeadMinutes; self.availableMinutes = availableMinutes
    }
    public var isFeasible: Bool? {
        guard let hands = handsOnMinutes, let lead = remainingLeadMinutes, let available = availableMinutes else { return nil }
        return hands <= available && lead <= available
    }
    func validate() throws {
        for value in [handsOnMinutes, remainingLeadMinutes, availableMinutes].compactMap({ $0 }) {
            guard (0...525_600).contains(value) else { throw DinnerPlanningError.invalid("preparation") }
        }
    }
}
public struct DinnerScenario: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let commitments: DinnerCommitmentSet
    public let acceptedDinnerIDs: [UUID]
    public let demands: [DinnerDemand]
    public let stock: [ConfirmedStockLot]
    /// Include commitments outside this comparison once so their stock is never stolen.
    public let otherReservations: [StockNeed]
    public let packs: [DinnerPackSelection]
    public let baselineLines: [CheckoutLine]
    public let baselineComplete: Bool
    public let fees: [CheckoutFee]
    public let discounts: [CheckoutDiscount]
    public let tax: CostEvidence
    public let deposits: CostEvidence
    public let context: CheckoutContext
    public let scope: CheckoutScope
    public let preparation: DinnerPreparation
    public let acceptedChanges: Int
    public init(id: UUID = UUID(), commitments: DinnerCommitmentSet, acceptedDinnerIDs: [UUID], demands: [DinnerDemand],
        stock: [ConfirmedStockLot] = [], otherReservations: [StockNeed] = [], packs: [DinnerPackSelection],
        baselineLines: [CheckoutLine] = [], baselineComplete: Bool, fees: [CheckoutFee], discounts: [CheckoutDiscount] = [],
        tax: CostEvidence, deposits: CostEvidence, context: CheckoutContext, scope: CheckoutScope = .wholeCheckout,
        preparation: DinnerPreparation, acceptedChanges: Int = 0) {
        self.id = id; self.commitments = commitments; self.acceptedDinnerIDs = acceptedDinnerIDs; self.demands = demands
        self.stock = stock; self.otherReservations = otherReservations; self.packs = packs; self.baselineLines = baselineLines
        self.baselineComplete = baselineComplete; self.fees = fees; self.discounts = discounts; self.tax = tax
        self.deposits = deposits; self.context = context; self.scope = scope; self.preparation = preparation; self.acceptedChanges = acceptedChanges
    }
}
public struct DinnerPackResult: Codable, Equatable, Sendable {
    public let foodID: UUID
    public let selectionID: UUID?
    public let result: OfferResult?
    public let availabilityConfirmed: Bool
}
public struct DinnerScenarioResult: Equatable, Sendable {
    public let scenarioID: UUID
    public let quote: CheckoutQuote
    public let checkout: CheckoutResult
    public let stockAllocation: StockAllocationResult
    public let packs: [DinnerPackResult]
    public let foodCoverageComplete: Bool
    public let timingFeasible: Bool?
    public let issues: [String]
    public var feasible: Bool { foodCoverageComplete && timingFeasible == true }
}
public struct DinnerPairingResult: Equatable, Sendable {
    public enum Status: String, Sendable { case proposals, noNewPairing, noFeasiblePair, searchIncomplete }
    public let status: Status
    public let baseline: DinnerScenarioResult
    public let alternatives: [DinnerScenarioResult]
    public let preferredScenarioIDs: [UUID]
    public let untestedCount: Int
}
public struct DinnerRecoveryResult: Equatable, Sendable {
    public let alternatives: [DinnerScenarioResult]
    public let preferredScenarioIDs: [UUID]
    public let needsExtraTripConfirmation: Bool
    public let unresolved: Bool
}

public enum DinnerScenarioEngine {
    public static func evaluate(_ scenario: DinnerScenario, acceptedDinners: [AcceptedDinner], cap: CheckoutCap? = nil) throws -> DinnerScenarioResult {
        try scenario.commitments.validate(); try scenario.preparation.validate()
        guard scenario.context.commitmentsID == scenario.commitments.id, scenario.acceptedChanges >= 0,
              scenario.demands.count <= 2_000, scenario.packs.count <= 1_000, scenario.stock.count <= 2_000,
              scenario.otherReservations.count <= 2_000 else { throw DinnerPlanningError.invalid("scenario") }
        try dinnerUnique(scenario.demands.map(\.id)); try dinnerUnique(scenario.packs.map(\.id)); try dinnerUnique(scenario.packs.map(\.foodID))
        try dinnerUnique(scenario.acceptedDinnerIDs)
        for pack in scenario.packs {
            try pack.offer.usableQuantity?.validate(); try pack.offer.confirmedConversion?.validate()
            guard !pack.offer.id.isEmpty, pack.offer.id.utf8.count <= 128, pack.offer.label.utf8.count <= 512,
                  pack.offer.price.map({ $0.minorUnits >= 0 }) ?? true else { throw DinnerPlanningError.invalid("packEvidence") }
            if case .confirmed(let limit) = pack.availability, let limit, limit < 0 { throw DinnerPlanningError.invalid("availability") }
        }
        for id in scenario.acceptedDinnerIDs {
            guard let dinner = acceptedDinners.first(where: { $0.id == id }) else { throw DinnerPlanningError.notFound(id) }
            try dinner.template.validate()
        }
        // Automatic scenarios must contain an approved meal; manually entered staples can
        // still be priced through CheckoutEngine directly.
        if scenario.commitments.commitments.contains(where: { $0.kind == .dinner }) && scenario.acceptedDinnerIDs.isEmpty {
            throw DinnerPlanningError.reviewRequired("acceptedDinner")
        }
        var issues: [String] = []
        let commitmentIDs = Set(scenario.commitments.commitments.map(\.id))
        for demand in scenario.demands {
            try dinnerText(demand.name); try demand.quantity?.validate()
            guard commitmentIDs.contains(demand.commitmentID) else { throw DinnerPlanningError.invalid("demandCommitment") }
            // Reuse ledger hard-exclusion validation, rather than a second name-matching policy.
            let isDinner = scenario.commitments.commitments.first(where: { $0.id == demand.commitmentID })?.kind == .dinner
            let sourceID = demand.acceptedDinnerID ?? (isDinner && scenario.acceptedDinnerIDs.count == 1 ? scenario.acceptedDinnerIDs.first : nil)
            let source = acceptedDinners.first { $0.id == sourceID }
            if let sourceID, !scenario.acceptedDinnerIDs.contains(sourceID) { throw DinnerPlanningError.invalid("demandAcceptedDinner") }
            if scenario.commitments.commitments.first(where: { $0.id == demand.commitmentID })?.kind == .dinner && source == nil {
                throw DinnerPlanningError.reviewRequired("demandMealSource")
            }
            let check = MealTemplate(title: "Reviewed ingredient", ingredients: [MealIngredient(name: demand.name, quantity: demand.quantity, exclusions: demand.exclusions)], exclusions: (source?.template.exclusions ?? []) + (source?.template.ingredients.flatMap(\.exclusions) ?? []))
            try check.validate()
        }
        // A single known demand cannot prove an entire accepted recipe is covered.
        // Legacy unbound scenarios remain readable, but need review before claiming
        // complete food or checkout coverage. Names are not ingredient identities.
        var demandProofComplete = true
        var representedDinners = Set<UUID>()
        for commitment in scenario.commitments.commitments {
            let demands = scenario.demands.filter { $0.commitmentID == commitment.id }
            let grouped = Dictionary(grouping: demands) { demand -> UUID? in
                demand.acceptedDinnerID ?? (commitment.kind == .dinner && scenario.acceptedDinnerIDs.count == 1 ? scenario.acceptedDinnerIDs.first : nil)
            }
            for (sourceID, mealDemands) in grouped {
                guard let sourceID else { continue }
                guard let dinner = acceptedDinners.first(where: { $0.id == sourceID }) else { throw DinnerPlanningError.notFound(sourceID) }
                representedDinners.insert(sourceID)
                let required = Set(dinner.template.ingredients.map(\.id))
                let supplied = Set(mealDemands.compactMap(\.ingredientID))
                guard supplied.isSubset(of: required) else { throw DinnerPlanningError.invalid("demandIngredient") }
                if required.isEmpty || required != supplied || mealDemands.contains(where: { $0.ingredientID == nil }) {
                    demandProofComplete = false
                    issues.append("Review all required ingredients for \(commitment.name)")
                }
                for ingredient in dinner.template.ingredients {
                    guard let recipeQuantity = ingredient.quantity else {
                        demandProofComplete = false
                        issues.append("Review unknown recipe quantity for \(ingredient.name)"); continue
                    }
                    let expected = try recipeQuantity.amount.multiplied(by: commitment.portions.divided(by: dinner.template.servings))
                    var entered = Rational.zero
                    var complete = true
                    for demand in mealDemands where demand.ingredientID == ingredient.id {
                        guard let quantity = demand.quantity,
                              let normalized = try quantity.converted(to: recipeQuantity.unit, using: recipeQuantity.confirmedConversion) else {
                            complete = false; continue
                        }
                        entered = try entered.adding(normalized)
                    }
                    if !complete || entered < expected {
                        demandProofComplete = false
                        issues.append("Review required recipe amount and servings for \(ingredient.name)")
                    }
                }
            }
        }
        if !Set(scenario.acceptedDinnerIDs).isSubset(of: representedDinners) {
            demandProofComplete = false
            issues.append("Review demand for every accepted dinner")
        }
        for commitment in scenario.commitments.commitments {
            let demands = scenario.demands.filter { $0.commitmentID == commitment.id }
            if demands.isEmpty { issues.append("Missing demand for \(commitment.name)") }
            else if demands.allSatisfy({ $0.quantity?.amount == .zero }) { issues.append("Review zero food demand for \(commitment.name)") }
        }
        for reservation in scenario.otherReservations where reservation.priority != .protected {
            throw DinnerPlanningError.invalid("outsideReservationPriority")
        }
        let knownNeeds = scenario.demands.compactMap { demand -> StockNeed? in
            guard let quantity = demand.quantity else { return nil }
            let protected = scenario.commitments.commitments.first(where: { $0.id == demand.commitmentID })!.protected
            return StockNeed(id: demand.id, foodID: demand.foodID, name: demand.name, amount: quantity, priority: protected ? .protected : .required)
        }
        if knownNeeds.count != scenario.demands.count { issues.append("Ingredient quantity is unknown") }
        let stock = try ConfirmedStockAllocator.allocate(lots: scenario.stock, needs: scenario.otherReservations + knownNeeds)
        // An unquantified demand for a food prevents using its stock for a competing known
        // demand; do not silently consume a protected amount whose size is unknown.
        let unknownFoods = Set(scenario.demands.filter { $0.quantity == nil }.map(\.foodID))
        var lines = scenario.baselineLines, packResults: [DinnerPackResult] = []
        var foodIDs: [UUID] = []
        for demand in scenario.demands where !foodIDs.contains(demand.foodID) { foodIDs.append(demand.foodID) }
        for foodID in foodIDs {
            let demands = scenario.demands.filter { $0.foodID == foodID }
            let selection = scenario.packs.first { $0.foodID == foodID }
            guard !unknownFoods.contains(foodID), let unit = demands.first?.quantity?.unit else {
                packResults.append(.init(foodID: foodID, selectionID: selection?.id, result: nil, availabilityConfirmed: false)); continue
            }
            var remaining = Rational.zero, protected = Rational.zero, convertible = true
            for demand in demands {
                guard let coverage = stock.demands.first(where: { $0.id == demand.id }), let shortfall = coverage.shortfall,
                      coverage.issues.isEmpty,
                      let normalized = try Quantity(amount: shortfall, unit: coverage.unit, originalLiteral: demand.name).converted(to: unit) else {
                    convertible = false; break
                }
                remaining = try remaining.adding(normalized)
                if scenario.commitments.commitments.first(where: { $0.id == demand.commitmentID })!.protected { protected = try protected.adding(normalized) }
            }
            guard convertible else {
                issues.append("Review usable conversion for \(demands[0].name)")
                packResults.append(.init(foodID: foodID, selectionID: selection?.id, result: nil, availabilityConfirmed: false)); continue
            }
            if remaining == .zero {
                // All need is met by confirmed stock, with no new pack or availability assumption.
                packResults.append(.init(foodID: foodID, selectionID: selection?.id, result: nil, availabilityConfirmed: true)); continue
            }
            guard let selection else {
                issues.append("Choose a usable pack for \(demands[0].name)")
                packResults.append(.init(foodID: foodID, selectionID: nil, result: nil, availabilityConfirmed: false)); continue
            }
            if case .confirmed(let maximum) = selection.availability, let maximum, maximum < 0 { throw DinnerPlanningError.invalid("availability") }
            let offer = selection.offer
            // PackComparison exposes a two-offer calculator. Supply the same evidence under
            // distinct calculation IDs and consume A; this reuses its whole-pack/conversion math.
            let twin = PackOffer(id: offer.id == "planning-alternate" ? "planning-alternate-2" : "planning-alternate", label: offer.label,
                usableQuantity: offer.usableQuantity, price: offer.price, confirmedConversion: offer.confirmedConversion)
            let result = try PackComparison.evaluate(ComparisonRequest(itemName: demands[0].name,
                needed: Quantity(amount: remaining, unit: unit, originalLiteral: demands[0].name),
                protectedAmount: Quantity(amount: protected, unit: unit, originalLiteral: "Protected"), offerA: offer, offerB: twin)).offerA
            let available: Bool
            switch selection.availability {
            case .confirmed(let maximum): available = result.packsToBuy.map { count in maximum.map { $0 >= count } ?? true } ?? false
            case .unknown, .unavailable: available = false
            }
            if !available { issues.append("Required pack availability is unconfirmed or insufficient for \(demands[0].name)") }
            for issue in result.issues { issues.append("\(demands[0].name): \(issue.rawValue)") }
            lines.append(CheckoutLine(id: selection.id, name: demands[0].name,
                cost: result.totalCost.map(CostEvidence.exact) ?? .unknown(reason: "Missing price or usable pack quantity"), thresholdEligible: selection.thresholdEligible))
            packResults.append(.init(foodID: foodID, selectionID: selection.id, result: result, availabilityConfirmed: available))
        }
        let foodComplete = issues.filter { !$0.contains("priceUnknown") }.isEmpty
            && packResults.allSatisfy { $0.availabilityConfirmed && ($0.result?.remainingNeed == nil || $0.result?.remainingNeed == .zero) }
        // Missing selections must not make an incomplete basket look like a complete zero-cost line set.
        let quoteComplete = scenario.baselineComplete && demandProofComplete && unknownFoods.isEmpty
            && Set(scenario.demands.map(\.commitmentID)) == commitmentIDs
            && packResults.allSatisfy { $0.result != nil || $0.availabilityConfirmed }
        let quote = CheckoutQuote(scope: scenario.scope, context: scenario.context,
            pricing: .components(lines: lines, lineSetComplete: quoteComplete, fees: scenario.fees,
                discounts: scenario.discounts, tax: scenario.tax, deposits: scenario.deposits))
        let checkout = try CheckoutEngine.evaluate(quote, cap: cap)
        if scenario.preparation.isFeasible == nil { issues.append("Preparation time is unconfirmed") }
        else if scenario.preparation.isFeasible == false { issues.append("Known preparation cannot fit the available time") }
        return DinnerScenarioResult(scenarioID: scenario.id, quote: quote, checkout: checkout, stockAllocation: stock,
            packs: packResults, foodCoverageComplete: foodComplete, timingFeasible: scenario.preparation.isFeasible, issues: issues)
    }
    public static func pair(current: DinnerScenario, alternatives: [DinnerScenario], selectedAcceptedDinnerIDs: Set<UUID>,
        state: DinnerPlanningState, cap: CheckoutCap?, access: DinnerAccessContext, at now: Date, isolated: Bool = false, searchLimit: Int = 32) throws -> DinnerPairingResult {
        try access.validate(shopID: access.shopID, at: now, budget: true)
        guard access.hasPaidTools || isolated else { throw DinnerPlanningError.paidAccessRequired }
        guard (1...128).contains(searchLimit), alternatives.count <= 500 else { throw DinnerPlanningError.invalid("searchLimit") }
        let baseline = try evaluate(current, acceptedDinners: state.acceptedDinners, cap: cap)
        var compared: [(DinnerScenario, DinnerScenarioResult)] = []
        let alreadySelected = selectedAcceptedDinnerIDs.union(current.acceptedDinnerIDs)
        var newChoices = 0, examined = 0
        for scenario in alternatives.prefix(searchLimit) {
            examined += 1
            guard scenario.commitments == current.commitments, scenario.scope == current.scope else { throw CheckoutError.incomparableBasis }
            guard scenario.baselineLines.sorted(by: { $0.id.uuidString < $1.id.uuidString }) == current.baselineLines.sorted(by: { $0.id.uuidString < $1.id.uuidString }),
                  scenario.baselineComplete == current.baselineComplete else { throw DinnerPlanningError.reviewRequired("changedOriginalItems") }
            if Set(scenario.acceptedDinnerIDs).isSubset(of: alreadySelected) { continue }
            newChoices += 1
            let result = try evaluate(scenario, acceptedDinners: state.acceptedDinners, cap: cap)
            _ = try CheckoutEngine.compare(before: baseline.quote, after: result.quote, cap: cap)
            compared.append((scenario, result))
        }
        let viable = compared.filter { $0.1.feasible }
        let preferred = rank(viable, cap: cap)
        return DinnerPairingResult(status: newChoices == 0 ? (alternatives.count > examined ? .searchIncomplete : .noNewPairing) : (viable.isEmpty ? .noFeasiblePair : .proposals), baseline: baseline,
            alternatives: compared.map { $0.1 }, preferredScenarioIDs: preferred, untestedCount: alternatives.count - examined)
    }
    public static func recover(alternatives: [DinnerScenario], state: DinnerPlanningState, cap: CheckoutCap?,
        access: DinnerAccessContext, at now: Date, extraTripAccepted: Bool = false) throws -> DinnerRecoveryResult {
        try access.validate(shopID: access.shopID, at: now, budget: true)
        guard access.hasPaidTools else { throw DinnerPlanningError.paidAccessRequired }
        guard alternatives.count <= 128 else { throw DinnerPlanningError.invalid("recoveryLimit") }
        if let first = alternatives.first {
            guard alternatives.allSatisfy({ $0.commitments == first.commitments && $0.scope == first.scope }) else { throw CheckoutError.incomparableBasis }
        }
        var evaluated: [(DinnerScenario, DinnerScenarioResult)] = []
        for alternative in alternatives {
            guard !alternative.acceptedDinnerIDs.isEmpty,
                  alternative.acceptedDinnerIDs.allSatisfy({ id in state.acceptedDinners.contains(where: { $0.id == id && $0.acceptedFallback }) }) else { continue }
            evaluated.append((alternative, try evaluate(alternative, acceptedDinners: state.acceptedDinners, cap: cap)))
        }
        let feasible = evaluated.filter { pair in
            guard pair.1.feasible else { return false }
            if cap == nil { return true }
            if case .within = pair.1.checkout.cap { return true }
            return false
        }
        // Prefer food already home. Then fewest purchased packs, then exact complete checkout.
        let counted = try feasible.map { pair -> (DinnerScenario, DinnerScenarioResult, Int64) in
            let count = try pair.1.packs.compactMap { $0.result?.packsToBuy }.reduce(Int64(0)) { try checkedAdd($0, $1) }
            return (pair.0, pair.1, count)
        }
        let sorted = counted.sorted {
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            return ($0.1.checkout.total.exact?.minorUnits ?? Int64.max) < ($1.1.checkout.total.exact?.minorUnits ?? Int64.max)
        }
        let best = sorted.first
        let bestCount = best?.2
        let preferred = sorted.filter { pair in
            pair.2 == bestCount && pair.1.checkout.total.exact == best?.1.checkout.total.exact
        }.map { $0.0.id }
        return DinnerRecoveryResult(alternatives: evaluated.map { $0.1 }, preferredScenarioIDs: preferred,
            needsExtraTripConfirmation: (bestCount ?? 0) > 0 && !extraTripAccepted, unresolved: best == nil || best?.1.checkout.total.exact == nil)
    }
    private static func rank(_ options: [(DinnerScenario, DinnerScenarioResult)], cap: CheckoutCap?) -> [UUID] {
        let exact = options.filter { option in
            guard option.1.checkout.total.exact != nil else { return false }
            if cap == nil { return true }
            if case .within = option.1.checkout.cap { return true }
            return false
        }
        let ordered = exact.sorted {
            if $0.0.acceptedChanges != $1.0.acceptedChanges { return $0.0.acceptedChanges < $1.0.acceptedChanges }
            return $0.1.checkout.total.exact! < $1.1.checkout.total.exact!
        }
        guard let best = ordered.first else { return [] }
        return ordered.filter { $0.0.acceptedChanges == best.0.acceptedChanges && $0.1.checkout.total.exact == best.1.checkout.total.exact }.map { $0.0.id }
    }
}

public struct StoreTripEvidence: Codable, Equatable, Sendable {
    public let incrementalCash: CostEvidence
    public let extraMinutes: Int?
    public let tripAlreadyPlanned: Bool
    public init(incrementalCash: CostEvidence, extraMinutes: Int?, tripAlreadyPlanned: Bool) {
        self.incrementalCash = incrementalCash; self.extraMinutes = extraMinutes; self.tripAlreadyPlanned = tripAlreadyPlanned
    }
}
public struct StoreQuoteOption: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let label: String
    public let commitments: DinnerCommitmentSet
    public let quote: CheckoutQuote
    public let available: Bool?
    public let quantitiesMatched: Bool
    public let singleStore: Bool
    public let trip: StoreTripEvidence
    public let cap: CheckoutCap?
    public let adoptionBasis: ShopBasis?
    public init(id: UUID = UUID(), label: String, commitments: DinnerCommitmentSet, quote: CheckoutQuote,
        available: Bool?, quantitiesMatched: Bool, singleStore: Bool = true, trip: StoreTripEvidence, cap: CheckoutCap? = nil, adoptionBasis: ShopBasis? = nil) {
        self.id = id; self.label = label; self.commitments = commitments; self.quote = quote; self.available = available
        self.quantitiesMatched = quantitiesMatched; self.singleStore = singleStore; self.trip = trip; self.cap = cap; self.adoptionBasis = adoptionBasis
    }
}
public struct TwoStoreQuotePair: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let shopID: UUID
    public let baseRevisionID: UUID
    public let basisRevision: Int
    public let first: StoreQuoteOption
    public let second: StoreQuoteOption
    public init(id: UUID = UUID(), shopID: UUID, baseRevisionID: UUID, basisRevision: Int, first: StoreQuoteOption, second: StoreQuoteOption) {
        self.id = id; self.shopID = shopID; self.baseRevisionID = baseRevisionID; self.basisRevision = basisRevision
        self.first = first; self.second = second
    }
    public func validate() throws {
        guard first.id != second.id, basisRevision >= 0 else { throw DinnerPlanningError.invalid("quotePair") }
        for option in [first, second] {
            try dinnerText(option.label); try option.commitments.validate()
            guard option.quote.context.commitmentsID == option.commitments.id,
                  option.trip.extraMinutes.map({ (0...525_600).contains($0) }) ?? true else { throw DinnerPlanningError.invalid("quoteOption") }
            try option.adoptionBasis?.validate()
            if let basis = option.adoptionBasis {
                guard basis.branch == option.quote.context.branchID, basis.mode.rawValue == option.quote.context.mode.rawValue else { throw DinnerPlanningError.invalid("quoteAdoptionBasis") }
            }
            _ = try CheckoutEngine.evaluate(option.quote, cap: option.cap)
            _ = try TwoStoreQuoteEngine.tripTotal(option)
        }
    }
}
public struct StoreQuoteResult: Equatable, Sendable {
    public let optionID: UUID
    public let checkout: CheckoutResult
    public let tripInclusive: CheckoutResult
    public let extraMinutes: Int?
    public let coverageConfirmed: Bool
}
public struct TwoStoreQuoteResult: Equatable, Sendable {
    public let first: StoreQuoteResult
    public let second: StoreQuoteResult
    public let comparable: Bool
    public let checkoutChange: Money?
    public let tripCashChange: Money?
    public let extraMinutesChange: Int?
    public let preferredByTotalCash: UUID?
    /// Maximum B incremental trip cash to equal A's known total, not a saving claim.
    public let secondTripCashBreakEven: Money?
    public let issues: [String]
}
public enum TwoStoreQuoteEngine {
    static func tripTotal(_ option: StoreQuoteOption) throws -> CheckoutResult {
        let checkout = try CheckoutEngine.evaluate(option.quote).total
        let checkoutEvidence: CostEvidence
        if let exact = checkout.exact { checkoutEvidence = .exact(exact) }
        else if let upper = checkout.upperBound { checkoutEvidence = .bounded(lower: checkout.lowerBound, upper: upper, reason: "Checkout is bounded") }
        else {
            // Evaluate component pricing again with a separate incremental trip charge, so
            // known lower bounds survive and unknown totals remain unresolved.
            switch option.quote.pricing {
            case .inclusiveTotal(let evidence):
                return try CheckoutEngine.evaluate(CheckoutQuote(scope: option.quote.scope, context: option.quote.context,
                    pricing: .components(lines: [CheckoutLine(id: option.id, name: "Grocery checkout", cost: evidence)],
                        lineSetComplete: true, fees: [CheckoutFee(id: "incrementalTripCash", rule: .fixed(option.trip.incrementalCash))],
                        discounts: [], tax: .exact(.zero), deposits: .exact(.zero))))
            case .components(let lines, let complete, let fees, let discounts, let tax, let deposits):
                guard !fees.contains(where: { $0.id == "incrementalTripCash" }) else { throw DinnerPlanningError.invalid("reservedFeeID") }
                return try CheckoutEngine.evaluate(CheckoutQuote(scope: option.quote.scope, context: option.quote.context,
                    pricing: .components(lines: lines, lineSetComplete: complete,
                        fees: fees + [CheckoutFee(id: "incrementalTripCash", rule: .fixed(option.trip.incrementalCash))],
                        discounts: discounts, tax: tax, deposits: deposits)))
            }
        }
        return try CheckoutEngine.evaluate(CheckoutQuote(scope: option.quote.scope, context: option.quote.context,
            pricing: .components(lines: [CheckoutLine(id: option.id, name: "Grocery checkout", cost: checkoutEvidence)],
                lineSetComplete: true, fees: [CheckoutFee(id: "incrementalTripCash", rule: .fixed(option.trip.incrementalCash))],
                discounts: [], tax: .exact(.zero), deposits: .exact(.zero))))
    }
    public static func compare(_ pair: TwoStoreQuotePair, access: DinnerAccessContext, at now: Date) throws -> TwoStoreQuoteResult {
        try access.validate(shopID: pair.shopID, at: now, budget: true); try pair.validate()
        let a = pair.first, b = pair.second
        let comparable = a.commitments == b.commitments && a.quote.scope == b.quote.scope
            && a.quantitiesMatched && b.quantitiesMatched && a.singleStore && b.singleStore
        let ar = try CheckoutEngine.evaluate(a.quote, cap: a.cap), br = try CheckoutEngine.evaluate(b.quote, cap: b.cap)
        let at = try tripTotal(a), bt = try tripTotal(b)
        let coverage = a.available == true && b.available == true
        let checkoutDelta = try comparable ? ar.total.exact.flatMap { av in try br.total.exact.map { try $0.subtracting(av) } } : nil
        let tripDelta = try comparable ? at.total.exact.flatMap { av in try bt.total.exact.map { try $0.subtracting(av) } } : nil
        let minutes = comparable ? a.trip.extraMinutes.flatMap { av in b.trip.extraMinutes.map { $0 - av } } : nil
        let preferred = comparable && coverage ? tripDelta.flatMap { $0.minorUnits == 0 ? nil : ($0.minorUnits < 0 ? b.id : a.id) } : nil
        let breakEven: Money?
        if comparable, coverage, case .unknown = b.trip.incrementalCash, let totalA = at.total.exact, let checkoutB = br.total.exact {
            let difference = try totalA.subtracting(checkoutB); breakEven = difference.minorUnits >= 0 ? difference : nil
        } else { breakEven = nil }
        var issues: [String] = []
        if !comparable { issues.append("Compare complete single-store plans for the same commitments and scope") }
        if !coverage { issues.append("Required product availability is unknown or unavailable") }
        if ar.total.exact == nil || br.total.exact == nil { issues.append("Checkout terms are incomplete") }
        if at.total.exact == nil || bt.total.exact == nil { issues.append("Total trip cash is unresolved") }
        return TwoStoreQuoteResult(first: .init(optionID: a.id, checkout: ar, tripInclusive: at, extraMinutes: a.trip.extraMinutes, coverageConfirmed: a.available == true),
            second: .init(optionID: b.id, checkout: br, tripInclusive: bt, extraMinutes: b.trip.extraMinutes, coverageConfirmed: b.available == true),
            comparable: comparable, checkoutChange: checkoutDelta, tripCashChange: tripDelta, extraMinutesChange: minutes,
            preferredByTotalCash: preferred, secondTripCashBreakEven: breakEven, issues: issues)
    }
    public static func previewAdoption(_ pair: TwoStoreQuotePair, optionID: UUID, basis: ShopBasis,
        ledger: ShoppingLedger, state: DinnerPlanningState, access: DinnerAccessContext, phase: BasketPhase, at now: Date) throws -> DinnerPreview {
        try access.validate(shopID: ledger.id, at: now, budget: true)
        guard pair.shopID == ledger.id, pair.baseRevisionID == ledger.revisionID, pair.basisRevision == ledger.basisRevision else { throw DinnerPlanningError.stalePreview }
        guard phase == .draft else { throw DinnerPlanningError.lockedBasket }
        let result = try compare(pair, access: access, at: now)
        guard result.comparable, let option = [pair.first, pair.second].first(where: { $0.id == optionID }), option.available == true else { throw DinnerPlanningError.reviewRequired("quoteCoverage") }
        guard let reviewedBasis = option.adoptionBasis, reviewedBasis == basis else { throw DinnerPlanningError.reviewRequired("adoptionBasis") }
        guard state.quotePairs.contains(pair) else { throw DinnerPlanningError.reviewRequired("saveQuoteProof") }
        // Source proof stays in quotePairs. The basis change clears active store-specific evidence.
        var newBasis = basis; newBasis.retailerPreview = nil
        return try DinnerPlanningEngine.preview(changes: [.adoptBasis(newBasis)], tool: .quoteAdoption, ledger: ledger,
            state: state, access: access, phase: phase, at: now, quoteSelection: .init(pairID: pair.id, optionID: option.id))
    }
}
