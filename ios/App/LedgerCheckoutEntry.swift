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

enum LedgerCheckoutError: Error, Equatable {
    case missingQuantity, emptyList, ambiguousServingGroups, staleSource, staleCheckout, placedOrder
}

struct LedgerCheckoutReview {
    let source: ShoppingLedger
    let workspaceRevision: Int64
    let previousJourneyRevision: Int64?
    let previousBasketRevision: UUID?
    let lines: [BasketLine]
    let needs: [AllocationNeed]
    let details: [PickupNeedDetail]
    let packSelections: [LedgerPackSelection]
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
                       packSelections: [LedgerPackSelection] = [], workspaceID: UUID? = nil) throws -> LedgerCheckoutReview {
        try shop.validate()
        let activeLines = shop.lines.filter { !$0.isTrashed && !$0.isHandled }
        guard !activeLines.isEmpty else { throw LedgerCheckoutError.emptyList }
        let sameBasis = previous?.ledgerBasis == shop.basis
        var selectedPacks: [UUID: LedgerPackSelection] = [:]
        for selection in packSelections where selection.shopID == shop.id {
            try selection.validateReference(in: shop)
            if let workspaceID, try selection.isCurrent(in: shop, workspaceID: workspaceID) { selectedPacks[selection.lineID] = selection }
        }
        let priorPackLineIDs = Set(previous?.ledgerPackSelections.map(\.lineID) ?? [])
        let lines = try activeLines.map { line -> BasketLine in
            guard let quantity = try shop.quantity(forLineID: line.id) else { throw LedgerCheckoutError.missingQuantity }
            if let selection = selectedPacks[line.id], let purchased = selection.purchasedQuantity, let price = selection.selectedResult.totalCost {
                return BasketLine(id: line.id, name: line.name, quantity: purchased, expectedCost: .exact(price))
            }
            let old = previous?.basket?.current.lines.first { $0.id == line.id && $0.name == line.name && $0.quantity == quantity }
            return BasketLine(id: line.id, name: line.name, quantity: quantity,
                              expectedCost: sameBasis && !priorPackLineIDs.contains(line.id) ? old?.expectedCost ?? .unknown(reason: pTr("Recheck the price for this shop")) : .unknown(reason: pTr("Recheck the price for this shop")))
        }
        var needs: [AllocationNeed] = [], details: [PickupNeedDetail] = []
        for line in lines {
            guard let sourceQuantity = try shop.quantity(forLineID: line.id), let sourceAmount = try sourceQuantity.converted(to: line.quantity.unit) else { throw LedgerCheckoutError.missingQuantity }
            var namedAmount = Rational.zero
            for contribution in shop.contributions(forLineID: line.id) {
                guard contribution.source.isMeal || contribution.source.isProtected else { continue }
                guard let quantity = contribution.quantity, let amount = try quantity.converted(to: line.quantity.unit) else { throw LedgerCheckoutError.missingQuantity }
                namedAmount = try namedAmount.adding(amount)
                let normalized = Quantity(amount: amount, unit: line.quantity.unit, originalLiteral: quantity.originalLiteral)
                switch contribution.source {
                case let .protectedNeed(purpose):
                    needs.append(AllocationNeed(id: contribution.id, orderLineID: line.id, name: purpose, amount: normalized, priority: .protected))
                    details.append(PickupNeedDetail(id: contribution.id, mealName: purpose, exclusions: contribution.exclusions, scheduledDay: nil, leadTimeMinutes: nil, completedSteps: []))
                case let .meal(occurrenceID):
                    guard let meal = shop.mealOccurrences.first(where: { $0.id == occurrenceID && $0.removedAt == nil }) else { throw LedgerCheckoutError.staleSource }
                    var usedServings = Rational.zero
                    for group in meal.servingGroups {
                        usedServings = try usedServings.adding(group.servings)
                        guard usedServings <= meal.servings else { throw LedgerCheckoutError.ambiguousServingGroups }
                        let portion = try amount.multiplied(by: group.servings.divided(by: meal.servings))
                        let id = compositeID(contribution.id, group.id)
                        needs.append(AllocationNeed(id: id, orderLineID: line.id, name: "\(meal.title) · \(group.name)", amount: Quantity(amount: portion, unit: line.quantity.unit, originalLiteral: quantity.originalLiteral), priority: group.isProtected ? .protected : .required))
                        details.append(PickupNeedDetail(id: id, mealName: meal.title, exclusions: contribution.exclusions, scheduledDay: meal.scheduledDay, leadTimeMinutes: meal.leadTimeMinutes, completedSteps: meal.completedSteps))
                    }
                    let remainingServings = try meal.servings.subtracting(usedServings)
                    if remainingServings > .zero {
                        let portion = try amount.multiplied(by: remainingServings.divided(by: meal.servings))
                        needs.append(AllocationNeed(id: contribution.id, orderLineID: line.id, name: meal.title, amount: Quantity(amount: portion, unit: line.quantity.unit, originalLiteral: quantity.originalLiteral), priority: .required))
                        details.append(PickupNeedDetail(id: contribution.id, mealName: meal.title, exclusions: contribution.exclusions, scheduledDay: meal.scheduledDay, leadTimeMinutes: meal.leadTimeMinutes, completedSteps: meal.completedSteps))
                    }
                default: break
                }
            }
            guard namedAmount <= sourceAmount else { throw LedgerCheckoutError.ambiguousServingGroups }
            // Unassigned manual/import quantities remain one separate purpose.
            // Twelve typed wraps with 6 + 4 + 2 linked portions have no residual.
            let remainder = try sourceAmount.subtracting(namedAmount)
            if remainder > .zero {
                needs.append(AllocationNeed(id: line.id, orderLineID: line.id, name: line.name, amount: Quantity(amount: remainder, unit: line.quantity.unit, originalLiteral: line.quantity.originalLiteral), priority: .required))
                details.append(PickupNeedDetail(id: line.id, mealName: line.name, exclusions: shop.contributions(forLineID: line.id).flatMap(\.exclusions), scheduledDay: nil, leadTimeMinutes: nil, completedSteps: []))
            }
        }
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
        let unchanged = previous?.ledgerSourceRevisionID == shop.revisionID && sameBasis && previous?.basket?.current.lines == lines && previous?.plannedNeeds == needs && previous?.needDetails == details && previous?.ledgerPackSelections == currentPacks && previous?.context == context && previous?.cap == cap
        let proposal: BasketProposal?
        if let basket = previous?.basket, !unchanged {
            var changes = lines.filter { line in basket.current.lines.first(where: { $0.id == line.id }) != line }.map(BasketChange.upsert)
            changes += basket.current.lines.filter { old in !lines.contains(where: { $0.id == old.id }) }.map { .remove($0.id) }
            // Basis-only and purpose-only reviews still make a fresh revision,
            // so an old frozen snapshot cannot stand for newly reviewed terms.
            if changes.isEmpty { changes = lines.map(BasketChange.upsert) }
            proposal = BasketProposal(id: UUID(), baseRevisionID: basket.current.id, revisionID: UUID(), changes: changes)
        } else { proposal = nil }
        return LedgerCheckoutReview(source: shop, workspaceRevision: workspaceRevision,
            previousJourneyRevision: previous?.revision, previousBasketRevision: previous?.basket?.current.id,
            lines: lines, needs: needs, details: details, packSelections: currentPacks, context: context, cap: cap, proposal: proposal, needsApplication: !unchanged)
    }

    @MainActor static func apply(_ review: LedgerCheckoutReview, ledger: LedgerModel, pickup: PickupModel) async throws -> Bool {
        let previous = pickup.journeys.first { $0.id == review.source.id }
        try review.assertCurrent(shop: ledger.shop, workspaceRevision: ledger.revision, journey: previous)
        guard !ledger.saving, !ledger.hasPendingSave, pickup.ready else { throw LedgerCheckoutError.staleSource }
        if let previous {
            guard previous.basket?.phase != .reportedPlaced else { throw LedgerCheckoutError.placedOrder }
            pickup.selectedID = review.source.id
            if !review.needsApplication { return true }
            return await pickup.change { value in
                guard value.revision == review.previousJourneyRevision, var basket = value.basket else { throw LedgerCheckoutError.staleCheckout }
                if let proposal = review.proposal { try basket.apply(proposal, at: Date()) }
                value.basket = basket; value.context = review.context; value.cap = review.cap
                value.plannedNeeds = review.needs; value.needDetails = review.details
                value.ledgerPackSelections = review.packSelections
                value.ledgerBasis = review.source.basis; value.ledgerSourceRevisionID = review.source.revisionID
                value.quote = nil; value.quotedRevisionID = nil
                value.flexible.subtract(review.needs.filter { $0.priority == .protected }.map(\.orderLineID))
            }
        }
        return await pickup.start(from: review.lines, shopID: review.source.id, context: review.context, cap: review.cap,
                                  plannedNeeds: review.needs, ledgerBasis: review.source.basis,
                                  ledgerSourceRevisionID: review.source.revisionID, needDetails: review.details, ledgerPackSelections: review.packSelections)
    }

    /// A stable shop ID makes resuming after either store commits retry-safe.
    /// The editable list owns its own fresh contribution IDs. Its next explicit
    /// checkout review reconciles those with the provisional carried basket.
    @MainActor static func openNextShop(_ journey: PickupJourney, ledger: LedgerModel) async -> Bool {
        guard journey.originShopID != nil, let basket = journey.basket, basket.phase == .draft, journey.context == nil,
              journey.quote == nil, journey.pickup == nil else { return false }
        if !ledger.ready { await ledger.open() }
        guard ledger.ready else { return false }
        return await ledger.change(key: "open-next-shop-\(journey.id.uuidString)") { workspace in
            if !workspace.shops.contains(where: { $0.id == journey.id }) {
                var shop = ShoppingLedger(id: journey.id, title: pTr("Next shop"))
                for line in basket.current.lines { try shop.addManualLine(name: line.name, quantity: line.quantity) }
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
            if opened { PickupHomeView(model: pickup) }
            else if let shop = ledger.shop {
                List {
                    Section {
                        Text(pTr("Review the list for checkout")).font(.title2.bold())
                        Text(pTr("Review the quantities, protected purposes, store and budget together. Applying clears previous checkout prices."))
                        Button(pTr("Review store, slot and budget")) { editingFacts = true }
                    }
                    Section(pTr("Shopping list")) {
                        ForEach(shop.lines.filter { !$0.isTrashed && !$0.isHandled }) { line in
                            NavigationLink { LedgerIngredientView(model: ledger, shopID: shop.id, lineID: line.id) } label: {
                                VStack(alignment: .leading) {
                                    Text(line.name)
                                    Text((try? shop.quantity(forLineID: line.id)).map { pQuantity($0) } ?? pTr("Quantity unresolved"))
                                }
                            }
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
                            ForEach(review.packSelections) { selection in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(ledgerFormat("Reviewed pack choice: %@", selection.selectedOfferID == selection.request.offerA.id ? selection.request.offerA.label : selection.request.offerB.label))
                                    if let quantity = selection.purchasedQuantity { Text(ledgerFormat("Purchased usable amount: %@", ledgerQuantity(quantity))) }
                                    if let cost = selection.selectedResult.totalCost { Text(ledgerFormat("Item cost: %@", moneyText(cost))) }
                                    Text("\(selection.source) · \(selection.reviewedAt.formatted())")
                                }
                            }
                            if !review.packSelections.isEmpty { Text(ledgerText("Pack choices supply whole purchased amounts. The named meal needs stay unchanged, and the whole checkout still needs its complete charges.")) }
                            Text(pTr("This review includes source, time zone, fees, reserve, cap scope and named portions, even when the list quantities did not change."))
                            Button(pTr("Apply reviewed checkout copy")) { Task { await apply(review) } }.buttonStyle(PrimaryAction())
                            Button(pTr("Cancel preview")) { self.review = nil }
                        }
                    } else {
                        Button(pTr("Continue to checkout review")) { Task { await prepare() } }.buttonStyle(PrimaryAction())
                    }
                    if let error { Text(error).foregroundStyle(Color("error")) }
                    PickupSaveStatus(model: pickup)
                }.workingSurface()
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
            let value = try LedgerCheckoutAdapter.review(shop: shop, workspaceRevision: ledger.revision, previous: pickup.journeys.first { $0.id == shop.id }, packSelections: ledger.workspace.packSelections, workspaceID: ledger.sourceWorkspaceID)
            if !value.needsApplication { pickup.selectedID = shop.id; opened = true }
            else if pickup.journeys.first(where: { $0.id == shop.id })?.basket?.phase == .reportedPlaced {
                error = pTr("This order was reported placed. Its original lines and terms remain locked; review retailer-confirmed amendments separately.")
            } else { review = value; error = nil }
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
    @State private var opened = false
    var body: some View {
        Group {
            if opened { LedgerHomeView(model: ledger) }
            else {
                Form {
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
