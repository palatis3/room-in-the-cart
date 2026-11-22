import SwiftUI
import CryptoKit
import CoreDomain

/// Installation-local bridge, supplied by composition. A missing bridge never
/// fabricates a second shopping workspace or claims that a list was updated.
private struct PickupLedgerKey: EnvironmentKey { static let defaultValue: LedgerModel? = nil }
extension EnvironmentValues {
    var pickupLedger: LedgerModel? {
        get { self[PickupLedgerKey.self] }
        set { self[PickupLedgerKey.self] = newValue }
    }
}

extension PickupJourney {
    var isFreshNextShopDraft: Bool {
        originShopID != nil && basket?.phase == .draft && context == nil && quote == nil && pickup == nil
    }
}

enum LedgerCheckoutError: Error, Equatable {
    case missingQuantity, emptyList, ambiguousServingGroups, staleSource, staleCheckout, placedOrder
    case changedDeferredLine(String)
}

struct LedgerCheckoutReview {
    let source: ShoppingLedger
    let workspaceRevision: Int64
    let previousJourneyRevision: Int64?
    let previousBasketRevision: UUID?
    let lines: [BasketLine]
    let needs: [AllocationNeed]
    let sourceNeeds: [AllocationNeed]
    let deferredLineIDs: Set<UUID>
    let details: [PickupNeedDetail]
    let packSelections: [LedgerPackSelection]
    let unreviewedPackLineIDs: [UUID]
    let context: CheckoutContext
    let cap: CheckoutCap?
    let proposal: BasketProposal?
    let needsApplication: Bool

    func assertCurrent(shop: ShoppingLedger?, workspaceRevision: Int64, journey: PickupJourney?) throws {
        guard shop == source, self.workspaceRevision == workspaceRevision else { throw LedgerCheckoutError.staleSource }
        guard journey?.id == (previousJourneyRevision == nil ? nil : source.id),
              journey?.revision == previousJourneyRevision,
              journey?.basket?.current.id == previousBasketRevision else { throw LedgerCheckoutError.staleCheckout }
    }
}

/// Only source contributions create named meal demand. Allocation edges describe
/// which part is already within a typed total; they never create a second need.
enum LedgerCheckoutAdapter {
    static func review(shop: ShoppingLedger, workspaceRevision: Int64, previous: PickupJourney?,
                       packSelections: [LedgerPackSelection] = [], workspaceID: UUID? = nil, pickupWorkspaceID: UUID? = nil, bindings: [DinnerPortionBinding] = [],
                       canonicalEvidence: [UUID: LedgerCanonicalPackStockEvidence] = [:], pantryIsActive: Bool = false, usedForDinner: Set<UUID> = []) throws -> LedgerCheckoutReview {
        try shop.validate()
        let handChecked = shop.handCheckedOnlyLineIDs
        let sourceNeedLines = shop.lines.filter { !$0.isTrashed && !$0.isHandled }
        let activeLines = shop.purchaseReviewLines.filter(shop.belongsInCurrentBasket)
        let activeByID = Dictionary(uniqueKeysWithValues: activeLines.map { ($0.id, $0) })
        // Trashed and handled rows both leave the editable list. A saved basket
        // still needs a review that can remove its final purchase.
        let canReviewRemovals = previous?.id == shop.id && previous?.basket != nil && !shop.lines.isEmpty
        guard !activeLines.isEmpty || canReviewRemovals else { throw LedgerCheckoutError.emptyList }
        let sameBasis = previous?.ledgerBasis == shop.basis
        let itemPackages = shop.itemPackages
        var selectedPacks: [UUID: LedgerPackSelection] = [:]
        for selection in packSelections where selection.shopID == shop.id {
            try selection.validateReference(in: shop)
            guard !usedForDinner.contains(selection.lineID), let line = activeByID[selection.lineID], let workspaceID else { continue }
            if let pick = line.tripPick {
                guard let packages = try shop.physicalPackages(for: line, requested: shop.quantity(forLineID: line.id),
                                                               sourcePackages: itemPackages[line.id] ?? []),
                      try selection.describes(pick, packages: packages) else { continue }
            }
            if pantryIsActive, selection.isGrossOnlyPurchase {
                if try selection.isCurrent(in: shop, workspaceID: workspaceID, bindings: bindings) {
                    selectedPacks[selection.lineID] = selection
                }
            } else if try LedgerPackStockReview.isCurrent(selection, shop: shop, workspaceID: workspaceID, journey: previous,
                pickupWorkspaceID: pickupWorkspaceID, bindings: bindings,
                currentCanonicalEvidence: canonicalEvidence[selection.id], pantryIsActive: pantryIsActive) {
                selectedPacks[selection.lineID] = selection
            }
        }
        let priorPackLineIDs = Set(previous?.ledgerPackSelections.map(\.lineID) ?? [])
        let reviewedPackLineIDs = Set(packSelections.filter { $0.shopID == shop.id }.map(\.lineID)).union(priorPackLineIDs)
        let itemExclusions = shop.itemExclusions
        let sourceLines = try activeLines.compactMap { line -> BasketLine? in
            if usedForDinner.contains(line.id) || selectedPacks[line.id]?.isNoPurchase == true { return nil }
            let requested = try shop.quantity(forLineID: line.id)
            guard let quantity = line.tripPick?.amount ?? requested else { throw LedgerCheckoutError.missingQuantity }
            let exclusions = itemExclusions[line.id] ?? []
            if let selection = selectedPacks[line.id], let purchased = selection.purchasedQuantity, let price = selection.selectedResult.totalCost {
                let offer = selection.selectedOfferID == selection.request.offerA.id ? selection.request.offerA : selection.request.offerB
                guard let count = selection.selectedResult.packsToBuy, let size = offer.usableQuantity else { throw LedgerPackError.invalidEvidence }
                let packs = [BasketPackage(count: count, amountPerPack: size.amount, unit: size.unit)]
                return BasketLine(id: line.id, name: line.name, quantity: line.tripPick?.amount ?? purchased, expectedCost: .exact(price),
                                  itemExclusions: exclusions, packages: packs)
            }
            let sourcePacks = itemPackages[line.id] ?? []
            let packs = try line.tripPick == nil ? sourcePacks : shop.physicalPackages(for: line, requested: requested, sourcePackages: sourcePacks) ?? []
            let old = previous?.basket?.current.lines.first { old in
                let matchesPick = line.tripPick != nil && old.quantity.unit == quantity.unit &&
                    old.quantity.amount == quantity.amount && old.quantity.confirmedConversion == quantity.confirmedConversion
                return old.id == line.id && old.name == line.name && (old.quantity == quantity || matchesPick) &&
                    (old.itemExclusions ?? []) == exclusions && (old.packages ?? []) == packs
            }
            let retainedCost = sameBasis && !priorPackLineIDs.contains(line.id) ? old?.expectedCost : nil
            return BasketLine(id: line.id, name: line.name, quantity: quantity,
                              expectedCost: retainedCost ?? .unknown(reason: pTr("Recheck the price for this shop")),
                              itemExclusions: exclusions, packages: packs)
        }
        var needs: [AllocationNeed] = [], details: [PickupNeedDetail] = []
        for line in sourceNeedLines where !handChecked.contains(line.id) {
            guard let sourceQuantity = try shop.quantity(forLineID: line.id) else {
                if activeByID[line.id] == nil { continue }
                throw LedgerCheckoutError.missingQuantity
            }
            let sourceAmount = sourceQuantity.amount
            let named = try namedReservations(shop: shop, lineID: line.id, unit: sourceQuantity.unit, bindings: bindings)
            let namedAmount = named.amount
            needs += named.needs
            details += named.details
            guard namedAmount <= sourceAmount else { throw LedgerCheckoutError.ambiguousServingGroups }
            // Unassigned manual/import quantities remain one separate purpose.
            // Twelve typed wraps with 6 + 4 + 2 linked portions have no residual.
            let remainder = try sourceAmount.subtracting(namedAmount)
            if remainder > .zero {
                needs.append(AllocationNeed(id: line.id, orderLineID: line.id, name: line.name, amount: Quantity(amount: remainder, unit: sourceQuantity.unit, originalLiteral: sourceQuantity.originalLiteral), priority: .required))
                details.append(PickupNeedDetail(id: line.id, mealName: line.name, exclusions: shop.contributions(forLineID: line.id).flatMap(\.exclusions), scheduledDay: nil, leadTimeMinutes: nil, completedSteps: []))
            }
        }
        // A checkout deferral belongs to this shop even though its source line
        // stays in the editable list. Undo is the explicit way to buy it again.
        var deferredLineIDs = Set<UUID>()
        if let previous, previous.id == shop.id, let basket = previous.basket {
            let basketIDs = Set(basket.current.lines.map(\.id))
            let sourceIDs = Set(shop.lines.map(\.id))
            let linesByID = Dictionary(uniqueKeysWithValues: sourceLines.map { ($0.id, $0) })
            let needsByLine = Dictionary(grouping: needs, by: \.orderLineID)
            let carriedByLine = Dictionary(grouping: previous.carriedMeals, by: \.orderLineID)
            for deferred in previous.deferred where deferred.sourceShopID == shop.id && deferred.status == "review" {
                let original = deferred.line
                guard sourceIDs.contains(original.id), !basketIDs.contains(original.id) else { continue }
                guard let line = linesByID[original.id], line.name == original.name, line.quantity == original.quantity,
                      line.itemExclusions == original.itemExclusions, line.packages == original.packages,
                      needsByLine[line.id] == carriedByLine[line.id] else {
                    throw LedgerCheckoutError.changedDeferredLine(original.name)
                }
                deferredLineIDs.insert(line.id)
            }
        }
        let lines = sourceLines.filter { !deferredLineIDs.contains($0.id) }
        let plannedNeeds = needs.filter { activeByID[$0.orderLineID] != nil && !deferredLineIDs.contains($0.orderLineID) }
        let preview = shop.basis.retailerPreview
        guard let observedAt = preview?.capturedAt ?? shop.revisions.last?.createdAt else { throw LedgerCheckoutError.staleSource }
        let mode: ShoppingMode
        switch shop.basis.mode { case .pickup: mode = .pickup; case .delivery: mode = .delivery; case .inStore: mode = .inStore }
        let context = CheckoutContext(storeID: shop.basis.branch, branchID: shop.basis.branch,
            mode: mode,
            slot: shop.basis.slot.map { "\($0.ISO8601Format()) · \(shop.basis.timeZoneIdentifier)" } ?? "",
            commitmentsID: shop.id, observedAt: observedAt, source: preview?.source ?? pTr("Shopper-entered list"))
        let scope: CheckoutScope
        switch shop.basis.capScope { case .wholeShop: scope = .wholeCheckout; case .dinnersOnly: scope = .dinner; case .selectedItems: scope = .item }
        let cap = shop.basis.cap.map { CheckoutCap(scope: scope, commitmentsID: shop.id, amount: $0) }
        let currentPacks = activeLines.compactMap { selectedPacks[$0.id] }
        // A later quote can refine the store, slot and cap in checkout itself.
        // Reopening the same purchased lines and source evidence retains those terms.
        let unchanged = previous?.ledgerSourceRevisionID == shop.revisionID && sameBasis && previous?.basket?.current.lines == lines && previous?.plannedNeeds == plannedNeeds && previous?.needDetails == details && previous?.ledgerPackSelections == currentPacks && previous?.context != nil
        // A retained application permits reopening its exact unchanged basket only.
        // Another checkout change requires a fresh review of its stock choices.
        let reused = Set(currentPacks.filter { selection in
            if let canonical = selection.canonicalStockEvidence { return canonicalEvidence[selection.id] != canonical }
            return selection.stockEvidence.map { $0.journeyRevision != previous?.revision } ?? false
        }.map(\.id))
        if !unchanged, !reused.isEmpty {
            return try review(shop: shop, workspaceRevision: workspaceRevision, previous: previous,
                packSelections: packSelections.filter { !reused.contains($0.id) }, workspaceID: workspaceID,
                pickupWorkspaceID: pickupWorkspaceID, bindings: bindings, canonicalEvidence: canonicalEvidence, pantryIsActive: pantryIsActive, usedForDinner: usedForDinner)
        }
        let proposal: BasketProposal?
        if let basket = previous?.basket, !unchanged {
            var changes = lines.filter { line in basket.current.lines.first(where: { $0.id == line.id }) != line }.map(BasketChange.upsert)
            changes += basket.current.lines.filter { old in !lines.contains(where: { $0.id == old.id }) }.map { .remove($0.id) }
            // Basis-only and purpose-only reviews still make a fresh revision,
            // so an old frozen snapshot cannot stand for newly reviewed terms.
            if changes.isEmpty { changes = lines.map(BasketChange.upsert) }
            proposal = changes.isEmpty ? nil : BasketProposal(id: UUID(), baseRevisionID: basket.current.id, revisionID: UUID(), changes: changes)
        } else { proposal = nil }
        return LedgerCheckoutReview(source: shop, workspaceRevision: workspaceRevision,
            previousJourneyRevision: previous?.revision, previousBasketRevision: previous?.basket?.current.id,
            lines: lines, needs: plannedNeeds, sourceNeeds: needs, deferredLineIDs: deferredLineIDs, details: details, packSelections: currentPacks,
            unreviewedPackLineIDs: activeLines.filter { line in
                !usedForDinner.contains(line.id) && selectedPacks[line.id] == nil && reviewedPackLineIDs.contains(line.id)
            }.map(\.id), context: unchanged ? previous?.context ?? context : context, cap: unchanged ? previous?.cap : cap,
            proposal: proposal, needsApplication: !unchanged)
    }

    /// Live app entry point. A missing canonical proof makes that choice
    /// unreviewed; it never permits active pantry to reuse legacy copied stock.
    @MainActor static func review(shop: ShoppingLedger, workspaceRevision: Int64, previous: PickupJourney?,
                                  packSelections: [LedgerPackSelection] = [], workspaceID: UUID? = nil,
                                  pickupWorkspaceID: UUID? = nil, bindings: [DinnerPortionBinding] = [],
                                  pantryContext: PantryPackStockReview.Context?, pantryIsActive: Bool,
                                  dinnerWorkspace: LedgerWorkspace? = nil, dinnerActorID: UUID? = nil) throws -> LedgerCheckoutReview {
        var usedForDinner = Set<UUID>()
        var evidence: [UUID: LedgerCanonicalPackStockEvidence] = [:]
        if pantryIsActive, let pantryContext {
            guard pantryContext.snapshot.state.active,
                  pantryContext.snapshot.state.workspaceID == pickupWorkspaceID else { throw LedgerCheckoutError.staleSource }
            // The supplied journey must be the exact saved source from this read.
            // A copied basket alongside newer source heads cannot qualify for the
            // intentional already-applied-basket exception.
            if let previous {
                guard let head = pantryContext.mapping.sourceHeads.first(where: { $0.id == previous.id }),
                      try JSONDecoder().decode(PickupJourney.self, from: head.payload) == previous else { throw LedgerCheckoutError.staleCheckout }
                if let dinnerWorkspace, let workspaceID, let dinnerActorID {
                    usedForDinner = previous.usedDinnerPantryLines(in: shop, workspace: dinnerWorkspace,
                        workspaceID: workspaceID, actorID: dinnerActorID, context: pantryContext)
                }
            }
            for selection in packSelections where selection.shopID == shop.id && selection.canonicalStockEvidence != nil {
                evidence[selection.id] = try? PantryPackStockReview.currentEvidence(for: selection, shop: shop,
                    bindings: bindings, context: pantryContext)
            }
        }
        return try review(shop: shop, workspaceRevision: workspaceRevision, previous: previous, packSelections: packSelections,
            workspaceID: workspaceID, pickupWorkspaceID: pickupWorkspaceID, bindings: bindings,
            canonicalEvidence: evidence, pantryIsActive: pantryIsActive, usedForDinner: usedForDinner)
    }

    static func namedReservations(shop: ShoppingLedger, lineID: UUID, unit: UnitOfMeasure, bindings: [DinnerPortionBinding]) throws
        -> (amount: Rational, needs: [AllocationNeed], details: [PickupNeedDetail]) {
        var needs: [AllocationNeed] = [], details: [PickupNeedDetail] = []
        var namedAmount = Rational.zero
        for contribution in shop.contributions(forLineID: lineID) {
            if contribution.isHandCheckedUnmeasuredIngredient { continue }
            guard contribution.source.isMeal || contribution.source.isProtected else { continue }
            guard let quantity = contribution.quantity, let amount = try quantity.converted(to: unit) else { throw LedgerCheckoutError.missingQuantity }
            namedAmount = try namedAmount.adding(amount)
            let normalized = Quantity(amount: amount, unit: unit, originalLiteral: quantity.originalLiteral)
            switch contribution.source {
            case let .protectedNeed(purpose):
                needs.append(AllocationNeed(id: contribution.id, orderLineID: lineID, name: purpose, amount: normalized, priority: .protected))
                details.append(PickupNeedDetail(id: contribution.id, mealName: purpose, exclusions: contribution.exclusions, scheduledDay: nil, leadTimeMinutes: nil, completedSteps: []))
            case let .meal(occurrenceID):
                guard let meal = shop.mealOccurrences.first(where: { $0.id == occurrenceID && $0.removedAt == nil }) else { throw LedgerCheckoutError.staleSource }
                let portions = try LedgerMealPortions.review(meal: meal, contribution: contribution, in: shop, unit: unit, bindings: bindings)
                for group in meal.servingGroups {
                    guard let portion = portions.groups[group.id] else { throw LedgerCheckoutError.ambiguousServingGroups }
                    guard portion > .zero else { continue }
                    let id = compositeID(contribution.id, group.id)
                    needs.append(AllocationNeed(id: id, orderLineID: lineID, name: "\(meal.title) · \(group.name)", amount: Quantity(amount: portion, unit: unit, originalLiteral: quantity.originalLiteral), priority: group.isProtected ? .protected : .required))
                    details.append(PickupNeedDetail(id: id, mealName: meal.title, exclusions: contribution.exclusions, scheduledDay: meal.scheduledDay, leadTimeMinutes: meal.leadTimeMinutes, completedSteps: meal.completedSteps, sourceContributionID: contribution.id, sourceOccurrenceID: meal.id, sourceGroupID: group.id, sourceLedgerRevisionID: shop.revisionID))
                }
                let portion = portions.unassigned
                if portion > .zero {
                    needs.append(AllocationNeed(id: contribution.id, orderLineID: lineID, name: meal.title, amount: Quantity(amount: portion, unit: unit, originalLiteral: quantity.originalLiteral), priority: .required))
                    details.append(PickupNeedDetail(id: contribution.id, mealName: meal.title, exclusions: contribution.exclusions, scheduledDay: meal.scheduledDay, leadTimeMinutes: meal.leadTimeMinutes, completedSteps: meal.completedSteps, sourceContributionID: contribution.id, sourceOccurrenceID: meal.id, sourceGroupID: nil, sourceLedgerRevisionID: shop.revisionID))
                }
            default: break
            }
        }
        return (namedAmount, needs, details)
    }

    @MainActor static func apply(_ review: LedgerCheckoutReview, ledger: LedgerModel, pickup: PickupModel,
                                 freshDinnerBasis: LedgerCanonicalPackStockEvidence.Basis? = nil,
                                 authorize: (@MainActor () -> Bool)? = nil) async throws -> Bool {
        guard authorize?() != false, freshDinnerBasis == nil || (pickup.pantryIsActive && review.previousJourneyRevision == nil)
        else { throw LedgerCheckoutError.staleSource }
        guard ledger.ready, !ledger.saving, !ledger.hasPendingSave, pickup.ready,
              !pickup.saving, !pickup.hasPendingSave else { throw LedgerCheckoutError.staleSource }
        try review.assertCurrent(shop: ledger.shop, workspaceRevision: ledger.revision,
            journey: pickup.journeys.first { $0.id == review.source.id })
        // Capture the original ledger preview before any suspension. Pickup's
        // atomic source submission must compare this to its actual ledger read.
        let reviewedLedger = try PickupModel.CheckoutLedgerBasis(ledger: ledger)
        if pickup.pantryIsActive {
            guard await pickup.refreshPantryStock() else { throw LedgerCheckoutError.staleSource }
        }
        let previous = pickup.journeys.first { $0.id == review.source.id }
        if let freshDinnerBasis {
            guard authorize?() == true, let id = ledger.sourceWorkspaceID, previous == nil,
                  try pickup.quickGroceryPantryContext(ledgerWorkspaceID: id)?.dinnerBasis == freshDinnerBasis
            else { throw LedgerCheckoutError.staleSource }
        }
        try review.assertCurrent(shop: ledger.shop, workspaceRevision: ledger.revision, journey: previous)
        guard ledger.ready, !ledger.saving, !ledger.hasPendingSave,
              pickup.ready, !pickup.saving, !pickup.hasPendingSave else { throw LedgerCheckoutError.staleSource }
        guard previous?.basket?.phase != .reportedPlaced else { throw LedgerCheckoutError.placedOrder }
        let pantryContext = try previous == nil ? nil : pickup.canonicalPackContext(for: review.source.id)
        let current = try self.review(shop: review.source, workspaceRevision: ledger.revision, previous: previous,
            packSelections: pickup.dinnerAuthorizedPacks(ledger.workspace.packSelections, ledger: ledger, shop: review.source), workspaceID: ledger.sourceWorkspaceID,
            pickupWorkspaceID: pickup.sourceWorkspaceID, bindings: ledger.workspace.dinnerPlanning.portionBindings,
            pantryContext: pantryContext, pantryIsActive: pickup.pantryIsActive,
                dinnerWorkspace: ledger.workspace, dinnerActorID: pickup.currentDinnerActorID)
        guard current.lines == review.lines, current.needs == review.needs, current.details == review.details,
              current.packSelections == review.packSelections, current.context == review.context, current.cap == review.cap,
              current.needsApplication == review.needsApplication else { throw LedgerCheckoutError.staleSource }
        guard let ledgerWorkspaceID = ledger.sourceWorkspaceID else { throw LedgerCheckoutError.staleSource }
        let occurrenceIDs = Set(review.source.mealOccurrences.map(\.id))
        let mealSource = PickupCheckoutMealSource(ledgerWorkspaceID: ledgerWorkspaceID, shop: review.source,
            needs: review.sourceNeeds, details: review.details,
            bindings: ledger.workspace.dinnerPlanning.portionBindings.filter { occurrenceIDs.contains($0.occurrenceID) })
        try mealSource.validate()
        if let previous {
            guard previous.basket?.phase != .reportedPlaced else { throw LedgerCheckoutError.placedOrder }
            pickup.selectedID = review.source.id
            if !review.needsApplication {
                if previous.mealSource == mealSource { return true }
                return await pickup.change(reviewedLedger: reviewedLedger) { value in
                    guard value.revision == review.previousJourneyRevision else { throw LedgerCheckoutError.staleCheckout }
                    value.mealSource = mealSource
                }
            }
            return await pickup.change(reviewedLedger: reviewedLedger) { value in
                guard value.revision == review.previousJourneyRevision, var basket = value.basket else { throw LedgerCheckoutError.staleCheckout }
                if let proposal = review.proposal { try basket.apply(proposal, at: Date()) }
                value.basketPriceTerms = .from(review.context, scope: PickupPricingTerms.scope(cap: review.cap, basis: review.source.basis))
                value.basket = basket; value.context = review.context; value.cap = review.cap
                value.plannedNeeds = review.needs; value.needDetails = review.details; value.mealSource = mealSource
                value.ledgerPackSelections = review.packSelections
                value.ledgerBasis = review.source.basis; value.ledgerSourceRevisionID = review.source.revisionID
                value.quote = nil; value.quotedRevisionID = nil
                value.flexible.subtract(review.needs.filter { $0.priority == .protected }.map(\.orderLineID))
            }
        }
        return await pickup.start(from: review.lines, shopID: review.source.id, context: review.context, cap: review.cap,
                                  plannedNeeds: review.needs, ledgerBasis: review.source.basis,
                                  ledgerSourceRevisionID: review.source.revisionID, needDetails: review.details, ledgerPackSelections: review.packSelections, mealSource: mealSource, reviewedLedger: reviewedLedger,
                                  reviewedPantryBasis: freshDinnerBasis, authorize: authorize)
    }

    /// A stable shop ID makes resuming after either store commits retry-safe.
    /// The editable list owns its own fresh contribution IDs. Its next explicit
    /// checkout review reconciles those with the provisional carried basket.
    @MainActor static func openNextShop(_ journey: PickupJourney, ledger: LedgerModel) async -> Bool {
        guard journey.isFreshNextShopDraft, let basket = journey.basket else { return false }
        if !ledger.ready { await ledger.open() }
        guard ledger.ready else { return false }
        return await ledger.change(key: "open-next-shop-\(journey.id.uuidString)") { workspace in
            if !workspace.shops.contains(where: { $0.id == journey.id }) {
                var shop = ShoppingLedger(id: journey.id, title: pTr("Next shop"))
                for line in basket.current.lines { try shop.addManualLine(name: line.name, quantity: line.quantity, exclusions: line.itemExclusions ?? []) }
                workspace.shops.append(shop)
            }
            workspace.selectedShopID = journey.id
        }
    }

    private static func compositeID(_ contribution: UUID, _ group: UUID) -> UUID {
        let digest = SHA256.hash(data: Data("pickup-need:\(contribution.uuidString):\(group.uuidString)".utf8))
        var bytes = Array(digest.prefix(16)); bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

struct LedgerCheckoutEntry: View {
    @ObservedObject var ledger: LedgerModel
    @ObservedObject var pickup: PickupModel
    @State private var opened = false
    @State private var error: String?
    @State private var review: LedgerCheckoutReview?
    @State private var editingFacts = false
    var body: some View {
        Group {
            if opened {
                if pickup.journey?.isAtHomeOnlyPlan == true { LedgerAtHomePlanView(model: pickup) }
                else { PickupHomeView(model: pickup) }
            }
            else if let shop = ledger.shop {
                JournalList {
                    if let proof = shop.initialCheckoutChange {
                        NavigationLink(SavedCheckoutChangeView.title) {
                            SavedCheckoutChangeView(proof: proof, shopID: shop.id)
                        }.accessibilityIdentifier("oneChange.savedReview")
                    }
                    Section {
                        Text(pTr("Review the list for checkout")).marketJournalTitle(.title2)
                        Text(pTr("Review the quantities, protected purposes, store and budget together. Applying clears previous checkout prices."))
                        Button(pTr("Review store, slot and budget")) { editingFacts = true }
                    }
                    Section(pTr("Shopping list")) {
                        let restrictions = shop.listExclusions
                        let handChecked = shop.handCheckedOnlyLineIDs
                        ForEach(shop.lines.filter { !$0.isTrashed && !$0.isHandled }) { line in
                            NavigationLink { LedgerIngredientView(model: ledger, shopID: shop.id, lineID: line.id) } label: {
                                VStack(alignment: .leading) {
                                    Text(line.name)
                                    if review?.deferredLineIDs.contains(line.id) == true {
                                        Text(ledgerText("Deferred to a later shop"))
                                    }
                                    if let exclusion = restrictions[line.id] { Text(verbatim: exclusion) }
                                    let requested = try? shop.quantity(forLineID: line.id)
                                    if handChecked.contains(line.id) {
                                        Text(tonightText("Checked by hand · unmeasured"))
                                        if let pick = line.tripPick {
                                            Text(shelfFormat("Picked · %@", pQuantity(pick.amount)))
                                        }
                                    } else if let summary = shop.packagePickSummary(line) {
                                        Text(summary)
                                        Text(pTr("Quantity unresolved"))
                                    } else if let requested, let pick = line.tripPick,
                                              (try? pick.amount.converted(to: requested.unit)) != requested.amount {
                                        Text(shelfFormat("Requested · %@", pQuantity(requested)))
                                        Text(shelfFormat("Picked · %@", pQuantity(pick.amount)))
                                    } else {
                                        Text(requested.map { pQuantity($0) } ?? pTr("Quantity unresolved"))
                                    }
                                }
                            }.accessibilityIdentifier("checkoutReview.line.\(line.id)")
                        }
                    }
                    if pickup.journeys.contains(where: { $0.id == shop.id }) {
                        Section {
                            Text(pTr("An earlier checkout copy exists. Placed orders retain their original terms."))
                            Button(pTr("Open saved checkout")) { pickup.selectedID = shop.id; opened = true }
                        }
                    }
                    if let review {
                        if let oldBasis = pickup.journeys.first(where: { $0.id == review.source.id })?.ledgerBasis {
                            Section(pTr("Previously reviewed basis")) { basisSummary(oldBasis) }
                        }
                        Section(pTr("Reviewed checkout basis")) {
                            basisSummary(review.source.basis)
                            ForEach(review.needs) { need in
                                Text("\(need.name): \(pQuantity(need.amount)) · \(pTr(need.priority == .protected ? "Protected" : "Required"))")
                            }
                            if !review.unreviewedPackLineIDs.isEmpty {
                                Text(ledgerText("Earlier pack choices need a new review. Their purchased quantities and prices have not been reused."))
                                    .foregroundStyle(Theme.warning)
                                ForEach(review.unreviewedPackLineIDs, id: \.self) { id in
                                    if let line = review.source.lines.first(where: { $0.id == id }) {
                                        NavigationLink(ledgerFormat("Review whole packs for %@", line.name)) {
                                            LedgerIngredientView(model: ledger, shopID: review.source.id, lineID: id)
                                        }
                                    }
                                }
                            }
                            ForEach(review.packSelections) { selection in
                                VStack(alignment: .leading, spacing: 5) {
                                    if selection.isNoPurchase { Text(ledgerText("Use confirmed food at home · no purchase needed")) }
                                    else {
                                        let offer = selection.selectedOfferID == selection.request.offerA.id ? selection.request.offerA : selection.request.offerB
                                        Text(ledgerFormat("Reviewed pack choice: %@", offer.label))
                                        if let basis = offer.confirmedConversion {
                                            DisclosureGroup(tr("Ingredient conversion")) {
                                                Text(ComparisonConversion.readableText(for: basis))
                                            }
                                        }
                                    }
                                    if let stock = selection.request.confirmedAtHome { Text(ledgerFormat("Confirmed at home for this need: %@", ledgerQuantity(stock))) }
                                    if let quantity = selection.purchasedQuantity { Text(ledgerFormat("Purchased usable amount: %@", ledgerQuantity(quantity))) }
                                    if !selection.isNoPurchase, let cost = selection.selectedResult.totalCost { Text(ledgerFormat("Item cost: %@", moneyText(cost))) }
                                    Text("\(selection.source) · \(selection.reviewedAt.formatted())")
                                }
                            }
                            if !review.packSelections.isEmpty { Text(ledgerText("Pack choices supply whole purchased amounts. The named meal needs stay unchanged, and the whole checkout still needs its complete charges.")) }
                            Text(pTr("This review includes source, time zone, fees, reserve, cap scope and named portions, even when the list quantities did not change."))
                            if review.lines.isEmpty && review.needs.isEmpty {
                                Text(ledgerText("Your list has no items to buy. Apply this review to clear the checkout copy."))
                                Button(pTr("Apply reviewed checkout copy")) { Task { await apply(review) } }.buttonStyle(PrimaryAction())
                            } else if review.lines.isEmpty {
                                Text(ledgerText("All list needs are covered by confirmed food at home. Save the plan, then review instructions for the cook."))
                                Button(ledgerText("Save use-at-home plan")) { Task { await apply(review) } }.buttonStyle(PrimaryAction()).accessibilityIdentifier("ledgerSaveAtHomePlan")
                            } else {
                                Button(pTr("Apply reviewed checkout copy")) { Task { await apply(review) } }.buttonStyle(PrimaryAction())
                            }
                            Button(pTr("Cancel preview")) { self.review = nil }
                        }
                    } else {
                        Button(pTr("Continue to checkout review")) { Task { await prepare() } }.buttonStyle(PrimaryAction())
                    }
                    if let error { Text(error).foregroundStyle(Color("error")) }
                    PickupSaveStatus(model: pickup)
                }
                    .disabled(pickup.saving || ledger.saving)
                    .sheet(isPresented: $editingFacts) { NavigationStack { LedgerFactsView(model: ledger, shop: shop) } }
            } else { LedgerHomeView(model: ledger) }
        }.navigationTitle(pTr("Review checkout")).navigationBarTitleDisplayMode(.inline)
            .environment(\.pickupLedger, ledger)
    }
    @ViewBuilder private func basisSummary(_ basis: ShopBasis) -> some View {
        Text(basis.branch.isEmpty ? pTr("Branch unknown · enter before evaluating checkout") : basis.branch)
        Text(basis.mode.ledgerLabel)
        Text(basis.slot.map { ledgerDate($0, zone: basis.timeZoneIdentifier) } ?? pTr("Slot unknown · enter before evaluating checkout"))
        Text("\(pTr("Time zone")): \(basis.timeZoneIdentifier)")
        Text("\(pTr("Spending cap")): \(basis.cap.map(pMoney) ?? pTr("Not provided")) · \(basis.capScope.ledgerLabel)")
        Text(pTr(basis.capFirmness == .firm ? "Firm limit" : "Flexible limit"))
        Text("\(pTr("Known fees from the list")): \(basis.knownFees.map(pMoney) ?? pTr("Unresolved"))")
        Text("\(pTr("Fixed reserve from the list")): \(basis.fixedReserve.map(pMoney) ?? pTr("Not provided"))")
        if let preview = basis.retailerPreview {
            Text("\(preview.source) · \(preview.capturedAt.formatted())")
            Text("\(pTr("Retailer preview total")): \(preview.total.map(pMoney) ?? pTr("Unresolved"))")
            Text("\(pTr("Charges marked included")): \(preview.includedCharges.joined(separator: ", "))")
        }
    }
    @MainActor private func prepare() async {
        await pickup.load()
        guard let shop = ledger.shop else { return }
        do {
            if pickup.pantryIsActive {
                guard await pickup.refreshPantryStock() else { throw LedgerCheckoutError.staleSource }
            }
            guard ledger.ready, !ledger.saving, !ledger.hasPendingSave, ledger.shop == shop else {
                throw LedgerCheckoutError.staleSource
            }
            let previous = pickup.journeys.first { $0.id == shop.id }
            let pantryContext = try previous == nil ? nil : pickup.canonicalPackContext(for: shop.id)
            let value = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: ledger.revision, previous: previous,
                packSelections: pickup.dinnerAuthorizedPacks(ledger.workspace.packSelections, ledger: ledger, shop: shop), workspaceID: ledger.sourceWorkspaceID,
                pickupWorkspaceID: pickup.sourceWorkspaceID, bindings: ledger.workspace.dinnerPlanning.portionBindings,
                pantryContext: pantryContext, pantryIsActive: pickup.pantryIsActive,
                dinnerWorkspace: ledger.workspace, dinnerActorID: pickup.currentDinnerActorID)
            if !value.needsApplication { pickup.selectedID = shop.id; opened = true }
            else if pickup.journeys.first(where: { $0.id == shop.id })?.basket?.phase == .reportedPlaced {
                error = pTr("This order was reported placed. Its original lines and terms remain locked; review retailer-confirmed amendments separately.")
            } else { review = value; error = nil }
        } catch LedgerCheckoutError.changedDeferredLine(let name) {
            self.error = ledgerFormat("%@ changed on the list after it was deferred. Open the saved checkout and undo its deferral before reviewing these changes.", name)
        } catch LedgerCheckoutError.emptyList {
            self.error = ledgerText("Your list has no items to buy.")
        } catch { self.error = pTr("Review quantities, units and named portions. Unknown or overallocated amounts have not been replaced with zero.") }
    }
    @MainActor private func apply(_ review: LedgerCheckoutReview) async {
        do {
            if try await LedgerCheckoutAdapter.apply(review, ledger: ledger, pickup: pickup) { self.review = nil; opened = true; error = nil }
            else { error = pickup.error }
        } catch LedgerCheckoutError.staleSource {
            self.review = nil; self.error = pTr("The shopping list or its store, budget or purposes changed after this review. Review the current source again.")
        } catch {
            self.review = nil; self.error = pTr("The saved checkout changed after this review. Reopen it and review the current version.")
        }
    }
}


struct PickupListBridgeView: View {
    @ObservedObject var model: PickupModel
    @ObservedObject var ledger: LedgerModel
    let journeyID: UUID
    var reviewStaples = false
    @State private var opened = false
    var body: some View {
        Group {
            if opened {
                if reviewStaples { StapleRecallView(ledger: ledger, targetID: journeyID) }
                else { LedgerHomeView(model: ledger) }
            }
            else {
                WorkingForm {
                    LedgerSaveStatus(model: ledger)
                    Text(pTr("The next-shop draft is saved. Open its editable shopping list; old prices and order status will not carry over."))
                    Button(pTr("Open saved next shopping list")) { Task { await open() } }
                        .disabled(ledger.saving || ledger.hasPendingSave)
                }
            }
        }.navigationTitle(pTr("Next shop"))
            .task { await open() }
    }
    private func open() async {
        guard let journey = model.journeys.first(where: { $0.id == journeyID }) else { return }
        opened = await LedgerCheckoutAdapter.openNextShop(journey, ledger: ledger)
    }
}
