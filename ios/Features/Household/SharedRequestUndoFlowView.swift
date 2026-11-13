import SwiftUI
import HouseholdClient

struct SharedRequestUndoShopView: View {
    @ObservedObject var owner: HouseholdShopModel
    @StateObject private var flow: SharedRequestUndoFlowModel
    let target: SharedDemandID?
    init(owner: HouseholdShopModel, target: SharedDemandID? = nil) {
        self.owner = owner; self.target = target; _flow = StateObject(wrappedValue: .init(access: owner))
    }
    var body: some View {
        SharedRequestUndoFlowView(model: flow, target: target, authorized: owner.trackingAllowed, lease: owner.trackingLease, shop: owner.shop)
    }
}
struct SharedRequestUndoInboxView: View {
    @ObservedObject var owner: HouseholdInboxModel
    @StateObject private var flow: SharedRequestUndoFlowModel
    init(owner: HouseholdInboxModel) { self.owner = owner; _flow = StateObject(wrappedValue: .init(access: owner)) }
    var body: some View { SharedRequestUndoFlowView(model: flow, target: nil, authorized: owner.trackingAllowed, lease: owner.trackingLease, shop: owner.shop) }
}
private struct SharedRequestUndoFlowView: View {
    @ObservedObject var model: SharedRequestUndoFlowModel
    let target: SharedDemandID?
    let authorized: Bool
    let lease: UUID
    let shop: ShopperShop?
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var resultFocused: Bool
    var body: some View {
        WorkingForm {
            if authorized {
                if let candidate = model.review?.response.candidate ?? model.candidate, model.permitted {
                    review(candidate)
                } else if !model.pending && !model.submitted {
                    Section {
                        Text(ru("Undo restores the exact accepted request outcome and link together with its complete basket and food changes. Later unrelated facts remain."))
                    }
                    ForEach(model.history, id: \.operationId) { item in
                        Section {
                            Text(householdTime(item.committedAt))
                            LabeledContent(st("Shop revision"), value: String(item.shopRevision))
                            if item.eligibility.status == .reviewable {
                                Button(ru("Review complete request Undo")) { Task { await model.select(item.operationId) } }
                                    .accessibilityIdentifier("requestUndo.target." + item.operationId.string)
                            } else { Text(ru("This acceptance cannot currently be undone. No historical facts were restored.")) }
                        }
                    }
                    if model.next != nil { Button(ru("Earlier request acceptances")) { Task { await model.load(more: true) } } }
                    Button(st("Refresh current facts")) { Task { await model.load() } }
                }
                if model.pending { Text(st("Not confirmed. Return to the shop and retry the exact saved action.")) }
                if let notice = model.notice { Text(notice).accessibilityIdentifier("requestUndo.result").accessibilityFocused($resultFocused) }
                if model.busy { ProgressView(ru("Checking complete request change…")) }
            } else { Text(st("Shared access ended. Return to the household.")) }
        }
        .navigationTitle(ru("Accepted request changes"))
        .scrollDismissesKeyboard(.interactively)
        .disabled(model.busy)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(st("Cancel")) { model.clear(); dismiss() } } }
        .task { await model.load(target: target) }
        .onDisappear { model.clear() }
        .onChange(of: authorized) { _, allowed in if !allowed { model.clear() } }
        .onChange(of: lease) { _, _ in model.clear() }
        .onChange(of: shop) { _, _ in model.clear() }
        .onChange(of: model.notice) { _, value in resultFocused = value != nil }
    }
    @ViewBuilder private func review(_ candidate: SharedRequestUndoCandidate) -> some View {
        Section(ru("Request outcome and exact link")) {
            Text(candidate.requestUndo.originalItem).font(.headline)
            LabeledContent(st("Original quantity wording"), value: candidate.requestUndo.originalQuantityText ?? st("Unknown"))
            LabeledContent(st("Exact target operation"), value: candidate.targetOperationId.string)
            LabeledContent(st("Request identity"), value: candidate.requestUndo.requestId.string)
            Text(ru(candidate.requestUndo.choice == .add ? "Original decision: add packs" : "Original decision: link existing packs"))
            requestState(ru("Before the original acceptance"), candidate.requestUndo.targetBefore)
            requestState(ru("After the original acceptance"), candidate.requestUndo.targetAfter)
            requestState(ru("Current request"), candidate.requestUndo.current)
            requestState(ru("Restored request"), candidate.requestUndo.restored)
            LabeledContent(ru("Link being removed"), value: candidate.requestUndo.beforeLink.lineId.string)
            LabeledContent(st("Accepted request revision"), value: String(candidate.requestUndo.beforeLink.reviewedRevision))
            Text(ru("The accepted link will be removed; no replacement link is created."))
            if candidate.scope.firstAdoptionReversed { Text(ru("This also reverses the complete initial food adoption, including its manual assertions, relationships and mappings.")) }
            ForEach(candidate.requestUndo.carry, id: \.operationId) { carry in
                LabeledContent(ru("Original carry source shop"), value: carry.sourceShopId.string)
                LabeledContent(ru("Original carry source request"), value: carry.sourceRequestId.string)
                LabeledContent(ru("Original carry target shop"), value: carry.targetShopId.string)
                LabeledContent(ru("Original carry target request"), value: carry.targetRequestId.string)
            }
        }
        if let shop = model.shop { Section(st("Before basket and quote")) { SharedShopFields(quote: shop.quote, lines: shop.lines) } }
        Section(st("After")) { SharedShopFields(quote: candidate.action.body.quote, lines: candidate.action.body.lines) }
        Section(ru("Complete checkout comparison")) {
            ShopperBudgetView(title: st("Before"), value: candidate.beforeCheckout)
            ShopperBudgetView(title: st("After"), value: candidate.afterCheckout)
            Text(ru("The quote terms stay unchanged. Removing or restoring items can still change the checkout total and fee."))
        }
        food(candidate.foodBefore, title: ru("Food before Undo"))
        food(candidate.foodAfter, title: ru("Food after Undo"))
        Section(ru("Every remaining basket item")) {
            Text(ru("Review every remaining whole pack. Unknown legacy food stays untracked even when a usable amount is entered."))
            ForEach(model.packs) { entry in
                let binding = model.pack(entry.id)
                Text(entry.name).font(.headline)
                Toggle(st("Quantity unknown"), isOn: binding.usable.unknown)
                if !entry.usable.unknown {
                    TextField(st("Amount numerator"), text: binding.usable.numerator).keyboardType(.numberPad)
                    TextField(st("Amount denominator"), text: binding.usable.denominator).keyboardType(.numberPad)
                    Picker(st("Unit"), selection: binding.usable.unit) {
                        ForEach(SharedDemandUnit.allCases, id: \.self) { Text(SharedDemandCopy.unit($0)).tag($0) }
                    }
                }
                Toggle(st("I accept unresolved quantities or restrictions for this item"), isOn: binding.acceptUnresolved)
                    .accessibilityIdentifier("requestUndo.pack." + entry.id.string)
            }
        }
        Section {
            if candidate.afterCheckout.status == "overCap" {
                Toggle(ru("I accept the displayed checkout overage"), isOn: $model.acceptOverage).accessibilityIdentifier("requestUndo.acceptOverage")
            }
            if ["unresolved", "scopeMismatch"].contains(candidate.afterCheckout.status) || candidate.afterCheckout.scope != "wholeCheckout" {
                Toggle(ru("I accept the displayed unknown costs or limited checkout scope"), isOn: $model.acceptUnknown).accessibilityIdentifier("requestUndo.acceptUnknown")
            }
            Toggle(st("I reviewed every change, retained identity and protected commitment"), isOn: $model.gate.changes)
            Toggle(st("I reviewed the whole pickup, unbound commitments, unknowns, prices and whole packs"), isOn: $model.gate.pickup)
            if let review = model.review {
                LabeledContent(st("Review expires"), value: householdTime(review.response.expiresAt))
                Button(ru("Apply complete request Undo once")) { Task { await model.apply() } }
                    .disabled(!model.gate.canApply || !model.moneyAccepted).accessibilityIdentifier("requestUndo.apply")
                Button(st("Edit again")) { model.editAgain() }
            } else {
                Button(ru("Prepare exact request Undo review")) { Task { await model.preview() } }
                    .disabled(!model.gate.canApply || !model.moneyAccepted).accessibilityIdentifier("requestUndo.preview")
            }
        }
    }
    @ViewBuilder private func requestState(_ title: String, _ state: SharedRequestUndoState) -> some View {
        Text(title).font(.headline)
        LabeledContent(st("Request revision"), value: String(state.revision))
        Text(ru(state.status == .pending ? "Pending" : state.status == .clarified ? "Clarified" : state.status == .deferred ? "Deferred" : "Added"))
        Text(ru(state.route == .current ? "This pickup" : "Next pickup"))
    }
    @ViewBuilder private func food(_ food: SharedRequestUndoFood, title: String) -> some View {
        switch food {
        case .legacy(let catalog):
            Section(title) {
                Text(ru("Legacy food remains untracked; quantities and available supply are not inferred."))
                ForEach(catalog, id: \.id) { SharedTrackingFacts.factFacts($0) }
            }
        case .tracked(let graph): SharedTrackingFacts.graphFacts(graph, title: title)
        case .partition(let state):
            SharedTrackingFacts.graphFacts(state.graph, title: title)
            Section(ru("Complete bound and unbound partition")) {
                Text(st("Tracked subtotals are not complete household coverage. Unbound food is never available supply."))
                ForEach(state.catalog, id: \.id) { fact in
                    SharedTrackingFacts.factFacts(fact)
                    if let transfer = state.unbound.first(where: { $0.factId == fact.id }) {
                        Text(st("Unbound · not available supply"))
                        if let source = transfer.transferred { SharedTrackingFacts.contribution(source) }
                    } else { Text(st("Bound to tracked food")) }
                }
                ForEach(state.packReviews, id: \.lineId) { pack in
                    Text(state.basket.first { $0.id == pack.lineId }?.name ?? pack.lineId.string)
                    Text(SharedDemandCopy.quantity(pack.usablePerPack))
                    if let quantity = pack.usablePerPack { SharedTrackingFacts.conversion(quantity) }
                }
                SharedTrackingFacts.identifiers(st("Untracked basket items"), state.legacyLineIds, state: state)
            }
        }
    }
}
