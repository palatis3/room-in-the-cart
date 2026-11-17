import Foundation

public enum LedgerPackError: Error, Equatable, Sendable {
    case unsupportedVersion, invalidEvidence, staleSource, missingQuantity, unavailableLine, operationConflict
}

/// Reviewed item-only purchase evidence. It contains neither checkout authority
/// nor a claim that the complete pickup is affordable.
public enum LedgerPackOutcome: String, Codable, Sendable { case purchase, noPurchase }

public struct LedgerPackSelection: Codable, Equatable, Sendable, Identifiable {
    public static let calculationVersion = "pack-v1/" + UnitOfMeasure.conversionTableVersion
    public let id: UUID
    public let formatVersion: Int
    public let engineVersion: String
    public let sourceWorkspaceID: UUID
    public let shopID: UUID
    public let lineID: UUID
    public let shopRevisionID: UUID
    public let basisRevision: Int
    public let request: ComparisonRequest
    public let selectedOfferID: String
    public let selectedResult: OfferResult
    public let reviewedAt: Date
    public let source: String
    public let stockEvidence: LedgerPackStockEvidence?
    public let canonicalStockEvidence: LedgerCanonicalPackStockEvidence?
    public let outcome: LedgerPackOutcome?
    public var isNoPurchase: Bool { outcome == .noPurchase }

    public init(id: UUID = UUID(), workspaceID: UUID, shop: ShoppingLedger, lineID: UUID,
                request: ComparisonRequest, selectedOfferID: String, at: Date, source: String, bindings: [DinnerPortionBinding] = [], stockEvidence: LedgerPackStockEvidence? = nil, canonicalStockEvidence: LedgerCanonicalPackStockEvidence? = nil) throws {
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: lineID, bindings: bindings)
        guard stockEvidence == nil || canonicalStockEvidence == nil else { throw LedgerPackError.invalidEvidence }
        let confirmed: Quantity?
        if let canonicalStockEvidence { confirmed = try canonicalStockEvidence.confirmedQuantity(for: requirement) }
        else { confirmed = try stockEvidence?.confirmedQuantity(for: requirement) }
        guard request.itemName == requirement.name, request.needed == requirement.quantity,
              request.protectedAmount == requirement.protectedQuantity,
              request.confirmedAtHome == confirmed else { throw LedgerPackError.staleSource }
        let comparison = try PackComparison.evaluate(request)
        let selected: OfferResult
        if selectedOfferID == request.offerA.id { selected = comparison.offerA }
        else if selectedOfferID == request.offerB.id { selected = comparison.offerB }
        else { throw LedgerPackError.invalidEvidence }
        if let stockEvidence {
            guard stockEvidence.journeyID == shop.id, stockEvidence.shopRevisionID == shop.revisionID,
                  stockEvidence.lineID == lineID else { throw LedgerPackError.staleSource }
        }
        if let canonicalStockEvidence {
            guard canonicalStockEvidence.scope.journeyID == shop.id,
                  canonicalStockEvidence.scope.shopRevisionID == shop.revisionID,
                  canonicalStockEvidence.scope.lineID == lineID else { throw LedgerPackError.staleSource }
        }
        self.id = id; formatVersion = canonicalStockEvidence != nil ? 3 : (stockEvidence == nil ? 1 : 2)
        engineVersion = Self.calculationVersion
        self.stockEvidence = stockEvidence; self.canonicalStockEvidence = canonicalStockEvidence
        outcome = formatVersion == 1 ? nil : (selected.packsToBuy == 0 ? .noPurchase : .purchase)
        sourceWorkspaceID = workspaceID; shopID = shop.id; self.lineID = lineID
        shopRevisionID = shop.revisionID; basisRevision = shop.basisRevision
        self.request = request; self.selectedOfferID = selectedOfferID; selectedResult = selected
        reviewedAt = at; self.source = source
        try validate()
    }

    public func validate() throws {
        guard [1, 2, 3].contains(formatVersion), engineVersion == Self.calculationVersion else { throw LedgerPackError.unsupportedVersion }
        guard basisRevision >= 0, reviewedAt.timeIntervalSinceReferenceDate.isFinite,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.utf8.count <= 512 else { throw LedgerPackError.invalidEvidence }
        if formatVersion == 1 {
            guard stockEvidence == nil, canonicalStockEvidence == nil, outcome == nil, request.confirmedAtHome == nil else { throw LedgerPackError.invalidEvidence }
        } else if formatVersion == 2 {
            guard canonicalStockEvidence == nil, let stockEvidence, let needed = request.needed, let protected = request.protectedAmount,
                  stockEvidence.journeyID == shopID, stockEvidence.shopRevisionID == shopRevisionID,
                  stockEvidence.lineID == lineID, outcome != nil,
                  request.confirmedAtHome == (try stockEvidence.confirmedQuantity(for:
                    LedgerPackRequirement(name: request.itemName, quantity: needed, protectedQuantity: protected))) else { throw LedgerPackError.invalidEvidence }
        } else {
            guard stockEvidence == nil, let canonicalStockEvidence, let needed = request.needed,
                  let protected = request.protectedAmount, outcome != nil,
                  canonicalStockEvidence.scope.journeyID == shopID,
                  canonicalStockEvidence.scope.shopRevisionID == shopRevisionID,
                  canonicalStockEvidence.scope.lineID == lineID,
                  request.confirmedAtHome == (try canonicalStockEvidence.confirmedQuantity(for:
                    LedgerPackRequirement(name: request.itemName, quantity: needed, protectedQuantity: protected))) else {
                throw LedgerPackError.invalidEvidence
            }
        }
        let comparison = try PackComparison.evaluate(request)
        let recomputed: OfferResult
        if selectedOfferID == request.offerA.id { recomputed = comparison.offerA }
        else if selectedOfferID == request.offerB.id { recomputed = comparison.offerB }
        else { throw LedgerPackError.invalidEvidence }
        guard selectedResult == recomputed, selectedResult.isResolved,
              let packs = selectedResult.packsToBuy, let purchased = selectedResult.purchasedAmount,
              selectedResult.totalCost != nil else { throw LedgerPackError.invalidEvidence }
        if isNoPurchase {
            guard (formatVersion == 2 || formatVersion == 3), packs == 0, purchased == .zero,
                  selectedResult.amountToBuy == .zero, selectedResult.totalCost == .zero else { throw LedgerPackError.invalidEvidence }
        } else {
            guard packs > 0, purchased > .zero, outcome != .noPurchase else { throw LedgerPackError.invalidEvidence }
        }
    }

    /// Historical evidence must still point at an actual retained source revision.
    public func validateReference(in shop: ShoppingLedger) throws {
        try validate()
        guard shop.id == shopID, shop.lines.contains(where: { $0.id == lineID }),
              shop.revisions.contains(where: { $0.id == shopRevisionID && $0.basisRevision == basisRevision }) else { throw LedgerPackError.invalidEvidence }
    }

    public func isCurrent(in shop: ShoppingLedger, workspaceID: UUID, bindings: [DinnerPortionBinding] = [], currentStockEvidence: LedgerPackStockEvidence? = nil, currentCanonicalEvidence: LedgerCanonicalPackStockEvidence? = nil) throws -> Bool {
        try validateReference(in: shop)
        guard sourceWorkspaceID == workspaceID, shop.revisionID == shopRevisionID,
              shop.basisRevision == basisRevision, stockEvidence == currentStockEvidence,
              canonicalStockEvidence == currentCanonicalEvidence else { return false }
        guard let requirement = try? LedgerPackRequirement.review(shop: shop, lineID: lineID, bindings: bindings) else { return false }
        return request.itemName == requirement.name && request.needed == requirement.quantity && request.protectedAmount == requirement.protectedQuantity
    }

    /// Validates only an already applied unchanged basket, never a new selection.
    /// Source-only quote/copy revisions may advance while complete physical/claim
    /// material stays identical. Another basket revision must be reviewed anew.
    public func isCurrentForAppliedBasket(in shop: ShoppingLedger, workspaceID: UUID,
        bindings: [DinnerPortionBinding] = [], currentCanonicalEvidence: LedgerCanonicalPackStockEvidence,
        basket: BasketPlan, retainedSelections: [LedgerPackSelection]) throws -> Bool {
        try validateReference(in: shop)
        guard let reviewed = canonicalStockEvidence, sourceWorkspaceID == workspaceID,
              shop.revisionID == shopRevisionID, shop.basisRevision == basisRevision,
              basket.id == shop.id, basket.phase != .reportedPlaced, retainedSelections.contains(self),
              currentCanonicalEvidence.scope.basketRevisionID == basket.current.id,
              currentCanonicalEvidence.scope.journeyRevision > reviewed.scope.journeyRevision,
              basket.current.parentID == reviewed.scope.basketRevisionID,
              case .applied = basket.current.reason,
              try reviewed.hasSameMaterial(as: currentCanonicalEvidence) else { return false }
        let requirement = try LedgerPackRequirement.review(shop: shop, lineID: lineID, bindings: bindings)
        guard request.itemName == requirement.name, request.needed == requirement.quantity,
              request.protectedAmount == requirement.protectedQuantity,
              request.confirmedAtHome == (try currentCanonicalEvidence.confirmedQuantity(for: requirement)) else { return false }
        if isNoPurchase { return !basket.current.lines.contains { $0.id == lineID } }
        guard let line = basket.current.lines.first(where: { $0.id == lineID }) else { return false }
        return line.quantity == purchasedQuantity && line.expectedCost == selectedResult.totalCost.map(CostEvidence.exact)
    }

    public var purchasedQuantity: Quantity? {
        guard !isNoPurchase, let amount = selectedResult.purchasedAmount, let unit = request.needed?.unit else { return nil }
        return Quantity(amount: amount, unit: unit, originalLiteral: amount.description)
    }
}

public struct LedgerPackRequirement: Equatable, Sendable {
    public let name: String
    public let quantity: Quantity
    /// This is a partition inside quantity, never additional demand.
    public let protectedQuantity: Quantity

    public static func review(shop: ShoppingLedger, lineID: UUID, bindings: [DinnerPortionBinding] = []) throws -> LedgerPackRequirement {
        try shop.validate()
        guard let line = shop.lines.first(where: { $0.id == lineID }), !line.isTrashed, !line.isHandled else { throw LedgerPackError.unavailableLine }
        guard let quantity = try shop.quantity(forLineID: lineID), quantity.amount > .zero else { throw LedgerPackError.missingQuantity }
        var protected = Rational.zero
        for contribution in shop.contributions(forLineID: lineID) {
            guard let amount = try contribution.quantity?.converted(to: quantity.unit) else { throw LedgerPackError.missingQuantity }
            switch contribution.source {
            case .protectedNeed: protected = try protected.adding(amount)
            case .meal(let occurrenceID):
                guard let meal = shop.mealOccurrences.first(where: { $0.id == occurrenceID && $0.removedAt == nil }) else { throw LedgerPackError.invalidEvidence }
                let portions = try LedgerMealPortions.review(meal: meal, contribution: contribution, in: shop, unit: quantity.unit, bindings: bindings)
                for group in meal.servingGroups where group.isProtected {
                    guard let part = portions.groups[group.id] else { throw LedgerPackError.invalidEvidence }
                    protected = try protected.adding(part)
                }
            default: break
            }
        }
        guard protected <= quantity.amount else { throw LedgerPackError.invalidEvidence }
        return LedgerPackRequirement(name: line.name, quantity: quantity,
            protectedQuantity: Quantity(amount: protected, unit: quantity.unit, originalLiteral: protected.description))
    }
}

extension LedgerWorkspace {
    @discardableResult public mutating func recordPackSelection(_ selection: LedgerPackSelection, workspaceID: UUID, currentStockEvidence: LedgerPackStockEvidence? = nil, currentCanonicalEvidence: LedgerCanonicalPackStockEvidence? = nil) throws -> Bool {
        if let existing = packSelections.first(where: { $0.id == selection.id }) {
            guard existing == selection else { throw LedgerPackError.operationConflict }
            return false
        }
        guard let shop = shops.first(where: { $0.id == selection.shopID }),
              try selection.isCurrent(in: shop, workspaceID: workspaceID, bindings: dinnerPlanning.portionBindings, currentStockEvidence: currentStockEvidence, currentCanonicalEvidence: currentCanonicalEvidence) else { throw LedgerPackError.staleSource }
        var candidate = self
        candidate.packSelections.append(selection)
        try candidate.validate()
        self = candidate
        return true
    }

    public func currentPackSelection(shopID: UUID, lineID: UUID, workspaceID: UUID,
        currentStockEvidence: LedgerPackStockEvidence? = nil, currentCanonicalEvidence: LedgerCanonicalPackStockEvidence? = nil) throws -> LedgerPackSelection? {
        guard let shop = shops.first(where: { $0.id == shopID }) else { throw LedgerPackError.unavailableLine }
        for selection in packSelections.reversed() where selection.shopID == shopID && selection.lineID == lineID {
            if try selection.isCurrent(in: shop, workspaceID: workspaceID, bindings: dinnerPlanning.portionBindings,
                currentStockEvidence: currentStockEvidence, currentCanonicalEvidence: currentCanonicalEvidence) { return selection }
        }
        return nil
    }
}
