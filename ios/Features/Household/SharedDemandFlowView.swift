import SwiftUI
import HouseholdClient

struct SharedDemandFlowView: View {
    @ObservedObject private var shopModel: HouseholdShopModel
    @StateObject private var model: SharedDemandFlowModel
    init(shopModel: HouseholdShopModel, editor: SharedFoodEditorContext? = nil) {
        self.shopModel = shopModel
        _model = StateObject(wrappedValue: SharedDemandFlowModel(access: shopModel, editor: editor))
    }
    var body: some View {
        SharedDemandFlowContent(model: model, authorized: shopModel.canReadFood, accessBusy: shopModel.busy, shopID: shopModel.scope.shopId)
    }
}

struct SharedRequestFoodView: View {
    @ObservedObject var inbox: HouseholdInboxModel
    @StateObject private var model: SharedDemandFlowModel
    init(inbox: HouseholdInboxModel, context: SharedRequestFoodContext) {
        self.inbox = inbox
        _model = StateObject(wrappedValue: SharedDemandFlowModel(access: inbox, request: context))
    }
    var body: some View {
        SharedDemandFlowContent(model: model, authorized: inbox.canReadFood, accessBusy: inbox.busy, shopID: inbox.shop?.shopId)
    }
}

/// The same controls, canonical totals, source disclosures and Apply gate serve
/// the shop editor and request adapter; the adapter constrains the permitted edits.
private struct SharedDemandFlowContent: View {
    @ObservedObject var model: SharedDemandFlowModel
    let authorized: Bool
    let accessBusy: Bool
    let shopID: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingText: String?
    var body: some View {
        WorkingForm {
            if authorized {
                if let page = model.page, let shop = model.shop, model.permitted {
                    Section {
                        Text(sd("Food amounts and whole packs are separate. Nothing is inferred from a pack count."))
                        if page.status == .legacy { Text(sd("Review every existing meal and request before starting shared food tracking. Unknown stays unknown.")) }
                    }
                    if let review = model.review { reviewed(review, shop: shop) }
                    else if !model.pending && !model.submitted {
                        if let request = model.requestContext { requestDecision(request) }
                        if model.mealContext != nil { mealDecision() }
                        current(page)
                        if page.status == .reviewRequired {
                            if model.draft.editedCandidate == nil {
                                Text(sd("Review the surviving food facts first. Apply this unchanged review before adding or linking sources."))
                            } else {
                                Text(sd("Review the surviving food facts with your updated prices and packs. Food sources and relationships stay unchanged."))
                            }
                        }
                        editor(page)
                        Section {
                            Button(sd("Review food changes")) { Task { await model.preview() } }
                                .accessibilityIdentifier("sharedFood.preview")
                        }
                    }
                }
                if model.page == nil && !model.busy {
                    Button(sd("Refresh food quantities")) { Task { await model.load() } }
                }
                if model.pending { Text(sd("Return to the shared shop for confirmation or retry. A pending change is not yet confirmed.")) }
                if let notice = model.notice { Text(notice).accessibilityIdentifier("sharedFood.notice") }
                if model.busy { ProgressView(sd("Checking shared food…")) }
            } else { Text(sd("Shared food access ended. Return to the household.")) }
        }
        .navigationTitle(sd("Food quantities and sources"))
        .keyboardDoneAction(visible: editingText != nil, title: sd("Done"), identifier: "sharedFood.done") { editingText = nil }
        .scrollDismissesKeyboard(.interactively)
        .disabled(model.busy || accessBusy)
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button(sd("Cancel")) { model.cancel(); dismiss() }.disabled(model.busy).accessibilityIdentifier("sharedFood.cancel")
        } }
        .task { await model.load() }
        .onDisappear { model.cancel() }
        .onChange(of: authorized) { _, allowed in if !allowed { model.cancel() } }
        .onChange(of: shopID) { _, _ in model.cancel() }
    }
    private func sd(_ key: String) -> String { SharedDemandCopy.text(key) }
    @ViewBuilder private func current(_ page: SharedDemandPage) -> some View {
        if let graph = page.graph {
            Section(sd("Current food sources")) {
                totals(page.totals, graph: graph)
                ForEach(graph.contributions.filter { $0.removedAt == nil }, id: \.id) { source in sourceFacts(source, lines: graph.lines) }
                ForEach(graph.edges, id: \.id) { edge in edgeFacts(edge, sources: graph.contributions) }
            }
        }
    }
    @ViewBuilder private func editor(_ page: SharedDemandPage) -> some View {
        if model.requestContext == nil, let candidate = model.draft.editedCandidate {
            Section(sd("Entered items and quote")) {
                Text(sd("These are your entered item and quote changes. Review their food sources before applying."))
                SharedShopFields(quote: candidate.quote, lines: model.draft.lines.map {
                    ShopperBasketLine(lineId: $0.id.uuid, originalItem: $0.name, packs: $0.packs, unitPriceMinor: $0.priceMinor, feeEligible: $0.feeEligible)
                })
            }
        }
        ForEach(model.draft.removedLines.map { model.removedLineBinding($0.id) }, id: \.wrappedValue.id) { $removed in
            Section(sd("Item marked for removal")) {
                Text(removed.line.name).font(.headline)
                ForEach(removed.sources, id: \.id) { source in sourceFacts(source, lines: page.graph?.lines ?? []) }
                if removed.mustKeep {
                    Text(sd("These meal, request or protected commitments remain. Keep their item to save your other edits."))
                } else {
                    Toggle(sd(model.mealContext == nil ? "Remove this item and its listed manual or imported food sources" : "Remove this item and the explicitly listed sources"), isOn: $removed.confirmed)
                }
                Button(sd("Keep this item and its sources")) { let id = removed.id; model.draft.restoreRemovedLine(id) }
                    .accessibilityIdentifier("sharedFood.restoreItem." + removed.id.string)
            }
        }
        if model.mealContext != nil {
            ForEach(model.draft.mealRetirements.map { model.mealRetirementBinding($0.id) }, id: \.wrappedValue.id) { $retirement in
                Section(sd("Meal source being removed")) {
                    sourceFacts(retirement.source, lines: page.graph?.lines ?? [])
                    Toggle(sd("Remove only this meal source"), isOn: $retirement.confirmed)
                        .accessibilityIdentifier("sharedFood.retire." + retirement.id.string)
                }
            }
            ForEach(model.draft.mealRelationships.map { model.mealRelationshipBinding($0.id) }, id: \.wrappedValue.id) { $relation in
                Section(sd("Existing source relationship")) {
                    edgeFacts(relation.edge, sources: page.graph?.contributions ?? [])
                    Picker(sd("Review this relationship"), selection: $relation.decision) {
                        Text(sd("Choose a decision")).tag(SharedFoodRelationshipReview.Decision.unreviewed)
                        Text(sd("Keep this exact relationship")).tag(SharedFoodRelationshipReview.Decision.keep)
                        Text(sd("Remove this relationship")).tag(SharedFoodRelationshipReview.Decision.remove)
                    }.pickerStyle(.menu)
                    Text(sd("If the covered amount changes, remove the old relationship and enter a new reviewed amount below."))
                }
            }
            Toggle(sd("I reviewed the changed meal and all retained food commitments"), isOn: $model.draft.mealSourcesReviewed)
                .accessibilityIdentifier("sharedFood.mealSourcesReviewed")
        }
        ForEach(model.draft.lines.map { model.lineBinding($0.id) }, id: \.wrappedValue.id) { $line in
            Section(line.name.isEmpty ? sd("New basket item") : line.name) {
                if !line.existing && model.requestContext == nil {
                    workingTextField(sd("Basket item"), text: $line.name, axis: .vertical).focused($editingText, equals: "line." + line.id.string)
                    Button(sd("Remove this unsaved item"), role: .destructive) { let id = line.id; model.draft.removeUnsavedLine(id) }
                }
                if let previous = page.graph?.lines.first(where: { $0.id == line.id }), previous.name != line.name {
                    LabeledContent(sd("Previous basket label"), value: previous.name)
                    Toggle(sd("This label still refers to the same food sources"), isOn: $line.confirmRename)
                    Text(sd("Renaming an item does not replace its food sources. Add a new item for different food."))
                }
                if (page.status == .legacy || !line.existing) && model.requestContext?.reviewedNeeded == nil { unitPicker(sd("Food total unit"), selection: $line.unit) }
                Stepper(sd("Whole packs") + ": \(line.packs)", value: $line.packs, in: 1...10000).disabled(page.status == .reviewRequired || model.requestContext != nil)
                if page.status != .reviewRequired, page.graph?.contributions.contains(where: { $0.lineId == line.id && $0.removedAt == nil && $0.productKey == nil }) == true {
                    Toggle(sd("I confirm the existing sources on this item are this same food"), isOn: $line.confirmExistingSources)
                        .disabled(model.requestContext != nil && (line.id != model.requestContext?.targetLineID || needsPriorIdentityReview(line.id)))
                    if model.requestContext != nil && needsPriorIdentityReview(line.id) {
                        Text(sd("Confirm the existing food identities in Food quantities, then return and review this request again."))
                    }
                    if page.graph?.contributions.contains(where: { source in
                        guard source.lineId == line.id, source.removedAt == nil, source.productKey == nil else { return false }
                        if case .reservation = source.source { return true }; return false
                    }) == true { Text(sd("Confirming a protected food's identity cannot be undone.")) }
                }
                if model.draft.editedCandidate == nil { Text(sd("Existing prices and quote stay unchanged. A new item has an unknown price.")) }
                if model.requestContext?.targetLineID == line.id, let fixed = model.requestContext?.reviewedUsable {
                    LabeledContent(sd("Usable food in one pack"), value: SharedDemandCopy.quantity(fixed))
                    Text(sd("These amounts come from your reviewed pack choice. Cancel and return to the pack review to change them."))
                } else { amountFields($line.usable, title: sd("Usable food in one pack"), prefix: "pack." + line.id.string) }
                Toggle(sd("I accept unresolved quantities or restrictions for this item"), isOn: $line.acceptUnresolved).accessibilityIdentifier("sharedFood.line." + line.id.string + ".acceptUnresolved")
            }
        }
        if page.status != .reviewRequired {
        if model.requestContext == nil {
        Section {
            Button(sd("Add basket item")) {
                guard model.draft.lines.count < 200 else { return }
                model.draft.lines.append(.init(id: .init(), name: "", unit: .count, packs: 1, priceMinor: nil, feeEligible: true, existing: false))
            }
            Button(sd("Add manual food need")) {
                guard model.draft.sources.count + (page.graph?.contributions.count ?? 0) < 2000 else { return }
                var source = SharedFoodSourceDraft(); source.lineID = model.draft.lines.first?.id
                model.draft.sources.append(source)
            }.accessibilityIdentifier("sharedFood.addManual")
        }
        }
        ForEach(model.draft.sources.map { model.sourceBinding($0.id) }, id: \.wrappedValue.id) { $source in
            Section(source.sourceLabel.isEmpty ? sd("Manual food") : source.sourceLabel) {
                Text(SharedDemandCopy.source(source.source)).font(.headline)
                if case .manual = source.source {
                    Button(sd("Remove this unsaved entry"), role: .destructive) { let id = source.id; model.draft.sources.removeAll { $0.id == id } }
                }
                if case .manual = source.source {
                    workingTextField(sd("Food name"), text: $source.productName, axis: .vertical).focused($editingText, equals: "source." + source.id.string + ".productName")
                        .onChange(of: source.productName) { _, _ in source.productConfirmed = false }
                    workingTextField(sd("Original wording"), text: $source.originalText, axis: .vertical).focused($editingText, equals: "source." + source.id.string + ".originalText")
                } else {
                    Text(source.originalText)
                    if let literal = source.originalQuantityText { LabeledContent(sd("Original quantity wording"), value: literal) }
                }
                Picker(sd("Basket item"), selection: $source.lineID) {
                    Text(sd("Choose an item")).tag(Optional<SharedDemandID>.none)
                    ForEach(model.draft.lines) { line in Text(line.name).tag(Optional(line.id)) }
                }.pickerStyle(.menu).disabled(source.requiredLineID != nil)
                    .onChange(of: source.lineID) { _, _ in source.productConfirmed = false }
                if let old = source.previousContribution {
                    LabeledContent(sd("Previous source quantity"), value: SharedDemandCopy.quantity(old.quantity))
                    if case .reservation = old.source, old.quantity == nil, source.fixedQuantity != nil {
                        Toggle(sd("I confirm this known protected quantity; it cannot be undone"), isOn: $source.quantificationConfirmed)
                            .accessibilityIdentifier("sharedFood.quantify." + source.id.string)
                    }
                }
                if source.quantityIsFixed {
                    LabeledContent(sd("Source quantity"), value: SharedDemandCopy.quantity(source.fixedQuantity))
                    if model.mealContext != nil, SharedFoodFixedConversionDraft.needed(for: source.fixedQuantity, lineUnit: model.draft.lines.first(where: { $0.id == source.lineID })?.unit) {
                        fixedConversionFields($source.fixedConversion, prefix: "source." + source.id.string + ".fixedConversion")
                    }
                }
                else { amountFields($source.amount, title: sd("Needed food amount"), prefix: "source." + source.id.string) }
                Toggle(sd("I confirm this source matches the selected food"), isOn: $source.productConfirmed)
                workingTextField(sd("Exclusion tags, comma separated"), text: $source.exclusions, axis: .vertical).focused($editingText, equals: "source." + source.id.string + ".exclusions")
                workingTextField(sd("Contains tags, comma separated"), text: $source.contains, axis: .vertical).focused($editingText, equals: "source." + source.id.string + ".contains").disabled(isProtectedUpdate(source))
                Text(sd("Use explicit lower-case tags. Do not guess what an inherited restriction means. Unmapped labels remain unresolved."))
                ForEach(Array(source.restrictions.enumerated()), id: \.offset) { index, restriction in
                    Text(restriction.label)
                    workingTextField(sd("Reviewed tags for this exact restriction"), text: model.restrictionBinding(sourceID: source.id, restriction: restriction), axis: .vertical).focused($editingText, equals: "source." + source.id.string + ".restriction.\(index)")
                }
            }
        }
        ForEach(model.draft.links.map { model.linkBinding($0.id) }, id: \.wrappedValue.id) { $link in
            Section(sd("Reviewed source relationship")) {
                if model.requestContext == nil {
                Picker(sd("Relationship"), selection: $link.kind) {
                    Text(sd("Use food already included")).tag(SharedDemandEdge.Kind.withinExisting)
                    Text(sd("Same manual amount entered twice")).tag(SharedDemandEdge.Kind.duplicate)
                }.pickerStyle(.menu).onChange(of: link.kind) { _, _ in link.confirmed = false }
                sourcePicker(sd("Need or duplicate entry"), selection: $link.demandID, supplyOnly: link.kind == .duplicate)
                    .onChange(of: link.demandID) { _, _ in link.confirmed = false }
                } else {
                    Text(sd("Use food already included")).font(.headline)
                    Text(model.requestContext?.reviewed.request.originalItem ?? "")
                }
                sourcePicker(sd("Existing manual food"), selection: $link.supplyID, supplyOnly: true)
                    .onChange(of: link.supplyID) { _, _ in link.confirmed = false }
                amountFields($link.amount, title: sd("Amount covered by this relationship"), prefix: "link." + link.id.string)
                    .onChange(of: link.amount) { _, _ in link.confirmed = false }
                workingTextField(sd("Why these are the same food"), text: $link.evidence, axis: .vertical).focused($editingText, equals: "link." + link.id.string + ".evidence")
                    .onChange(of: link.evidence) { _, _ in link.confirmed = false }
                Toggle(sd("I reviewed this exact amount and same-product relationship"), isOn: $link.confirmed)
                Button(sd("Remove this unsaved relationship"), role: .destructive) { let id = link.id; model.draft.links.removeAll { $0.id == id } }
            }
        }
        Section {
            Button(sd(model.requestContext == nil ? "Link within existing food or review a duplicate" : "Use existing food for this request")) {
                if model.draft.links.count + (page.graph?.edges.count ?? 0) < 4000 {
                    var link = SharedFoodLinkDraft(); link.demandID = model.requestContext?.sourceID
                    model.draft.links.append(link)
                }
            }
            Text(sd("Additional needs add together. Review the total before applying a duplicate or within-existing link."))
        }
        }
    }
    private func sourcePicker(_ title: String, selection: Binding<SharedDemandID?>, supplyOnly: Bool) -> some View {
        Picker(title, selection: selection) {
            Text(sd("Choose a source")).tag(Optional<SharedDemandID>.none)
            ForEach(sourceChoices.filter { !supplyOnly || isSupply($0.source) }, id: \.id) { item in
                Text(item.name + " · " + SharedDemandCopy.source(item.source)).tag(Optional(item.id))
            }
        }.pickerStyle(.menu)
    }
    private var sourceChoices: [(id: SharedDemandID, name: String, source: SharedDemandSource)] {
        let replaced = Set(model.draft.sources.map(\.id))
        let retiring = Set(model.draft.mealRetirements.map { $0.source.id })
        let saved = model.page?.graph?.contributions.filter { $0.removedAt == nil && !replaced.contains($0.id) && !retiring.contains($0.id) && (model.requestContext == nil || $0.lineId == model.requestContext?.targetLineID) }.map { ($0.id, $0.originalText, $0.source) } ?? []
        let entered = model.draft.sources.map { ($0.id, $0.originalText, $0.source) }
        return (saved + entered).enumerated().map { index, row in (row.0, "\(index + 1). " + row.1, row.2) }
    }
    private func isProtectedUpdate(_ source: SharedFoodSourceDraft) -> Bool {
        if let old = source.previousContribution, case .reservation = old.source { return true }; return false
    }
    @ViewBuilder private func mealDecision() -> some View {
        if let edit = model.mealContext?.mealEdit {
            Section(sd("Reviewed meal change")) {
                if let old = model.shop?.meals?.first(where: { $0.id == edit.occurrenceId.uuid }) {
                    Text(sd("Before")).font(.headline); SharedMealFacts(meal: old.meal)
                }
                if let meal = edit.meal { Text(sd("After")).font(.headline); SharedMealFacts(meal: meal) }
                else { Text(sd("Remove this meal from this shop")) }
                Text(sd("Other meals, requests and protected food stay separate. Review every affected source and whole pack."))
            }
        }
    }
    private func isSupply(_ source: SharedDemandSource) -> Bool { switch source { case .manual, .imported: true; default: false } }
    @ViewBuilder private func amountFields(_ value: Binding<SharedFoodAmountDraft>, title: String, prefix: String) -> some View {
        Text(title).font(.headline)
        Toggle(sd("Quantity unknown"), isOn: value.unknown).accessibilityIdentifier("sharedFood." + prefix + ".unknown")
        if !value.wrappedValue.unknown {
            workingTextField(sd("Amount, decimal or fraction"), text: value.literal).accessibilityIdentifier("sharedFood." + prefix + ".literal").focused($editingText, equals: prefix + ".literal").keyboardType(.numbersAndPunctuation)
            unitPicker(sd("Unit"), selection: value.unit)
            Toggle(sd("Use a confirmed conversion between different kinds of units"), isOn: value.useConversion)
            if value.wrappedValue.useConversion {
                unitPicker(sd("Conversion target unit"), selection: value.conversionUnit)
                workingTextField(sd("Target amount for one source unit"), text: value.conversionRate).focused($editingText, equals: prefix + ".conversionRate").keyboardType(.decimalPad)
                workingTextField(sd("Conversion evidence"), text: value.conversionNote, axis: .vertical).focused($editingText, equals: prefix + ".conversionNote")
                Text(sd("Only use a conversion you have confirmed for this food. No density is assumed."))
            }
        }
    }
    @ViewBuilder private func fixedConversionFields(_ value: Binding<SharedFoodFixedConversionDraft>, prefix: String) -> some View {
        Toggle(sd("Use a confirmed conversion between different kinds of units"), isOn: value.enabled).accessibilityIdentifier("sharedFood." + prefix + ".enabled")
        if value.wrappedValue.enabled {
            unitPicker(sd("Conversion target unit"), selection: value.targetUnit)
            workingTextField(sd("Target amount for one source unit"), text: value.rate).focused($editingText, equals: prefix + ".rate").keyboardType(.decimalPad).accessibilityIdentifier("sharedFood." + prefix + ".rate")
            workingTextField(sd("Conversion evidence"), text: value.note, axis: .vertical).focused($editingText, equals: prefix + ".note").accessibilityIdentifier("sharedFood." + prefix + ".note")
            Text(sd("Only use a conversion you have confirmed for this food. No density is assumed."))
        }
    }
    private func unitPicker(_ title: String, selection: Binding<SharedDemandUnit>) -> some View {
        Picker(title, selection: selection) { ForEach(SharedDemandUnit.allCases, id: \.self) { Text(SharedDemandCopy.unit($0)).tag($0) } }.pickerStyle(.menu)
    }
    @ViewBuilder private func reviewed(_ review: SharedDemandReview, shop: ShopperShop) -> some View {
        if model.mealContext != nil { mealDecision() }
        if let request = model.requestContext { requestDecision(request) }
        Section(sd("Before")) { totals(review.preview.beforeTotals, graph: review.preview.before) }
        Section(sd("After")) {
            totals(review.preview.afterTotals, graph: review.preview.after)
            ForEach(review.preview.after.contributions.filter { $0.removedAt == nil }, id: \.id) { source in sourceFacts(source, lines: review.preview.after.lines) }
            ForEach(review.preview.after.edges, id: \.id) { edge in edgeFacts(edge, sources: review.preview.after.contributions) }
        }
        let removed = review.preview.receipt.contributions.compactMap { delta -> SharedDemandContribution? in
            guard let before = delta.before, before.removedAt == nil, delta.after?.removedAt != nil else { return nil }
            return before
        }
        if !removed.isEmpty {
            Section(sd("Food sources being removed")) {
                ForEach(removed, id: \.id) { source in sourceFacts(source, lines: review.preview.before.lines) }
            }
        }
        let basket: [ShopperBasketLine] = model.requestContext?.basket ?? (patchLines(review.request.action) ?? [])
        let quote = model.requestContext?.reviewed.shop.quote ?? (patchQuote(review.request.action) ?? shop.quote)
        if model.requestContext != nil || patchQuote(review.request.action) != nil {
            Section(sd("Whole packs and quote")) { SharedShopFields(quote: quote, lines: basket) }
            Section(sd("Reviewed pack coverage")) {
                ForEach(review.preview.packs, id: \.lineId) { pack in
                    Text(basket.first { $0.lineId == pack.lineId.string }?.originalItem ?? sd("Food")).font(.headline)
                    LabeledContent(sd("Usable food in one pack"), value: SharedDemandCopy.quantity(pack.usablePerPack))
                    if pack.acceptUnresolved { Text(sd("Unresolved quantities or restrictions accepted for this item")) }
                    if let quantity = pack.usablePerPack { conversionFacts(quantity) }
                }
            }
        }
        Section {
            LabeledContent(sd("Review expires"), value: householdTime(review.preview.expiresAt))
            Text(sd("Review the food and packs before applying. Cancel leaves the shop unchanged. Retry keeps the same reviewed change."))
            Toggle(sd("I reviewed these sources, relationships, unknowns and whole packs"), isOn: $model.acknowledged).accessibilityIdentifier("sharedFood.acknowledged")
            Button(sd("Apply food changes")) { Task { await model.apply() } }.disabled(!model.acknowledged)
                .accessibilityIdentifier("sharedFood.apply")
            Button(sd("Edit this review")) { model.editAgain() }
        }
    }
    private func patchLines(_ action: SharedDemandAction) -> [ShopperBasketLine]? {
        if case .patch(let body) = action { return body.lines }; return nil
    }
    private func patchQuote(_ action: SharedDemandAction) -> ShopperQuote? {
        if case .patch(let body) = action { return body.quote }; return nil
    }
    private func needsPriorIdentityReview(_ id: SharedDemandID) -> Bool {
        model.page?.graph?.contributions.contains { source in
            guard source.removedAt == nil, source.lineId == id, source.productKey == nil else { return false }
            switch source.source { case .manual, .imported: return false; default: return true }
        } ?? false
    }
    @ViewBuilder private func requestDecision(_ context: SharedRequestFoodContext) -> some View {
        Section(sd("Reviewed request decision")) {
            Text(context.reviewed.request.originalItem).font(.headline)
            if let alias = context.reviewed.request.authorAlias { LabeledContent(ht("Requested by"), value: alias) }
            if let wording = context.reviewed.request.ownQuantity { LabeledContent(sd("Original quantity wording"), value: wording) }
            Text(sd("Keep the request wording and reviewed packs. Enter food quantities explicitly; linking a basket item does not itself allocate existing food."))
            ShopperBudgetView(title: ht("Before this decision"), value: context.reviewed.preview.before)
            ShopperBudgetView(title: ht("After this decision"), value: context.reviewed.preview.after)
            if context.reviewed.preview.requiresOverageAcceptance { Text(ht("I accept the displayed overage")) }
            if context.reviewed.preview.requiresUnknownAcceptance { Text(ht("I understand the total or its scope is unresolved")) }
            LabeledContent(sd("Request preview expires"), value: householdTime(context.reviewed.preview.expiresAt))
            Text(sd("To change the request outcome, packs, price or budget acknowledgments, cancel this food review and review the request again."))
        }
    }
    @ViewBuilder private func totals(_ values: [SharedDemandLineTotal], graph: SharedDemandGraph) -> some View {
        if values.isEmpty { Text(sd("No recorded food total")) }
        ForEach(values, id: \.lineId) { total in
            LabeledContent(graph.lines.first { $0.id == total.lineId }?.name ?? sd("Food"), value: SharedDemandCopy.amount(total.quantity, unit: total.unit))
        }
    }
    @ViewBuilder private func sourceFacts(_ source: SharedDemandContribution, lines: [SharedDemandLine]) -> some View {
        Text(source.originalText).font(.headline)
        LabeledContent(sd("Basket item"), value: lines.first { $0.id == source.lineId }?.name ?? sd("Food"))
        if let origin = originLabel(source.source) { Text(origin) }
        LabeledContent(SharedDemandCopy.source(source.source), value: SharedDemandCopy.quantity(source.quantity))
        if let quantity = source.quantity { LabeledContent(sd("Original quantity wording"), value: quantity.originalLiteral); conversionFacts(quantity) }
        ForEach(Array((source.sourceExclusions ?? []).enumerated()), id: \.offset) { _, restriction in
            switch restriction.resolution {
            case .unresolved: Text(restriction.label + " · " + sd("Unresolved restriction"))
            case .mapped(let tags, _): Text(restriction.label + " · " + tags.joined(separator: ", "))
            }
        }
        if !source.exclusions.isEmpty { LabeledContent(sd("Exclusions"), value: source.exclusions.joined(separator: ", ")) }
        if !source.contains.isEmpty { LabeledContent(sd("Contains"), value: source.contains.joined(separator: ", ")) }
    }
    private func originLabel(_ source: SharedDemandSource) -> String? {
        let id: SharedDemandID?
        switch source { case .meal(let occurrence, _, _, _): id = occurrence
        case .reservation(_, _, let occurrence, _, _, _): id = occurrence
        default: id = nil }
        return model.shop?.meals?.first { $0.id == id?.uuid }?.meal.title
    }
    @ViewBuilder private func conversionFacts(_ quantity: SharedDemandQuantity) -> some View {
        if let basis = quantity.confirmedConversion {
            LabeledContent(sd("Confirmed conversion"), value: "1 " + SharedDemandCopy.unit(basis.sourceUnit) + " = " + SharedDemandCopy.amount(basis.targetAmountPerSourceUnit) + " " + SharedDemandCopy.unit(basis.targetUnit))
            Text(basis.sourceNote)
        }
    }
    @ViewBuilder private func edgeFacts(_ edge: SharedDemandEdge, sources: [SharedDemandContribution]) -> some View {
        Text(sd(edge.kind == .duplicate ? "Same manual amount entered twice" : "Use food already included")).font(.headline)
        Text((sources.first { $0.id == edge.demandId }?.originalText ?? sd("Food")) + " → " + (sources.first { $0.id == edge.supplyId }?.originalText ?? sd("Food")))
        Text(SharedDemandCopy.quantity(edge.quantity)); conversionFacts(edge.quantity); Text(edge.confirmation.evidence)
    }
}
