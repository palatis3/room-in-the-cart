import SwiftUI
import HouseholdClient

private struct UndoPackEntry: Equatable {
    var amount = SharedFoodAmountDraft()
    var acceptUnresolved = false
}
struct SharedOperationUndoView: View {
    @ObservedObject private var shopModel: HouseholdShopModel
    @StateObject private var model: SharedOperationUndoModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SharedDemandID: UndoPackEntry] = [:]
    @State private var entryGeneration = UUID()
    @State private var entryError = false
    @State private var submitted = false
    @FocusState private var editing: String?
    init(shopModel: HouseholdShopModel) {
        self.shopModel = shopModel
        _model = StateObject(wrappedValue: SharedOperationUndoModel(access: shopModel))
    }
    var body: some View {
        WorkingForm {
            if !shopModel.canReadFood && !model.busy {
                Text(u("Access to this shop ended."))
            } else if model.pending {
                Section { Text(u("This change is waiting for confirmation. Return to the shop to retry the same saved action.")) }
            } else if let candidate = model.candidate, let shop = model.currentShop {
                candidateContent(candidate, shop: shop)
            } else {
                Section {
                    Text(u("Review a saved item, quote or meal change before undoing it. Later changes that still fit will remain."))
                        .accessibilityIdentifier(model.currentShop == nil ? "sharedUndo.intro" : "sharedUndo.loaded")
                    Text(u("New meals, starting shared food tracking, request decisions and store changes cannot be undone here."))
                }
                ForEach(model.history, id: \.operationId) { item in
                    Section {
                        Text(u(item.kind == .patch ? "Shop change" : "Request decision")).font(.headline)
                        Text(householdTime(item.committedAt))
                        if item.eligibility.status == .reviewable {
                            Button(u("Review undo")) { Task { await model.select(item) } }
                                .disabled(model.busy || shopModel.busy)
                                .accessibilityIdentifier("sharedUndo.history." + item.operationId.string)
                        } else {
                            Text(SharedOperationUndoCopy.unavailable(item.eligibility.reason))
                                .accessibilityIdentifier("sharedUndo.unavailable." + item.operationId.string)
                        }
                    }
                }
                if model.nextBeforeRevision != nil { Button(u("Earlier changes")) { Task { await model.loadMore() } }.disabled(model.busy) }
                if model.history.isEmpty && !model.busy { Text(u("No saved changes to review.")) }
            }
            if model.failed { Text(u("This review is no longer available. Refresh the shop and try again.")).accessibilityIdentifier("sharedUndo.stale") }
            if entryError { Text(u("Review a usable amount or accept the unknowns for every remaining item.")).accessibilityIdentifier("sharedUndo.entryError") }
            if model.busy { ProgressView(u("Checking saved changes…")) }
            if model.candidate == nil && !model.pending { Button(u("Refresh saved changes")) { clearEntries(); Task { await model.load() } }.disabled(model.busy) }
            if model.pending { Button(u("Return to shop")) { model.cancel(); clearEntries(); dismiss() }.accessibilityIdentifier("sharedUndo.return") }
        }
        .navigationTitle(u(model.candidate == nil ? "Saved changes" : "Review undo"))
        .keyboardDoneAction(visible: editing != nil, title: SharedDemandCopy.text("Done"), identifier: "sharedUndo.done") { editing = nil }
        .scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button(u("Cancel")) { model.cancel(); clearEntries(); dismiss() }
                .disabled(model.isApplying).accessibilityIdentifier("sharedUndo.cancel")
        } }
        .task { await model.load() }
        .onDisappear { model.cancel(); clearEntries() }
        .onChange(of: shopModel.operationUndoIdentity) { _, _ in model.accessChanged(); clearIfDiscarded() }
        .onChange(of: shopModel.foodShop) { _, _ in model.accessChanged(); clearIfDiscarded() }
        .onChange(of: shopModel.foodPending) { _, _ in model.accessChanged(); clearIfDiscarded() }
        .onChange(of: model.candidate?.targetOperationId) { _, _ in clearEntries() }
        .onChange(of: model.failed) { _, value in if value { submitted = false } }
        .onChange(of: shopModel.delivery) { _, value in
            if submitted, case .confirmed = value { model.cancel(); clearEntries(); dismiss() }
        }
    }
    private func u(_ key: String) -> String { SharedOperationUndoCopy.text(key) }
    private func clearEntries() { entries = [:]; entryGeneration = UUID(); entryError = false; editing = nil }
    private func clearIfDiscarded() { if model.candidate == nil { clearEntries() } }
    private func entry(_ id: SharedDemandID, unit: SharedDemandUnit) -> Binding<UndoPackEntry> {
        var empty = UndoPackEntry(); empty.amount.unit = unit
        let fallback = empty, generation = entryGeneration
        return Binding(get: { generation == entryGeneration ? entries[id] ?? fallback : fallback }, set: { value in
            guard generation == entryGeneration, !model.busy, !model.isApplying, model.candidate?.packReviewLineIds.contains(id) == true else { return }
            entries[id] = value; entryError = false; model.editReview()
        })
    }
    @ViewBuilder private func candidateContent(_ candidate: SharedOperationUndoCandidate, shop: ShopperShop) -> some View {
        let after = model.review?.response.preview.after ?? candidate.after
        Section {
            Text(u("Review the complete result below. Cancel leaves the shop unchanged."))
            if candidate.scope.quoteChanged { Text(u("The earlier quote will be restored.")) }
        }
        if let meal = candidate.mealUndo {
            Section(u("Meal before")) {
                if let current = meal.current.meal { SharedMealFacts(meal: current, deadlineIdentifier: "sharedUndo.meal.before.deadline") }
                else { Text(u("This meal is currently skipped.")).accessibilityIdentifier("sharedUndo.meal.before.absent") }
            }
            Section(u("Meal after")) {
                SharedMealFacts(meal: meal.restoredMeal, deadlineIdentifier: "sharedUndo.meal.after.deadline")
                ForEach(meal.touchedFields, id: \.self) { Text(SharedOperationUndoCopy.mealField($0)) }
                Text(u("Other current meal details stay unchanged. Protected food remains reserved."))
            }
        }
        Section(u("Items and quote before")) { SharedShopFields(quote: shop.quote, lines: shop.lines) }
        Section(u("Items and quote after")) { SharedShopFields(quote: candidate.action.body.quote, lines: candidate.action.body.lines) }
        Section(u("Checkout before and after")) {
            budget(candidate.beforeCheckout, label: u("Before"))
            budget(candidate.afterCheckout, label: u("After"))
        }
        Section(u("Food before")) { food(candidate.before, totals: candidate.beforeTotals, prefix: "before") }
        Section(u("Food after")) { food(after, totals: candidate.afterTotals, prefix: "after") }
        if let review = model.review {
            Section(u("Reviewed usable amounts")) {
                ForEach(review.request.packs, id: \.lineId) { pack in
                    Text(candidate.action.body.lines.first { $0.lineId == pack.lineId.string }?.originalItem ?? u("Item")).font(.headline)
                    Text(SharedDemandCopy.quantity(pack.usablePerPack))
                    if pack.acceptUnresolved { Text(u("Unknown quantities or restrictions accepted for this item.")) }
                }
            }
            Section {
                LabeledContent(u("Review expires"), value: householdTime(review.response.preview.expiresAt))
                Toggle(u("I reviewed the food, packs and checkout changes"), isOn: $model.monetaryAcknowledged)
                    .disabled(model.busy || shopModel.busy).accessibilityIdentifier("sharedUndo.acknowledged")
                Button(u("Undo this change")) { submitted = true; Task { await model.apply() } }
                    .disabled(!model.monetaryAcknowledged || model.busy || shopModel.busy).accessibilityIdentifier("sharedUndo.apply")
                Button(u("Edit usable amounts")) { model.editReview() }.disabled(model.busy).accessibilityIdentifier("sharedUndo.editAmounts")
            }
        } else {
            Section(u("Usable food in each pack")) {
                Text(u("Confirm each remaining item's usable amount now. Pack counts do not tell us how much food is usable."))
                ForEach(candidate.packReviewLineIds, id: \.self) { id in
                    let unit = after.lines.first { $0.id == id }?.unit ?? .count
                    let value = entry(id, unit: unit), prefix = "sharedUndo.pack." + id.string
                    Text(candidate.action.body.lines.first { $0.lineId == id.string }?.originalItem ?? u("Item")).font(.headline)
                    Toggle(SharedDemandCopy.text("Quantity unknown"), isOn: value.amount.unknown).accessibilityIdentifier(prefix + ".unknown")
                    if !value.wrappedValue.amount.unknown {
                        workingTextField(SharedDemandCopy.text("Amount, decimal or fraction"), text: value.amount.literal)
                            .keyboardType(.numbersAndPunctuation).focused($editing, equals: prefix).accessibilityIdentifier(prefix + ".amount")
                        units(SharedDemandCopy.text("Unit"), value.amount.unit).accessibilityIdentifier(prefix + ".unit")
                        Toggle(SharedDemandCopy.text("Use a confirmed conversion between different kinds of units"), isOn: value.amount.useConversion)
                        if value.wrappedValue.amount.useConversion {
                            units(SharedDemandCopy.text("Conversion target unit"), value.amount.conversionUnit).accessibilityIdentifier(prefix + ".conversionUnit")
                            workingTextField(SharedDemandCopy.text("Target amount for one source unit"), text: value.amount.conversionRate).keyboardType(.numbersAndPunctuation).focused($editing, equals: prefix + ".rate")
                            workingTextField(SharedDemandCopy.text("Conversion evidence"), text: value.amount.conversionNote).focused($editing, equals: prefix + ".note")
                            Text(SharedDemandCopy.text("Only use a conversion you have confirmed for this food. No density is assumed."))
                        }
                    }
                    Toggle(u("I accept unresolved quantities or restrictions for this item"), isOn: value.acceptUnresolved).accessibilityIdentifier(prefix + ".acceptUnknown")
                }
            }.disabled(model.busy || shopModel.busy)
            Section { Button(u("Review final result")) { preview(candidate) }.disabled(model.busy || shopModel.busy).accessibilityIdentifier("sharedUndo.preview") }
        }
    }
    private func preview(_ candidate: SharedOperationUndoCandidate) {
        do {
            for id in candidate.packReviewLineIds {
                let input = entries[id] ?? UndoPackEntry()
                try model.acknowledgePack(.init(lineId: id, usablePerPack: input.amount.quantity(), acceptUnresolved: input.acceptUnresolved))
            }
            editing = nil; entryError = false; Task { await model.preview() }
        } catch { entryError = true }
    }
    private func units(_ title: String, _ value: Binding<SharedDemandUnit>) -> some View {
        Picker(title, selection: value) { ForEach(SharedDemandUnit.allCases, id: \.self) { Text(SharedDemandCopy.unit($0)).tag($0) } }.pickerStyle(.menu)
    }
    @ViewBuilder private func budget(_ value: ShopperBudget, label: String) -> some View {
        Text(label).font(.headline)
        LabeledContent(householdScope(value.scope), value: householdMoney(value.totalMinor, currency: value.currency))
        Text(u(value.status == "overCap" ? "Over the spending limit" : value.status == "withinCap" ? "Within the spending limit" : value.status == "scopeMismatch" ? "The quote and spending limit cover different things." : "Some checkout costs are still unknown."))
        if value.overCapMinor != nil { LabeledContent(u("Over the limit"), value: householdMoney(value.overCapMinor, currency: value.currency)) }
        if value.totalMinor == nil { LabeledContent(u("Known minimum"), value: householdMoney(value.lowerBoundMinor, currency: value.currency)) }
    }
    @ViewBuilder private func food(_ graph: SharedDemandGraph, totals: [SharedDemandLineTotal], prefix: String) -> some View {
        ForEach(totals, id: \.lineId) { total in
            LabeledContent(graph.lines.first { $0.id == total.lineId }?.name ?? u("Item"), value: SharedDemandCopy.amount(total.quantity, unit: total.unit))
        }
        ForEach(graph.contributions, id: \.id) { source in
            VStack(alignment: .leading, spacing: 4) {
                Text(source.productName).font(.headline)
                Text(source.originalText)
                Text(graph.lines.first { $0.id == source.lineId }?.name ?? source.productName)
                Text(SharedDemandCopy.source(source.source))
                if case .reservation(_, let purpose, _, _, _, _) = source.source { Text(purpose) }
                Text(source.removedAt == nil ? u("Included") : u("Removed"))
                Text(SharedDemandCopy.quantity(source.quantity))
                if let quantity = source.quantity { Text(quantity.originalLiteral); conversion(quantity) }
                ForEach(Array((source.sourceExclusions ?? []).enumerated()), id: \.offset) { _, restriction in
                    Text(restriction.label)
                    if restriction.resolution == .unresolved { Text(u("Restriction still needs review")) }
                }
                if !source.exclusions.isEmpty { Text(u("Exclusions") + ": " + source.exclusions.joined(separator: ", ")) }
                if !source.contains.isEmpty { Text(u("Contains") + ": " + source.contains.joined(separator: ", ")) }
            }.accessibilityIdentifier("sharedUndo." + prefix + ".source." + source.id.string)
        }
        ForEach(graph.edges, id: \.id) { edge in
            VStack(alignment: .leading) {
                Text(u(edge.kind == .duplicate ? "Same food, counted once" : "Food already included"))
                Text(graph.contributions.first { $0.id == edge.demandId }?.originalText ?? u("Item"))
                Text(graph.contributions.first { $0.id == edge.supplyId }?.originalText ?? u("Item"))
                Text(SharedDemandCopy.quantity(edge.quantity)); conversion(edge.quantity)
                Text(edge.confirmation.evidence); Text(householdTime(edge.confirmation.confirmedAt))
            }
        }
    }
    @ViewBuilder private func conversion(_ quantity: SharedDemandQuantity) -> some View {
        if let basis = quantity.confirmedConversion {
            Text("1 \(SharedDemandCopy.unit(basis.sourceUnit)) = \(SharedDemandCopy.amount(basis.targetAmountPerSourceUnit)) \(SharedDemandCopy.unit(basis.targetUnit))")
            Text(basis.sourceNote); Text(householdTime(basis.confirmedAt))
        }
    }
}
