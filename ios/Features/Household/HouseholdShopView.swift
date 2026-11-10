import SwiftUI
import HouseholdClient

struct HouseholdShopView: View {
    @ObservedObject var model: HouseholdModel
    var body: some View {
        Group {
            if let shop = model.sharedShop, !model.locked { SharedShopContent(model: shop, household: model) }
            else { ContentUnavailableView(ht("Shared shop access required"), systemImage: "lock", description: Text(ht("The organizer can start the first shared shop. Only its assigned shopper can change it."))) }
        }.navigationTitle(ht("Shared household shop"))
    }
}
private struct SharedShopContent: View {
    @ObservedObject var model: HouseholdShopModel
    @ObservedObject var household: HouseholdModel
    @State private var clearingRetry = false
    @State private var mealDaySelection: SharedMealDaySelection?
    var body: some View {
        Form {
            if model.authorized {
                Section {
                    Text(model.scope.household.label).font(.headline)
                    Text(ht("This is the household service's shared shop. Private lists, meals and records on this phone are not uploaded."))
                    Button(ht("Refresh shared shop")) { Task { await model.load() } }
                    if household.storeQuoteScope != nil {
                        NavigationLink(StoreQuoteCopy.text("Two entered store quotes")) { SharedStoreQuotesView(household: household) }
                            .accessibilityIdentifier("sharedShop.storeQuotes")
                    }
                    NavigationLink(PlacementCopy.text("Shared placement reports")) { PlacementRecordsEntryView(household: household) }
                        .accessibilityIdentifier("sharedShop.placementReports")
                }
                delivery
                if model.canReadConfirmedOrder, let shop = model.shop, shop.placedRevision != nil {
                    NavigationLink(OrderAmendmentCopy.text("Confirmed order and amendments")) {
                        SharedOrderAmendmentView(model: model, shopID: shop.shopId)
                    }.accessibilityIdentifier("sharedShop.confirmedOrder")
                }
                if model.canReadDelivery, let shop = model.shop, shop.placedRevision != nil, ["placed", "closed"].contains(shop.phase) {
                    NavigationLink(ht("What came home")) { SharedDeliveryView(model: model, household: household, shopID: shop.shopId) }
                        .accessibilityIdentifier("sharedShop.deliveryEvidence")
                }
                if model.pending == nil {
                    if let shop = model.shop {
                        Section(["placed", "closed"].contains(shop.phase) ? OrderAmendmentCopy.text("Original checkout") : ht("Current shared shop")) {
                            LabeledContent(ht("Revision"), value: shop.shopRevision.formatted())
                            Text(phaseName(shop.phase))
                            if shop.storeReviewRequired == true {
                                Text(StoreQuoteCopy.text("Prices from the former store are invalid. Review a fresh checkout quote before freezing."))
                            }
                            SharedShopFields(quote: shop.quote, lines: shop.lines)
                            if shop.meals != nil, shop.phase == "draft", model.canManage {
                                NavigationLink(ht("Meal planning access and proposals")) { SharedMealMovesView(household: household) }
                            }
                            if let meals = shop.meals, !meals.isEmpty {
                                Text(ht("Shared meal plan")).font(.headline)
                                ForEach(meals) { SharedMealFacts(meal: $0.meal) }
                            }
                            if model.canManage {
                                NavigationLink(ht("Shared financial evidence")) { SharedFinancialEvidenceView(model: model, shopID: shop.shopId) }
                                    .accessibilityIdentifier("sharedShop.financial")
                            }
                            if model.canManage, shop.phase == "closed", shop.placedRevision != nil, let id = UUID(uuidString: shop.shopId) {
                                NavigationLink(pTr("Optional pickup feedback")) { SharedMeasurementFeedbackView(household: household, shopID: id) }
                            }
                            if household.canReviewHouseholdRequests { NavigationLink(ht("Review family requests")) { HouseholdInboxView(model: household) } }
                            if shop.phase == "draft", model.canManage {
                                NavigationLink(SharedDemandCopy.text("Food quantities and sources")) { SharedDemandFlowView(shopModel: model) }
                                    .accessibilityIdentifier("sharedShop.foodQuantities")
                                NavigationLink(SharedOperationUndoCopy.text("Saved changes")) { SharedOperationUndoView(shopModel: model) }
                                    .accessibilityIdentifier("sharedShop.savedChanges")
                                Button(ht("Edit shared items and quote")) { model.beginEditing() }.accessibilityIdentifier("sharedShop.edit")
                                Button(ht("Review freezing this shop")) { model.reviewPhaseChange("shop.freeze") }
                            } else if shop.phase == "frozen", model.canManage {
                                Text(ht("Requests received after freezing are saved for next shop. Reopening does not move them into this shop automatically."))
                                Button(ht("Review reopening this shop")) { model.reviewPhaseChange("shop.reopen") }
                            } else if shop.phase == "placed" { Text(ht("A reported order cannot be reopened as a draft.")) }
                        }
                    } else if model.canCreate {
                        Section(ht("Start the first shared shop")) {
                            Text(ht("Enter the items and quote you intend to share. You will review all fields before the service creates the shop and assigns you as shopper."))
                            if !model.editing { Button(ht("Enter shared shop details")) { model.beginEditing() } }
                        }
                    } else {
                        Section { Text(ht("The current shop belongs to another assigned shopper. Contributor requests and household management keep their separate permissions.")) }
                    }
                    if model.scope.capabilities.contains("household_admin"), model.scope.shopId != nil, !model.editing {
                        NavigationLink(ht("Change assigned shopper")) { SharedShopAssignmentView(household: household, model: model) }
                    }
                    if model.canStartAnother && !model.editing {
                        Button(ht("Start a separate shared shop")) { model.beginAnotherShop() }
                    }
                    if model.creatingAnother && model.editing { Text(ht("Enter a new shared shop. Your existing shop stays separate.")) }
                    if model.editing {
                        if !model.creatingAnother, model.canManage, let meals = model.shop?.meals {
                            SharedMealEditor(model: model, meals: meals) { mealDaySelection = $0 }
                        }
                        SharedShopEditor(model: model)
                    }
                    if let review = model.review {
                        Section(ht("Review shared shop change")) {
                            Text(actionName(review.kind)).font(.headline)
                            if let transfer = review.transfer {
                                LabeledContent(ht("Current shopper"), value: transfer.fromLabel)
                                LabeledContent(ht("New shopper"), value: transfer.toLabel)
                                Text(ht("This adult will control shared basket changes. A frozen basket stays frozen. Existing planning access must be granted again."))
                            }
                            if let edit = review.mealEdit {
                                if let previous = model.shop?.meals?.first(where: { $0.id == edit.occurrenceID }) {
                                    Text(ht("Previously planned")); SharedMealFacts(meal: previous.meal, deadlineIdentifier: "sharedMeal.review.previousDeadline")
                                }
                                if let meal = edit.meal { Text(ht("Proposed meal")); SharedMealFacts(meal: meal, deadlineIdentifier: "sharedMeal.review.proposedDeadline") }
                                else { Text(ht("Remove this occurrence from the shared plan.")) }
                            }
                            if let candidate = review.candidate { SharedShopFields(quote: candidate.quote, lines: candidate.lines) }
                            if review.kind == "shop.create" { Text(ht("Only these entered fields will be sent. The service will assign this household's organizer as shopper for the new shop.")) }
                            if review.kind == "shop.freeze" { Text(ht("Freeze the displayed revision. This records a shared snapshot; it does not place an order with a retailer. Later requests go to next shop.")) }
                            if review.kind == "shop.reopen" { Text(ht("Reopen the frozen shop for review. Existing next-shop requests stay there until you explicitly review bringing them into this shop.")) }
                            Toggle(ht("I reviewed these exact shared fields and this action"), isOn: $model.acknowledged)
                            Button(actionName(review.kind)) { Task { await model.applyReviewed() } }.disabled(!model.acknowledged)
                        }
                    }
                }
                if let notice = model.notice { Section { Text(notice).accessibilityIdentifier("household.shop.notice") } }
                if model.busy { ProgressView(ht("Checking service…")) }
            } else { Text(ht("Shared shop access has ended. Return to household settings.")) }
        }.sheet(item: $mealDaySelection) { selected in
            SharedMealDaySheet(model: model, selection: selected)
        }.sheet(item: Binding(get: { model.foodEditor }, set: { if $0 == nil { model.cancelFoodEditor() } })) { context in
            NavigationStack { SharedDemandFlowView(shopModel: model, editor: context) }
        }.disabled(model.busy).task { await model.load() }
        .confirmationDialog(ht("Clear this local shared-shop retry?"), isPresented: $clearingRetry, titleVisibility: .visible) {
            Button(ht("I reviewed the current shop; clear retry"), role: .destructive) { Task { await model.clearPendingAfterReview() } }
        } message: { Text(ht("Clearing a retry does not undo a shop change already received by the service.")) }
    }
    @ViewBuilder private var delivery: some View {
        switch model.delivery {
        case .none: EmptyView()
        case .waiting:
            Section(ht("Shared shop action waiting")) {
                Text(ht("The result is not confirmed. Retry the same saved action to avoid creating another shop or repeating a change."))
                Button(ht("Retry the same shared shop action")) { Task { await model.retry() } }.accessibilityIdentifier("sharedShop.retry")
                if model.reviewedCurrentFacts { Button(ht("Clear after reviewing current shop")) { clearingRetry = true } }
            }
        case .needsReview:
            Section {
                Text(ht("Refresh the current shared shop before clearing this retry and reviewing a fresh action."))
                if model.reviewedCurrentFacts { Button(ht("Clear after reviewing current shop")) { clearingRetry = true } }
            }
        case .confirmed(let receipt):
            Section { Label(ht("Shared shop change confirmed"), systemImage: "checkmark.circle"); LabeledContent(ht("Revision"), value: receipt.shopRevision.formatted()) }
        }
    }
    private func phaseName(_ phase: String) -> String {
        switch phase { case "draft": return ht("Draft shared shop"); case "frozen": return ht("Frozen shared shop"); case "placed": return ht("Order reported placed"); default: return ht("Check current shop status") }
    }
    private func actionName(_ kind: String) -> String {
        switch kind { case "shop.create": return ht("Create reviewed shared shop"); case "shop.patch": return ht("Publish reviewed items and quote"); case "shop.transferAuthority": return ht("Transfer shopper authority"); case "shop.freeze": return ht("Freeze reviewed shared shop"); default: return ht("Reopen reviewed shared shop") }
    }
}
private struct SharedShopEditor: View {
    @ObservedObject var model: HouseholdShopModel
    var body: some View {
        Section(ht("Entered shared items")) {
            Text(ht("Enter each actual pack separately from its price. A blank price remains unknown."))
            ForEach($model.draft.lines) { $line in
                VStack(alignment: .leading) {
                    TextField(ht("Pack or item name"), text: $line.item)
                    Stepper(value: $line.packs, in: 1...10_000) { LabeledContent(ht("Whole packs"), value: line.packs.formatted()) }
                    TextField(ht("Price per pack in USD, blank if unknown"), text: $line.price).keyboardType(.decimalPad).accessibilityIdentifier("sharedShop.line." + line.id.uuidString.lowercased() + ".price")
                    Toggle(ht("Counts toward the retailer fee threshold"), isOn: $line.feeEligible)
                    Button(ht("Remove this shared line"), role: .destructive) { model.draft.lines.removeAll { $0.id == line.id } }
                }
            }
            Button(ht("Add shared line")) { model.draft.lines.append(.init()) }.disabled(model.draft.lines.count >= 200)
            Toggle(ht("This includes all remaining items for the stated quote scope"), isOn: $model.draft.complete)
        }
        Section(ht("Entered quote and cap")) {
            Picker(ht("Quote scope"), selection: $model.draft.scope) { scopeOptions }
            Picker(ht("Cap scope"), selection: $model.draft.capScope) { scopeOptions; Text(ht("Unknown")).tag("unknown") }
            costField("Cap in USD, blank if unknown", $model.draft.cap)
            Picker(ht("Retailer fee rule"), selection: $model.draft.feeKind) {
                Text(ht("Fixed fee")).tag("fixed"); Text(ht("Fee depends on eligible subtotal")).tag("threshold")
            }
            if model.draft.feeKind == "fixed" { costField("Retailer fee in USD, blank if unknown", $model.draft.fee) }
            else {
                costField("Fee threshold in USD", $model.draft.threshold)
                costField("Fee below threshold in USD, blank if unknown", $model.draft.belowFee)
                costField("Fee at or above threshold in USD, blank if unknown", $model.draft.aboveFee)
            }
            costField("Tax in USD, blank if unknown", $model.draft.tax)
            costField("Deposits in USD, blank if unknown", $model.draft.deposits)
            costField("Discounts in USD, blank if unknown", $model.draft.discounts)
            DatePicker(ht("Quote recorded"), selection: $model.draft.observedAt)
            DatePicker(ht("Quote expires"), selection: $model.draft.expiresAt).accessibilityIdentifier("sharedShop.quote.expires")
            Text(ht("Only enter zero when confirmed. Unknown or incomplete costs remain unresolved in request previews."))
            Button(ht("Review entered shared shop")) { Task { await model.reviewEditor() } }.accessibilityIdentifier("sharedShop.reviewEditor")
            Button(ht("Cancel shared shop edit")) { model.cancelEditing() }
        }
    }
    @ViewBuilder private var scopeOptions: some View {
        Text(ht("Whole checkout")).tag("wholeCheckout"); Text(ht("Item only")).tag("item"); Text(ht("Dinner only")).tag("dinner")
    }
    private func costField(_ key: String, _ binding: Binding<String>) -> some View { TextField(ht(key), text: binding).keyboardType(.decimalPad).accessibilityIdentifier("sharedShop.cost." + key) }
}
struct SharedShopFields: View {
    let quote: ShopperQuote; let lines: [ShopperBasketLine]
    var body: some View {
        ForEach(lines) { line in
            VStack(alignment: .leading) {
                Text(line.originalItem).font(.headline)
                LabeledContent(ht("Whole packs"), value: line.packs.formatted())
                LabeledContent(ht("Price per pack"), value: householdMoney(line.unitPriceMinor, currency: quote.currency))
                Text(line.feeEligible ? ht("Counts toward the retailer fee threshold") : ht("Does not count toward the retailer fee threshold"))
            }
        }
        LabeledContent(ht("Quote scope"), value: householdScope(quote.scope))
        Text(quote.complete ? ht("All remaining items included") : ht("Remaining items are not confirmed complete"))
        LabeledContent(ht("Cap"), value: householdMoney(quote.capMinor, currency: quote.currency))
        LabeledContent(ht("Cap scope"), value: householdScope(quote.capScope))
        if quote.fee.kind == "fixed" { LabeledContent(ht("Retailer fee"), value: householdMoney(quote.fee.amountMinor, currency: quote.currency)) }
        else {
            LabeledContent(ht("Fee threshold"), value: householdMoney(quote.fee.thresholdMinor, currency: quote.currency))
            LabeledContent(ht("Fee below threshold"), value: householdMoney(quote.fee.belowMinor, currency: quote.currency))
            LabeledContent(ht("Fee at or above threshold"), value: householdMoney(quote.fee.aboveMinor, currency: quote.currency))
        }
        LabeledContent(ht("Tax"), value: householdMoney(quote.taxesMinor, currency: quote.currency))
        LabeledContent(ht("Deposits"), value: householdMoney(quote.depositsMinor, currency: quote.currency))
        LabeledContent(ht("Discounts"), value: householdMoney(quote.discountsMinor, currency: quote.currency))
        LabeledContent(ht("Quote recorded"), value: householdTime(quote.observedAt))
        LabeledContent(ht("Quote expires"), value: householdTime(quote.expiresAt))
    }
}
