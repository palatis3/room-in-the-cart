import SwiftUI
import HouseholdClient

struct SharedTrackingShopView: View {
    @ObservedObject var owner: HouseholdShopModel
    @StateObject private var flow: SharedTrackingFlowModel
    let editor: TrackingShopEditorContext?
    init(owner: HouseholdShopModel, editor: TrackingShopEditorContext? = nil, freezing: Bool = false) {
        self.owner = owner; self.editor = editor
        _flow = StateObject(wrappedValue: .init(access: owner, edited: editor?.candidate, mealEdit: editor?.mealEdit, freezing: freezing, selectionID: editor?.id))
    }
    var body: some View {
        SharedTrackingFlowView(model: flow, authorized: owner.trackingAllowed && (editor == nil || owner.trackingEditor == editor), lease: owner.trackingLease,
            shop: owner.shop, advanced: AnyView(SharedDemandFlowView(shopModel: owner)))
    }
}
struct SharedTrackingRequestView: View {
    @ObservedObject var owner: HouseholdInboxModel
    @StateObject private var flow: SharedTrackingFlowModel
    init(owner: HouseholdInboxModel, context: TrackingRequestContext) {
        self.owner = owner
        _flow = StateObject(wrappedValue: .init(access: owner, request: context))
    }
    var body: some View {
        SharedTrackingFlowView(model: flow, authorized: owner.trackingAllowed && owner.trackingRequest == flow.request,
            lease: owner.trackingLease, shop: owner.shop, advanced: nil)
    }
}
struct SharedTrackingFlowView: View {
    @ObservedObject var model: SharedTrackingFlowModel
    let authorized: Bool
    let lease: UUID
    let shop: ShopperShop?
    let advanced: AnyView?
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var resultFocused: Bool
    var body: some View {
        WorkingForm {
            if authorized {
                if let page = model.page, model.permitted {
                    if let candidate = model.candidate { candidateReview(candidate) }
                    else if !model.pending && !model.submitted {
                        current(page)
                        if model.freezing { freezeReview(page) }
                        else {
                            if page.status == .reviewRequired {
                                Text(st("Privacy changed this record. Only the surviving facts below can be reviewed; old previews and copied text cannot be restored."))
                            } else { entry(page); partialMealEntry() }
                            packEntry()
                            Button(st("Review all changes and pickup")) { Task { await model.preview() } }
                                .accessibilityIdentifier("sharedTracking.preview")
                            if page.status == .enabled, model.request == nil, model.edited == nil {
                                history(page); rebind(page)
                                if page.state?.unbound.isEmpty == true, page.state?.legacyLineIds.isEmpty == true, let advanced {
                                    NavigationLink(st("Edit food relationships and conversions")) { advanced }
                                        .accessibilityIdentifier("sharedTracking.advanced")
                                }
                            }
                        }
                    }
                }
                if model.pending { Text(st("Not confirmed. Return to the shop and retry the exact saved action.")) }
                if let notice = model.notice { Text(notice).accessibilityIdentifier("sharedTracking.result").accessibilityFocused($resultFocused) }
                if model.page == nil && !model.busy && !model.submitted && !model.pending {
                    Button(st("Refresh current facts")) { Task { await model.load() } }.accessibilityIdentifier("sharedTracking.refresh")
                }
                if model.busy { ProgressView(st("Checking shared pickup…")) }
            } else { Text(st("Shared access ended. Return to the household.")) }
        }
        .navigationTitle(st(model.freezing ? "Review frozen pickup" : "Food quantities and sources"))
        .scrollDismissesKeyboard(.interactively)
        .disabled(model.busy)
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button(st("Cancel")) { model.clear(); dismiss() }.accessibilityIdentifier("sharedTracking.cancel")
        } }
        .task { await model.load() }
        .onDisappear { model.clear() }
        .onChange(of: authorized) { _, value in if !value { model.clear() } }
        .onChange(of: lease) { _, _ in model.clear() }
        .onChange(of: shop) { _, _ in model.clear() }
        .onChange(of: model.notice) { _, value in resultFocused = value != nil }
    }
    @ViewBuilder private func current(_ page: SharedTrackingPage) -> some View {
        let state = page.state
        let graph = state?.graph ?? page.projection?.state.graph
        Section(st("Current pickup")) {
            LabeledContent(st("Shop revision"), value: String(page.shopRevision))
            Text(st("Tracked subtotals are not complete household coverage. Unbound food is never available supply."))
            if let shop { SharedShopFields(quote: shop.quote, lines: shop.lines) }
            ShopperBudgetView(title: st("Current whole pickup cost"), value: page.checkout)
            if let coverage = page.coverage, let graph { SharedTrackingFacts.coverageFacts(coverage, graph: graph) }
        }
        if let graph { SharedTrackingFacts.graphFacts(graph, title: st("Current tracked sources and relationships")) }
        let catalog = state?.catalog ?? page.projection?.state.catalog ?? []
        let unbound = state?.unbound ?? page.projection?.state.unbound ?? []
        Section(st("All authoritative commitments")) {
            ForEach(catalog, id: \.id) { fact in
                VStack(alignment: .leading, spacing: 8) {
                    SharedTrackingFacts.factFacts(fact)
                    if let entry = unbound.first(where: { $0.factId == fact.id }) {
                        Text(st("Unbound · not available supply"))
                        if let transfer = entry.transferred { Text(st("Retained source identity")); SharedTrackingFacts.contribution(transfer) }
                    } else { Text(st("Bound to tracked food")) }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("sharedTracking.fact." + fact.id.string)
            }
        }
    }
    @ViewBuilder private func entry(_ page: SharedTrackingPage) -> some View {
        if let request = model.request {
            Section(st("Exact request decision")) {
                Text(request.reviewed.request.originalItem)
                Text(request.reviewed.request.ownQuantity ?? st("Unknown"))
                LabeledContent(st("Request revision"), value: String(request.reviewed.preview.requestRevision))
                SharedShopFields(quote: request.reviewed.shop.quote, lines: request.basket)
                if let fixed = request.fixedNeeded { LabeledContent(st("Request food amount"), value: SharedDemandCopy.quantity(fixed)) }
                else { amount(model.entry(\.requestAmount, empty: .init()), title: st("Request food amount")) }
                unit(model.entry(\.requestLineUnit, empty: .count), title: st("Food total unit"))
                Toggle(st("I confirm this request is the same food as the selected basket item"), isOn: model.entry(\.requestMatched, empty: false))
            }
        } else {
            if let edited = model.edited { Section(st("Entered basket and quote")) {
                SharedShopFields(quote: edited.quote, lines: edited.lines)
                Toggle(st("Changed basket labels still describe the same tracked food"), isOn: model.entry(\.confirmBasketLabels, empty: false))
                Text(st("Keep tracked items with existing commitments. Their removal needs a separate source review."))
            } }
        }
        Section(st("Authored manual food")) {
            if page.status == .legacy { Text(st("Represent every basket item with an explicit source. Enter unrelated groceries separately; pack counts do not establish food amounts.")) }
            ForEach(model.draft.manuals) { entry in
                let binding = model.row(\.manuals, id: entry.id, empty: TrackingManualEntry(id: entry.id))
                VStack(alignment: .leading, spacing: 8) {
                    if let id = entry.lineID, let pack = model.draft.packs.first(where: { $0.id == id }) { Text(pack.name) }
                    Toggle(st("Add a manual need"), isOn: binding.enabled)
                    if entry.enabled {
                        TextField(st("Food name"), text: binding.name, axis: .vertical)
                        TextField(st("Original wording"), text: binding.original, axis: .vertical)
                        linePicker(binding.lineID, title: st("Basket item"))
                        amount(binding.amount, title: st("Food amount"))
                        TextField(st("Exclusion tags, separated by commas"), text: binding.exclusions)
                        TextField(st("Contains tags, separated by commas"), text: binding.contains)
                        Toggle(st("I confirm this source matches the selected food"), isOn: binding.productConfirmed)
                    }
                }.accessibilityElement(children: .contain).accessibilityIdentifier("sharedTracking.manual." + entry.id.string)
            }
        }
            if page.status == .legacy {
                Section(st("Bind each existing commitment")) {
                    Text(st("Keep every authoritative source, amount, original wording and restriction. Choose its basket item explicitly."))
                    ForEach(model.draft.facts.filter { fact in
                        guard let request = model.request, case .request(let id, _) = fact.fact.source else { return true }; return id.string != request.reviewed.request.id
                    }) { entry in
                        SharedTrackingFacts.factFacts(entry.fact)
                        TextField(st("Matched food name"), text: model.factEntry(id: entry.id, path: \.productName, empty: ""), axis: .vertical)
                        if case .request = entry.fact.source {
                            amount(model.factEntry(id: entry.id, path: \.requestAmount, empty: .init()), title: st("Request food amount"))
                        }
                        linePicker(model.factEntry(id: entry.id, path: \.lineID, empty: nil), title: st("Basket item"))
                            .disabled(entry.fact.requiredLineId != nil)
                        if entry.fact.quantity != nil, entry.fact.quantity?.confirmedConversion == nil {
                            fixedConversion(model.factEntry(id: entry.id, path: \.conversion, empty: .init()))
                        }
                        Toggle(st("I confirm this source matches the selected food"), isOn: model.factEntry(id: entry.id, path: \.productConfirmed, empty: false))
                    }
                }
            }
    }
    @ViewBuilder private func partialMealEntry() -> some View {
        if let change = model.draft.mealChanges {
            Section(st("Meal commitments")) {
                Text(st("Review the meal change and every affected food commitment. Unbound food remains unavailable supply."))
                if let before = change.catalog.mealChange.before?.meal {
                    Text(st("Before")); SharedMealFacts(meal: before, deadlineIdentifier: "sharedTracking.entry.before.deadline")
                }
                if let after = change.catalog.mealChange.after.meal {
                    Text(st("After")); SharedMealFacts(meal: after, deadlineIdentifier: "sharedTracking.entry.after.deadline")
                } else { Text(st("Meal removed")) }
                ForEach(change.rows) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(row.source.proposed.productName).font(.headline)
                        Text(st(row.source.location == .tracked ? "Tracked food" : row.source.location == .transferred ? "Retained unbound food" : "New or unbound food"))
                        if let before = row.source.before { Text(st("Before")); SharedTrackingFacts.contribution(before) }
                        Text(st("After")); Text(row.source.proposed.originalText)
                        Text(SharedDemandCopy.quantity(row.source.proposed.quantity))
                        SharedTrackingFacts.restrictions(row.source.proposed.sourceExclusions)
                        if let quantity = row.source.proposed.quantity { SharedTrackingFacts.conversion(quantity) }
                        if row.source.location == .new || row.source.location == .unbound {
                            Picker(st("Basket item"), selection: model.mealLineEntry(id: row.id)) {
                                Text(st("Keep this commitment unbound")).tag(Optional<SharedDemandID>.none)
                                ForEach(model.draft.packs) { Text($0.name).tag(Optional($0.id)) }
                            }
                            if row.lineID != nil {
                                Toggle(st("I confirm this source matches the selected food"), isOn: model.mealRowEntry(\.rows, id: row.id, path: \.productConfirmed, empty: false))
                                if row.source.proposed.quantity != nil, row.source.proposed.quantity?.confirmedConversion == nil {
                                    fixedConversion(model.mealRowEntry(\.rows, id: row.id, path: \.conversion, empty: .init()))
                                }
                            }
                        }
                        if row.canReviewFreshConversion {
                            if let lineID = row.source.before?.lineId,
                               let line = model.page?.state?.graph.lines.first(where: { $0.id == lineID }),
                               row.source.location == .tracked {
                                Text(st("Food total unit")); Text(SharedDemandCopy.unit(line.unit))
                            }
                            fixedConversion(model.mealRowEntry(\.rows, id: row.id, path: \.conversion, empty: .init()))
                        }
                        if row.needsConfirmation {
                            Toggle(st("I reviewed this source change"), isOn: model.mealRowEntry(\.rows, id: row.id, path: \.confirmed, empty: false))
                        }
                        if row.needsQuantificationConfirmation {
                            Toggle(st("I confirm the previously unknown protected quantity"), isOn: model.mealRowEntry(\.rows, id: row.id, path: \.quantificationConfirmed, empty: false))
                        }
                    }.accessibilityElement(children: .contain).accessibilityIdentifier("sharedTracking.mealSource." + row.id.string)
                }
                ForEach(change.retirements) { row in
                    Text(st("Remove this meal commitment")); SharedTrackingFacts.contribution(row.source)
                    Toggle(st("I reviewed this removal"), isOn: model.mealRowEntry(\.retirements, id: row.id, path: \.confirmed, empty: false))
                        .accessibilityIdentifier("sharedTracking.mealRemoval." + row.id.string)
                }
                ForEach(change.edgeRemovals) { row in
                    Text(st("Food relationships affected by this change"))
                    Text(SharedDemandCopy.quantity(row.edge.quantity)); Text(row.edge.confirmation.evidence)
                    Toggle(st("Remove this relationship"), isOn: model.mealRowEntry(\.edgeRemovals, id: row.id, path: \.remove, empty: false)).disabled(row.required)
                    if row.remove {
                        Toggle(st("I reviewed this relationship removal"), isOn: model.mealRowEntry(\.edgeRemovals, id: row.id, path: \.confirmed, empty: false))
                            .accessibilityIdentifier("sharedTracking.mealEdge." + row.id.string)
                    }
                }
                Toggle(st("I reviewed all meal commitments"), isOn: model.mealEntry(\.reviewed, empty: false))
                    .accessibilityIdentifier("sharedTracking.mealReviewed")
            }
        }
    }
    @ViewBuilder private func packEntry() -> some View {
        Section(st("Review usable food and whole packs separately")) {
            Text(st("Leave unknown usable food unresolved. Only tracked items receive pack reviews; the full basket remains visible in pickup review."))
            ForEach(model.draft.packs.filter { entry in model.page.map { model.draft.reviewLineIDs(page: $0, request: model.request).contains(entry.id) } == true }) { entry in
                let binding = model.row(\.packs, id: entry.id, empty: TrackingPackEntry(id: entry.id, name: ""))
                Text(entry.name).font(.headline)
                if model.page?.status == .legacy || model.page?.state?.graph.lines.contains(where: { $0.id == entry.id && $0.trashedAt == nil }) == false { unit(binding.lineUnit, title: st("Food total unit")) }
                if model.page?.state?.graph.contributions.contains(where: { $0.lineId == entry.id && $0.removedAt == nil && $0.productKey == nil }) == true {
                    Toggle(st("I confirm the existing sources on this item are the same food"), isOn: binding.confirmExistingSources)
                }
                if let fixed = entry.fixedUsable { LabeledContent(st("Reviewed usable food per pack"), value: SharedDemandCopy.quantity(fixed)) }
                else { amount(binding.usable, title: st("Usable food in one pack")) }
                Toggle(st("I accept unresolved quantities or restrictions for this item"), isOn: binding.acceptUnresolved)
                    .accessibilityIdentifier("sharedTracking.pack." + entry.id.string)
            }
        }
    }
    @ViewBuilder private func candidateReview(_ review: SharedTrackingCandidateReview) -> some View {
        Section(st("Review exact changes")) {
            Text(st("Nothing is saved until Apply. Review the complete before and after facts, then the whole pickup."))
            LabeledContent(st("Review expires"), value: review.candidate.expiresAt)
        }
        if let shop = model.shop {
            Section(st("Before basket and quote")) { SharedShopFields(quote: shop.quote, lines: shop.lines) }
        }
        if let request = model.request {
            Section(st("Request checkout comparison")) {
                ShopperBudgetView(title: st("Before"), value: request.reviewed.preview.before)
                ShopperBudgetView(title: st("After"), value: request.reviewed.preview.after)
                LabeledContent(st("Checkout change"), value: householdMoney(request.reviewed.preview.changeMinor, currency: request.reviewed.preview.after.currency))
            }
        }
        Section(st("Whole pickup cost before and after")) {
            ShopperBudgetView(title: st("Before"), value: review.candidate.disclosure.money.before)
            ShopperBudgetView(title: st("After"), value: review.candidate.disclosure.money.after)
        }
        if case .patch(let action) = review.candidate.action.command, let edit = action.mealEdit, case .none = review.candidate.disclosure.changes {
            Section(st("Meal before and after")) {
                if let current = model.shop?.meals?.first(where: { $0.occurrenceId == edit.occurrenceId.uuid }) { Text(st("Before")); SharedMealFacts(meal: current.meal, deadlineIdentifier: "sharedTracking.meal.before.deadline") }
                else { Text(st("No current meal")) }
                if let after = edit.meal { Text(st("After")); SharedMealFacts(meal: after, deadlineIdentifier: "sharedTracking.meal.after.deadline") }
                else { Text(st("Meal removed")) }
            }
        }
        switch review.intent.kind {
        case .firstAdoptionUndo(let target, _), .mealOperationUndo(let target, _): Section(st("Exact target operation")) { Text(target.string) }
        default: EmptyView()
        }
        if let graph = review.page.state?.graph ?? review.page.projection?.state.graph { SharedTrackingFacts.graphFacts(graph, title: st("Before")) }
        if let previous = review.page.state {
            Section(st("Previous food commitments")) {
                ForEach(previous.catalog, id: \.id) { fact in
                    SharedTrackingFacts.factFacts(fact)
                    if let entry = previous.unbound.first(where: { $0.factId == fact.id }) {
                        Text(st("Unbound · not available supply"))
                        if let transferred = entry.transferred { SharedTrackingFacts.contribution(transferred) }
                    } else { Text(st("Bound to tracked food")) }
                }
            }
            Section(st("Previous pack evidence")) {
                ForEach(previous.packReviews, id: \.lineId) { pack in
                    Text(previous.basket.first { $0.id == pack.lineId }?.name ?? pack.lineId.string)
                    Text(SharedDemandCopy.quantity(pack.usablePerPack))
                    if let amount = pack.usablePerPack { SharedTrackingFacts.conversion(amount) }
                    Text(st(pack.acceptUnresolved ? "Unresolved facts explicitly accepted" : "Unresolved facts not accepted"))
                }
            }
        }
        SharedTrackingFacts.graphFacts(review.candidate.after.graph, title: st("After"))
        SharedTrackingFacts.changes(review.candidate.disclosure.changes)
        Section(st("Complete pickup review")) {
            switch review.candidate.action.command {
            case .patch(let action): SharedShopFields(quote: action.quote, lines: action.lines)
            case .request: if let request = model.request { SharedShopFields(quote: request.reviewed.shop.quote, lines: request.basket) }
            }
            SharedTrackingFacts.coverageFacts(review.candidate.disclosure.pickup.coverage, graph: review.candidate.after.graph)
            ForEach(review.candidate.after.catalog, id: \.id) { fact in
                SharedTrackingFacts.factFacts(fact)
                if let entry = review.candidate.after.unbound.first(where: { $0.factId == fact.id }) {
                    Text(st("Unbound · not available supply"))
                    if let transferred = entry.transferred { SharedTrackingFacts.contribution(transferred) }
                } else { Text(st("Bound to tracked food")) }
            }
            ForEach(review.candidate.disclosure.pickup.packReviews, id: \.lineId) { pack in
                Text(review.candidate.after.basket.first { $0.id == pack.lineId }?.name ?? pack.lineId.string)
                LabeledContent(st("Usable food in one pack"), value: SharedDemandCopy.quantity(pack.usablePerPack))
                if let amount = pack.usablePerPack { SharedTrackingFacts.conversion(amount) }
                Text(st(pack.acceptUnresolved ? "Unresolved facts explicitly accepted" : "Unresolved facts not accepted"))
            }
            SharedTrackingFacts.identifiers(st("Unpriced basket items"), review.candidate.disclosure.pickup.unpricedBasketIds, state: review.candidate.after)
            SharedTrackingFacts.identifiers(st("Unresolved tracked pack items"), review.candidate.disclosure.pickup.unresolvedPackIds, state: review.candidate.after)
        }
        Section {
            if review.candidate.disclosure.money.after.status == "overCap" {
                Toggle(st("I accept this pickup over the cap"), isOn: $model.acceptOverage).accessibilityIdentifier("sharedTracking.acceptOverage")
            }
            if ["unresolved", "scopeMismatch"].contains(review.candidate.disclosure.money.after.status) || review.candidate.disclosure.money.after.scope != "wholeCheckout" {
                Toggle(st("I accept this unknown or partial checkout cost"), isOn: $model.acceptUnknown).accessibilityIdentifier("sharedTracking.acceptUnknown")
            }
            acknowledgments()
            Button(st("Apply reviewed change once")) { Task { await model.apply() } }.disabled(!model.gate.canApply || !model.moneyAccepted)
                .accessibilityIdentifier("sharedTracking.apply")
            Button(st("Edit again")) { model.editAgain() }.accessibilityIdentifier("sharedTracking.editAgain")
        }
    }
    @ViewBuilder private func freezeReview(_ page: SharedTrackingPage) -> some View {
        Section(st("Freeze this exact pickup revision")) {
            Text(st("Freezing saves a dated snapshot. Sharing, retailer checkout, reporting placement and actual arrival remain separate actions."))
            if let state = page.state {
                ForEach(state.packReviews, id: \.lineId) { pack in
                    Text(state.basket.first { $0.id == pack.lineId }?.name ?? pack.lineId.string)
                    Text(SharedDemandCopy.quantity(pack.usablePerPack))
                    Text(st(pack.acceptUnresolved ? "Unresolved facts explicitly accepted" : "Unresolved facts not accepted"))
                }
            }
            if page.freezeReview != nil {
                acknowledgments()
                Button(st("Freeze reviewed pickup")) { Task { await model.freeze() } }.disabled(!model.gate.canApply)
                    .accessibilityIdentifier("sharedTracking.freeze")
            } else { Text(st("Review and save the current food facts before freezing this pickup.")) }
        }
    }
    @ViewBuilder private func history(_ page: SharedTrackingPage) -> some View {
        Section(st("Saved tracking changes")) {
            Text(st("Undo reviews the entire saved change. Later unrelated facts are retained; conflicts require a fresh review."))
            Button(st("Read saved changes")) { Task { await model.loadHistory() } }.accessibilityIdentifier("sharedTracking.history")
            if let history = model.history {
                Text(st("Select the tracked pack reviews that remain after Undo. The service checks this selection; it is not a local inverse."))
                ForEach(model.draft.packs) { pack in undoPackEntry(pack, path: \.packs) }
                if !model.draft.historicalUndoPacks.isEmpty {
                    Text(st("Earlier basket items are included only if this Undo restores them. Review their pack evidence explicitly."))
                    ForEach(model.draft.historicalUndoPacks) { pack in undoPackEntry(pack, path: \.historicalUndoPacks) }
                }
                ForEach(history.items, id: \.operationId) { item in
                    VStack(alignment: .leading) {
                        Text(item.committedAt); LabeledContent(st("Shop revision"), value: String(item.shopRevision))
                        if item.status == .current_preview_required, item.reviewRoute == .requestAcceptance, let owner = model.access as? HouseholdShopModel {
                            NavigationLink(ru("Review complete request Undo")) { SharedRequestUndoShopView(owner: owner, target: item.operationId) }
                                .accessibilityIdentifier("sharedTracking.requestUndo." + item.operationId.string)
                        } else if item.status == .current_preview_required {
                            Button(st(item.reviewRoute == .trackingMeal ? "Review whole-meal Undo" : "Review whole first-adoption Undo")) { Task { await model.undo(item) } }
                                .accessibilityIdentifier("sharedTracking.undo." + item.operationId.string)
                        } else { Text(st("This saved change is unavailable for review.")) }
                    }
                }
            }
        }
    }
    @ViewBuilder private func undoPackEntry(_ pack: TrackingPackEntry, path: WritableKeyPath<TrackingFlowDraft, [TrackingPackEntry]>) -> some View {
        let binding = model.row(path, id: pack.id, empty: TrackingPackEntry(id: pack.id, name: ""))
        Toggle(pack.name, isOn: binding.includeForUndo).accessibilityIdentifier("sharedTracking.undoPack." + pack.id.string)
        if pack.includeForUndo {
            amount(binding.usable, title: st("Usable food in one pack"))
            Toggle(st("I accept unresolved quantities or restrictions for this item"), isOn: binding.acceptUnresolved)
                .accessibilityIdentifier("sharedTracking.undoPackUnknown." + pack.id.string)
        }
    }
    @ViewBuilder private func rebind(_ page: SharedTrackingPage) -> some View {
        if let state = page.state, state.unbound.contains(where: { $0.transferred != nil }) {
            Section(st("Restore a retained binding")) {
                Text(st("Only retained source identities can be restored here. No earlier allocations are restored."))
                Picker(st("Retained source"), selection: model.entry(\.rebindFactID, empty: nil)) {
                    Text(st("Choose a source")).tag(Optional<SharedDemandID>.none)
                    ForEach(state.unbound.filter { $0.transferred != nil }, id: \.factId) { entry in
                        Text(state.catalog.first { $0.id == entry.factId }?.sourceLabel ?? entry.factId.string).tag(Optional(entry.factId))
                    }
                }
                if let selected = state.unbound.first(where: { $0.factId == model.draft.rebindFactID }), let source = selected.transferred {
                    SharedTrackingFacts.contribution(source)
                    if let old = state.graph.lines.first(where: { $0.id == source.lineId }) { Text(old.name) }
                    else { TextField(st("Restored basket name"), text: model.entry(\.rebindName, empty: "")); unit(model.entry(\.rebindUnit, empty: .count), title: st("Food total unit")) }
                    if let existing = state.basket.first(where: { $0.id == source.lineId }) { SharedTrackingFacts.basketFacts(existing) }
                    else {
                        Stepper(st("Whole packs") + ": \(model.draft.rebindPacks)", value: model.entry(\.rebindPacks, empty: 1), in: 1...1000)
                        Text(st("A restored new basket row starts with unknown price. Review its price separately afterward."))
                        Toggle(st("Counts toward the fee threshold"), isOn: model.entry(\.rebindFeeEligible, empty: true))
                    }
                    if let pack = state.packReviews.first(where: { $0.lineId == source.lineId }) { Text(SharedDemandCopy.quantity(pack.usablePerPack)) }
                    else {
                        amount(model.entry(\.rebindUsable, empty: .init()), title: st("Usable food in one pack"))
                        Toggle(st("I accept unresolved quantities or restrictions for this item"), isOn: model.entry(\.rebindUnresolved, empty: false))
                    }
                    Toggle(st("I reviewed the exact retained identity and its basket item"), isOn: model.entry(\.rebindConfirmed, empty: false))
                    Button(st("Review restored binding")) { Task { await model.rebind() } }.disabled(!model.draft.rebindConfirmed)
                        .accessibilityIdentifier("sharedTracking.rebind")
                }
            }
        }
    }
    @ViewBuilder private func acknowledgments() -> some View {
        Toggle(st("I reviewed every change, retained identity and protected commitment"), isOn: $model.gate.changes)
            .accessibilityIdentifier("sharedTracking.ackChanges")
        Toggle(st("I reviewed the whole pickup, unbound commitments, unknowns, prices and whole packs"), isOn: $model.gate.pickup)
            .accessibilityIdentifier("sharedTracking.ackPickup")
    }
    @ViewBuilder private func fixedConversion(_ value: Binding<TrackingFixedConversionEntry>) -> some View {
        Toggle(st("Use a confirmed conversion for this fixed source amount"), isOn: value.enabled)
        if value.wrappedValue.enabled {
            unit(value.target, title: st("Conversion target unit"))
            TextField(st("Target amount numerator per source unit"), text: value.numerator).keyboardType(.numberPad)
            TextField(st("Target amount denominator per source unit"), text: value.denominator).keyboardType(.numberPad)
            TextField(st("Conversion evidence"), text: value.note, axis: .vertical)
        }
    }
    private func unit(_ value: Binding<SharedDemandUnit>, title: String) -> some View {
        Picker(title, selection: value) { ForEach(SharedDemandUnit.allCases, id: \.self) { Text(SharedDemandCopy.unit($0)).tag($0) } }
    }
    private func linePicker(_ value: Binding<SharedDemandID?>, title: String) -> some View {
        Picker(title, selection: value) {
            Text(st("Choose an item")).tag(Optional<SharedDemandID>.none)
            ForEach(model.draft.packs) { Text($0.name).tag(Optional($0.id)) }
        }
    }
    @ViewBuilder private func amount(_ value: Binding<TrackingAmountEntry>, title: String) -> some View {
        Text(title).font(.subheadline)
        Toggle(st("Quantity unknown"), isOn: value.unknown)
        if !value.wrappedValue.unknown {
            TextField(st("Amount numerator"), text: value.numerator).keyboardType(.numberPad)
            TextField(st("Amount denominator"), text: value.denominator).keyboardType(.numberPad)
            unit(value.unit, title: st("Unit"))
        }
    }
}
