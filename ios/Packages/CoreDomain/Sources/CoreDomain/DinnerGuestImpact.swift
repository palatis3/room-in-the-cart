import Foundation

/// A read-only projection. Pack evidence belongs to the reviewed base revision, never to a new basket.
public struct DinnerGuestImpact: Equatable, Sendable {
    public struct Line: Equatable, Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let packLabel: String?
        public let before: Int64?
        public let after: Int64?
        public let beforeCost: Money?
        public let afterCost: Money?
    }
    public let lines: [Line]
    public let beforeCheckout: CheckoutResult?
    public let afterCheckout: CheckoutResult?
    public let beforeFees: CheckoutAmount?
    public let afterFees: CheckoutAmount?
}

extension DinnerPreview {
    public var reviewsGuestPurchases: Bool {
        guard proposal.tool == .guests || proposal.tool == .manual else { return false }
        return !proposal.changes.isEmpty && proposal.changes.allSatisfy { if case .adjust = $0 { return true }; return false }
    }

    public func guestImpact(workspace: LedgerWorkspace, workspaceID: UUID, quote: CheckoutQuote?) throws -> DinnerGuestImpact {
        guard reviewsGuestPurchases, proposal.namespace == "local:\(workspaceID.uuidString)",
              let shop = workspace.shops.first(where: { $0.id == proposal.shopID }),
              shop.revisionID == proposal.baseRevisionID, workspace.dinnerPlanning.revisionID == proposal.planningRevisionID else {
            throw DinnerPlanningError.stalePreview
        }
        let changed = Set(changedContributionIDs)
        let ids = Set(projectedContributions.filter { changed.contains($0.id) }.map(\.lineID))
        let lines = try shop.lines.filter { ids.contains($0.id) && !$0.isTrashed && !$0.isHandled }.map { line in
            let evidence = try workspace.currentPackSelection(shopID: shop.id, lineID: line.id, workspaceID: workspaceID)
            let selected = evidence.map { $0.selectedOfferID == $0.request.offerA.id ? $0.request.offerA : $0.request.offerB }
            var after: OfferResult?
            if let evidence, let needed = try projectedLedger.quantity(forLineID: line.id) {
                // Named portions are already inside ledger demand. Do not add them again or invent available stock.
                let request = ComparisonRequest(itemName: line.name, needed: needed, offerA: evidence.request.offerA, offerB: evidence.request.offerB)
                let repriced = try PackComparison.evaluate(request)
                after = evidence.selectedOfferID == request.offerA.id ? repriced.offerA : repriced.offerB
            }
            return DinnerGuestImpact.Line(id: line.id, name: line.name, packLabel: selected?.label,
                before: evidence?.selectedResult.packsToBuy, after: after?.packsToBuy,
                beforeCost: budgetBasis == nil ? nil : evidence?.selectedResult.totalCost,
                afterCost: budgetBasis == nil ? nil : after?.totalCost)
        }
        let unpriced = DinnerGuestImpact(lines: lines, beforeCheckout: nil, afterCheckout: nil, beforeFees: nil, afterFees: nil)
        guard budgetBasis != nil, let quote, quote.scope == .wholeCheckout, quote.context.commitmentsID == shop.id else { return unpriced }
        let before = try CheckoutEngine.evaluateWithFees(quote)
        guard case let .components(items, complete, fees, discounts, tax, deposits) = quote.pricing,
              Set(items.map(\.id)) == Set(shop.lines.filter { !$0.isHandled && !$0.isTrashed }.map(\.id)) else {
            return DinnerGuestImpact(lines: lines, beforeCheckout: before.result, afterCheckout: nil, beforeFees: before.fees, afterFees: nil)
        }
        let changes = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        let updated = items.map { item in
            guard let change = changes[item.id] else { return item }
            guard let old = change.beforeCost, item.cost == .exact(old), let new = change.afterCost else {
                return CheckoutLine(id: item.id, name: item.name, cost: .unknown(reason: "Review changed package price"), thresholdEligible: item.thresholdEligible)
            }
            return CheckoutLine(id: item.id, name: item.name, cost: .exact(new), thresholdEligible: item.thresholdEligible)
        }
        let revised = CheckoutQuote(scope: quote.scope, context: quote.context, pricing: .components(lines: updated,
            lineSetComplete: complete, fees: fees, discounts: discounts, tax: tax, deposits: deposits))
        let after = try CheckoutEngine.evaluateWithFees(revised)
        return DinnerGuestImpact(lines: lines, beforeCheckout: before.result, afterCheckout: after.result, beforeFees: before.fees, afterFees: after.fees)
    }
}
