import Foundation
import CoreDomain

enum PickupCheckoutDraftError: Error, Equatable {
    case staleSource, missingContext, reviewReplacement
}

/// The retailer facts that determine whether prices can describe this checkout.
struct PickupPricingTerms: Codable, Equatable {
    let store: String, branch: String, slot: String
    let mode: ShoppingMode
    let scope: CheckoutScope

    static func from(_ context: CheckoutContext, scope: CheckoutScope) -> Self {
        Self(store: context.storeID, branch: context.branchID, slot: context.slot, mode: context.mode, scope: scope)
    }

    static func scope(cap: CheckoutCap?, basis: ShopBasis?) -> CheckoutScope {
        if let cap { return cap.scope }
        switch basis?.capScope {
        case .dinnersOnly: return .dinner
        case .selectedItems: return .item
        default: return .wholeCheckout
        }
    }
}

/// The form is an edit of saved evidence, not a reconstruction from its result.
/// Unchanged fields keep their original evidence and the metadata they do not edit.
struct PickupCheckoutDraft {
    var store = "" { willSet { pinEditedPricing() } }
    var branch = "" { willSet { pinEditedPricing() } }
    var slot = "" { willSet { pinEditedPricing() } }
    var source = ""
    var observed = Date()
    var mode: ShoppingMode = .pickup { willSet { pinEditedPricing() } }
    var scope: CheckoutScope = .wholeCheckout { willSet { pinEditedPricing() } }
    var capScope: CheckoutScope = .wholeCheckout
    var cap = ""
    var inclusive = false
    var total = ""
    var prices: [UUID: String] = [:]
    var fee = "", threshold = "", discount = "", tax = "", deposits = ""
    var complete = true
    private var sourceWorkspaceID: UUID?
    private(set) var journeyID: UUID?
    private(set) var basketRevisionID: UUID?
    private(set) var replacingPricing = false
    private(set) var hasSavedPricing = false
    private(set) var originalPricing: CheckoutPricing?
    var reviewedQuote: CheckoutQuote? { hasSavedPricing ? originalQuote : nil }
    private var originalQuote: CheckoutQuote?
    private var earlierQuoteRevision: Int64?
    private var ledgerSourceRevisionID: UUID?
    private var originalQuotedRevisionID: UUID?
    private var originalContext: CheckoutContext?
    private(set) var originalCap: CheckoutCap?
    private var basketLines: [BasketLine] = []
    private var initialInput: PricingInput?
    private var initialDetails: DetailsInput?
    private var supportsEditing = true

    private struct PricingInput: Equatable {
        let inclusive: Bool
        let total: String
        let prices: [UUID: String]
        let fee: String, threshold: String, discount: String, tax: String, deposits: String
        let complete: Bool
    }
    private var pricingInput: PricingInput {
        .init(inclusive: inclusive, total: total, prices: prices, fee: fee, threshold: threshold,
              discount: discount, tax: tax, deposits: deposits, complete: complete)
    }
    private struct DetailsInput: Equatable {
        let store: String, branch: String, slot: String, source: String
        let observed: Date
        let mode: ShoppingMode
        let scope: CheckoutScope, capScope: CheckoutScope
        let cap: String
    }
    private var detailsInput: DetailsInput {
        .init(store: store, branch: branch, slot: slot, source: source, observed: observed,
              mode: mode, scope: scope, capScope: capScope, cap: cap)
    }
    private var terms: PickupPricingTerms { .init(store: store, branch: branch, slot: slot, mode: mode, scope: scope) }
    private var originalTerms: PickupPricingTerms?
    private var pricingTerms: PickupPricingTerms?
    private mutating func pinEditedPricing() {
        if pricingTerms == nil, let initialInput, pricingInput != initialInput { pricingTerms = terms }
    }
    var termsNeedFreshPricing: Bool { pricingTerms.map { $0 != terms } ?? false }
    var changedRetailerTerms: Bool { originalTerms.map { $0 != terms } ?? false }
    var pricingNeedsReplacement: Bool { termsNeedFreshPricing || (!supportsEditing && !replacingPricing) }
    var displayLines: [BasketLine] { basketLines }
    var hasUnsavedChanges: Bool {
        guard let initialInput, let initialDetails else { return false }
        return replacingPricing || pricingInput != initialInput || detailsInput != initialDetails
    }

    init() {}

    init(journey: PickupJourney, workspaceID: UUID? = nil, now: Date = Date()) {
        sourceWorkspaceID = workspaceID
        journeyID = journey.id; basketRevisionID = journey.basket?.current.id
        earlierQuoteRevision = journey.earlierQuotes.last?.id
        ledgerSourceRevisionID = journey.ledgerSourceRevisionID
        originalQuote = journey.quote; originalQuotedRevisionID = journey.quotedRevisionID
        originalContext = journey.context; originalCap = journey.cap
        basketLines = journey.basket?.current.lines ?? []
        let currentQuote = journey.quotedRevisionID == basketRevisionID && basketRevisionID != nil ? journey.quote : nil
        let context = currentQuote?.context ?? journey.context
        store = context?.storeID ?? ""; branch = context?.branchID ?? ""
        slot = context?.slot ?? ""; source = context?.source ?? ""
        observed = context?.observedAt ?? now; mode = context?.mode ?? .pickup
        scope = currentQuote?.scope ?? PickupPricingTerms.scope(cap: journey.cap, basis: journey.ledgerBasis)
        capScope = journey.cap?.scope ?? scope
        cap = journey.cap.map { Self.literal($0.amount) } ?? ""
        // An inclusive (or cleared) quote can sit on an older basket revision.
        // A line's original pack price still belongs to the retailer that supplied it.
        let canUseBasketPricing = journey.basketPriceTerms.map { $0 == terms } ?? (currentQuote == nil && journey.earlierQuotes.isEmpty)
        func lineCost(_ line: BasketLine) -> CostEvidence {
            canUseBasketPricing ? line.expectedCost : .unknown(reason: pTr("Recheck the price for this shop"))
        }
        for line in basketLines { prices[line.id] = Self.literal(lineCost(line)) }
        let pricing = currentQuote?.pricing ?? .components(
            lines: basketLines.map { CheckoutLine(id: $0.id, name: $0.name, cost: lineCost($0)) },
            lineSetComplete: true,
            fees: [CheckoutFee(id: "retailer-fee", rule: .fixed(.unknown(reason: pTr("Not confirmed"))))],
            discounts: [CheckoutDiscount(id: "eligible-discount", amount: .unknown(reason: pTr("Not confirmed")), reducesEligibleSubtotal: true)],
            tax: .unknown(reason: pTr("Not confirmed")), deposits: .unknown(reason: pTr("Not confirmed")))
        originalPricing = pricing; hasSavedPricing = currentQuote != nil
        switch pricing {
        case .inclusiveTotal(let evidence):
            inclusive = true; total = Self.literal(evidence)
        case let .components(lines, lineSetComplete, fees, discounts, savedTax, savedDeposits):
            for line in lines { prices[line.id] = Self.literal(line.cost) }
            complete = lineSetComplete
            if let saved = fees.first {
                switch saved.rule {
                case .fixed(let evidence): fee = Self.literal(evidence)
                case let .waivedAt(amount, evidence, _): threshold = Self.literal(amount); fee = Self.literal(evidence)
                }
            } else { fee = "0" }
            discount = discounts.first.map { Self.literal($0.amount) } ?? "0"
            tax = Self.literal(savedTax); deposits = Self.literal(savedDeposits)
        }
        supportsEditing = Self.canEdit(pricing, basketLines: basketLines)
        originalTerms = terms
        if currentQuote != nil || basketLines.contains(where: {
            if case .unknown = lineCost($0) { return false }
            return true
        }) { pricingTerms = terms }
        initialInput = pricingInput
        initialDetails = detailsInput
    }

    /// Source updates can refresh an untouched form, but cannot discard edits or
    /// retarget an edited checkout to another pickup or basket revision.
    @discardableResult mutating func refreshIfPristine(from journey: PickupJourney, workspaceID: UUID? = nil, hasLocalReview: Bool = false,
                                                     now: Date = Date()) -> Bool {
        guard !matchesSource(journey, workspaceID: workspaceID), !hasUnsavedChanges, !hasLocalReview else { return false }
        self = PickupCheckoutDraft(journey: journey, workspaceID: workspaceID, now: now)
        return true
    }

    /// This is called only after the person confirms the replacement in the UI.
    /// The original pricing stays available for comparison until a save succeeds.
    mutating func beginPricingReplacement(now: Date = Date()) {
        if termsNeedFreshPricing { source = ""; observed = now }
        pricingTerms = terms
        replacingPricing = true
        inclusive = false; total = ""; prices = [:]
        fee = ""; threshold = ""; discount = ""; tax = ""; deposits = ""; complete = false
    }

    func matchesSource(_ journey: PickupJourney, workspaceID: UUID? = nil) -> Bool {
        (sourceWorkspaceID == nil || sourceWorkspaceID == workspaceID) && journey.id == journeyID && basketRevisionID != nil && journey.basket?.current.id == basketRevisionID
            && journey.quote == originalQuote && journey.quotedRevisionID == originalQuotedRevisionID
            && journey.earlierQuotes.last?.id == earlierQuoteRevision && journey.ledgerSourceRevisionID == ledgerSourceRevisionID
            && journey.context == originalContext && journey.cap == originalCap
    }

    func submission(for journey: PickupJourney, workspaceID: UUID? = nil) throws -> (quote: CheckoutQuote, cap: CheckoutCap?) {
        guard matchesSource(journey, workspaceID: workspaceID) else { throw PickupCheckoutDraftError.staleSource }
        guard !termsNeedFreshPricing else { throw PickupCheckoutDraftError.reviewReplacement }
        guard !store.isEmpty, !branch.isEmpty, !slot.isEmpty, !source.isEmpty else {
            throw PickupCheckoutDraftError.missingContext
        }
        let commitmentsID = (hasSavedPricing ? originalQuote?.context : originalContext)?.commitmentsID ?? journey.id
        let context = CheckoutContext(storeID: store, branchID: branch, mode: mode, slot: slot,
                                      commitmentsID: commitmentsID, observedAt: observed, source: source)
        let pricing = try makePricing()
        let capAmount: Money?
        if let originalCap, cap == Self.literal(originalCap.amount) { capAmount = originalCap.amount }
        else { capAmount = try ComparisonModel.money(cap) }
        let savedCap = capAmount.map {
            CheckoutCap(scope: capScope, commitmentsID: originalCap?.commitmentsID ?? commitmentsID, amount: $0)
        }
        return (CheckoutQuote(scope: scope, context: context, pricing: pricing), savedCap)
    }

    private func makePricing() throws -> CheckoutPricing {
        if !replacingPricing, let originalPricing, let initialInput {
            if pricingInput == initialInput { return originalPricing }
            guard supportsEditing else { throw PickupCheckoutDraftError.reviewReplacement }
            if inclusive == initialInput.inclusive {
                switch originalPricing {
                case .inclusiveTotal(let evidence):
                    return .inclusiveTotal(try Self.edited(total, initialInput.total, evidence))
                case let .components(lines, _, fees, discounts, savedTax, savedDeposits):
                    let editedLines = try lines.map {
                        CheckoutLine(id: $0.id, name: $0.name,
                                     cost: try Self.edited(prices[$0.id] ?? "", initialInput.prices[$0.id] ?? "", $0.cost),
                                     thresholdEligible: $0.thresholdEligible)
                    }
                    let editedFees: [CheckoutFee]
                    if let saved = fees.first {
                        let evidence: CostEvidence
                        switch saved.rule { case .fixed(let value), .waivedAt(_, let value, _): evidence = value }
                        let cost = try Self.edited(fee, initialInput.fee, evidence)
                        let rule: CheckoutFeeRule
                        let thresholdAmount: Money?
                        if threshold == initialInput.threshold, case .waivedAt(let savedThreshold, _, _) = saved.rule {
                            thresholdAmount = savedThreshold
                        } else { thresholdAmount = try ComparisonModel.money(threshold) }
                        if let amount = thresholdAmount {
                            let basis: FeeThresholdBasis
                            if case .waivedAt(_, _, let savedBasis) = saved.rule { basis = savedBasis }
                            else { basis = .eligibleItemsAfterEligibleDiscounts }
                            rule = .waivedAt(threshold: amount, belowThreshold: cost, basis: basis)
                        } else { rule = .fixed(cost) }
                        editedFees = [CheckoutFee(id: saved.id, rule: rule)]
                    } else if fee == initialInput.fee && threshold == initialInput.threshold { editedFees = [] }
                    else { editedFees = [try newFee()] }
                    let editedDiscounts: [CheckoutDiscount]
                    if let saved = discounts.first {
                        editedDiscounts = [CheckoutDiscount(id: saved.id,
                            amount: try Self.edited(discount, initialInput.discount, saved.amount),
                            reducesEligibleSubtotal: saved.reducesEligibleSubtotal)]
                    } else if discount == initialInput.discount { editedDiscounts = [] }
                    else { editedDiscounts = [try newDiscount()] }
                    return .components(lines: editedLines, lineSetComplete: complete, fees: editedFees,
                        discounts: editedDiscounts, tax: try Self.edited(tax, initialInput.tax, savedTax),
                        deposits: try Self.edited(deposits, initialInput.deposits, savedDeposits))
                }
            }
        }
        if inclusive { return .inclusiveTotal(try Self.evidence(total)) }
        return .components(lines: try basketLines.map {
            CheckoutLine(id: $0.id, name: $0.name, cost: try Self.evidence(prices[$0.id] ?? ""))
        }, lineSetComplete: complete, fees: [try newFee()], discounts: [try newDiscount()],
           tax: try Self.evidence(tax), deposits: try Self.evidence(deposits))
    }

    private func newFee() throws -> CheckoutFee {
        let rule: CheckoutFeeRule
        if let amount = try ComparisonModel.money(threshold) {
            rule = .waivedAt(threshold: amount, belowThreshold: try Self.evidence(fee), basis: .eligibleItemsAfterEligibleDiscounts)
        } else { rule = .fixed(try Self.evidence(fee)) }
        return CheckoutFee(id: "retailer-fee", rule: rule)
    }
    private func newDiscount() throws -> CheckoutDiscount {
        CheckoutDiscount(id: "eligible-discount", amount: try Self.evidence(discount), reducesEligibleSubtotal: true)
    }
    private static func edited(_ text: String, _ originalText: String, _ original: CostEvidence) throws -> CostEvidence {
        if text == originalText { return original }
        return try evidence(text)
    }
    private static func evidence(_ text: String) throws -> CostEvidence {
        try ComparisonModel.money(text).map(CostEvidence.exact) ?? .unknown(reason: pTr("Not confirmed"))
    }
    private static func literal(_ amount: Money) -> String { (Decimal(amount.minorUnits) / 100).description }
    private static func literal(_ evidence: CostEvidence) -> String {
        if case .exact(let amount) = evidence { return literal(amount) }
        return ""
    }
    private static func scalar(_ evidence: CostEvidence) -> Bool {
        if case .bounded = evidence { return false }
        return true
    }
    private static func canEdit(_ pricing: CheckoutPricing, basketLines: [BasketLine]) -> Bool {
        switch pricing {
        case .inclusiveTotal(let evidence): return scalar(evidence)
        case let .components(lines, _, fees, discounts, tax, deposits):
            guard lines.count == basketLines.count, Set(lines.map(\.id)) == Set(basketLines.map(\.id)),
                  lines.allSatisfy({ line in basketLines.contains(where: { $0.id == line.id && $0.name == line.name }) && line.thresholdEligible && scalar(line.cost) }),
                  fees.count <= 1, discounts.count <= 1, scalar(tax), scalar(deposits),
                  discounts.allSatisfy({ $0.reducesEligibleSubtotal && scalar($0.amount) }) else { return false }
            return fees.allSatisfy {
                switch $0.rule {
                case .fixed(let evidence): return scalar(evidence)
                case let .waivedAt(_, evidence, basis): return basis == .eligibleItemsAfterEligibleDiscounts && scalar(evidence)
                }
            }
        }
    }
}
