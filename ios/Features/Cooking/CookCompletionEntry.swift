import SwiftUI
import CoreDomain

func cookCompletionText(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "CookCompletion") }

struct CookCompletionEntry: View {
    @ObservedObject var ledger: LedgerModel
    @ObservedObject var pickup: PickupModel
    let shopID: UUID
    let mealID: UUID
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.guardianChildCoordinator) private var child
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = CookCompletionEditorModel()
    @StateObject private var lifetime = CookReviewLifetime()
    private struct Scope: Equatable {
        let identity: CapturePrivateIdentity
        let inventory: UUID
        let ledger: UUID
        let generation: UUID
        let preferences: UUID?
    }
    private var scope: Scope? {
        guard scene == .active, UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable, child?.presented != true,
              household.projection?.grantId == nil,
              let identity = CapturePrivateIdentity.current(access: access, household: household),
              pickup.pantryIsActive, pickup.pantryRouteAvailable,
              ledger.workspace.selectedShopID == shopID,
              ledger.workspace.shops.first(where: { $0.id == shopID })?.mealOccurrences.contains(where: { $0.id == mealID && $0.removedAt == nil }) == true,
              let inventory = pickup.sourceWorkspaceID, let ledgerID = ledger.sourceWorkspaceID else { return nil }
        return Scope(identity: identity, inventory: inventory, ledger: ledgerID,
                     generation: pickup.privatePantryGeneration, preferences: ledger.workspace.dinnerPlanning.privateMealPreferences?.revision)
    }
    var body: some View {
        Group {
            if scope == nil {
                Text(cookCompletionText("Unlock the same private workspace and reopen this dinner to record cooking."))
            } else if let undo = model.undoReview {
                CookCompletionUndoView(model: model, review: undo)
            } else if let completed = model.completed {
                CookCompletionSavedView(model: model, ledger: ledger, pickup: pickup, draft: completed)
            } else if let review = model.review {
                CookCompletionReviewView(model: model, review: review)
            } else if model.context != nil {
                CookCompletionForm(model: model)
            } else {
                List {
                    if model.busy { ProgressView(cookCompletionText("Loading current food and dinner…")) }
                    else {
                        Text(cookCompletionText("Current food or dinner details could not be verified. Nothing new has been confirmed."))
                        Button(cookCompletionText("Reload current dinner")) { Task { await model.reload() } }
                    }
                }
            }
        }
        .navigationTitle(cookCompletionText("Record cooking"))
        .privacySensitive()
        .interactiveDismissDisabled(model.busy)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(cookCompletionText(model.hasAttemptedMutation ? "Close" : "Cancel")) { dismiss() }.disabled(model.busy)
            }
        }
        .onDisappear { lifetime.end(); model.invalidate() }
        .task(id: scope) {
            let token = lifetime.begin()
            model.invalidate()
            guard let original = scope else { return }
            let authorized = { lifetime.permits(token) && scope == original }
            let session = PantryCookSession(ledger: ledger, pickup: pickup, authorize: authorized)
            await model.open(session: session, shopID: shopID, mealID: mealID, authorize: authorized)
        }
    }
}

private struct CookCompletionForm: View {
    @ObservedObject var model: CookCompletionEditorModel
    var body: some View {
        Form {
            if let context = model.context {
                Section(cookCompletionText("What you cooked")) {
                    Text(context.title).font(.headline)
                    Text(cookCompletionText("Confirm the actual servings and time. Recipe quantities do not determine what was used."))
                    TextField(cookCompletionText("Servings made"), text: $model.servings)
                        .keyboardType(.numbersAndPunctuation).accessibilityIdentifier("cook.servings")
                    DatePicker(cookCompletionText("Cooked at"), selection: $model.cookedAt, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                }
                ForEach($model.ingredients) { $ingredient in
                    Section(ingredient.name) {
                        LabeledContent(cookCompletionText("Planned amount"), value: pantryQuantity(ingredient.planned))
                        Picker(cookCompletionText("Actual use"), selection: $ingredient.use) {
                            Text(cookCompletionText("Choose what happened")).tag(CookCompletionEditorModel.IngredientUse.undecided)
                            Text(cookCompletionText("Not used")).tag(CookCompletionEditorModel.IngredientUse.notUsed)
                            Text(cookCompletionText("Used")).tag(CookCompletionEditorModel.IngredientUse.used)
                        }.pickerStyle(.menu).accessibilityIdentifier("cook.ingredient.\(ingredient.id)")
                        if ingredient.use == .used {
                            ForEach($ingredient.parts) { $part in
                                CookCompletionPartView(model: model, ingredientID: ingredient.id, part: $part)
                            }
                            Button(cookCompletionText("Add another batch or untracked part")) { model.addPart(ingredientID: ingredient.id) }
                        }
                    }
                }
                Section(cookCompletionText("Food remaining after cooking")) {
                    Text(cookCompletionText("Count leftovers independently. They are not inferred from planned portions."))
                    Picker(cookCompletionText("Leftovers"), selection: $model.leftoverChoice) {
                        Text(cookCompletionText("Choose what remains")).tag(CookCompletionEditorModel.LeftoverChoice.undecided)
                        Text(cookCompletionText("No leftovers")).tag(CookCompletionEditorModel.LeftoverChoice.none)
                        Text(cookCompletionText("I counted leftovers")).tag(CookCompletionEditorModel.LeftoverChoice.recorded)
                    }.pickerStyle(.menu).accessibilityIdentifier("cook.leftoverChoice")
                    if model.leftoverChoice == .recorded {
                        ForEach($model.leftovers) { $row in
                            VStack(alignment: .leading, spacing: 8) {
                                TextField(cookCompletionText("Leftover name"), text: $row.name)
                                TextField(cookCompletionText("Confirmed portions"), text: $row.portions).keyboardType(.numbersAndPunctuation)
                                Picker(cookCompletionText("Storage"), selection: $row.location) {
                                    ForEach(InventoryLocation.allCases, id: \.self) { Text(pantryLocationName($0)).tag($0) }
                                }
                                Button(cookCompletionText("Remove leftover row"), role: .destructive) { model.leftovers.removeAll { $0.id == row.id } }
                            }
                        }
                        Button(cookCompletionText("Add counted leftovers")) { model.addLeftover() }
                    }
                }
                CookCompletionNotice(model: model)
                Section {
                    Button(cookCompletionText("Review cooking and inventory changes")) { Task { await model.prepareReview() } }
                        .accessibilityIdentifier("cook.review")
                    Button(cookCompletionText("Discard this draft and reload current counts")) { Task { await model.reload() } }
                }
            }
        }.disabled(!model.canEdit)
    }
}

private struct CookCompletionPartView: View {
    @ObservedObject var model: CookCompletionEditorModel
    let ingredientID: UUID
    @Binding var part: CookCompletionEditorModel.Part
    @State private var selectingSubstitute = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Picker(cookCompletionText("How was this part recorded?"), selection: $part.use) {
                Text(cookCompletionText("Choose a record type")).tag(CookCompletionEditorModel.PartUse.undecided)
                Text(cookCompletionText("Known amount from a pantry batch")).tag(CookCompletionEditorModel.PartUse.measured)
                Text(cookCompletionText("Unmeasured amount from a pantry batch")).tag(CookCompletionEditorModel.PartUse.unmeasured)
                Text(cookCompletionText("Food not tracked in this pantry")).tag(CookCompletionEditorModel.PartUse.untracked)
            }.pickerStyle(.menu).accessibilityIdentifier("cook.part.\(part.id)")
            if part.use == .measured || part.use == .unmeasured {
                Picker(cookCompletionText("Actual batch used"), selection: $part.lotID) {
                    Text(cookCompletionText("Choose a batch")).tag(UUID?.none)
                    ForEach(model.context?.inventory.lots ?? []) { lot in
                        Text(lot.name + " · " + pantryLocationName(lot.location) + " · " + String(lot.id.uuidString.suffix(6))).tag(Optional(lot.id))
                    }
                }.onChange(of: part.lotID) { _, id in
                    if let lot = model.context?.inventory.lots.first(where: { $0.id == id }) { part.unit = lot.unit }
                }
                if let lot = model.context?.inventory.lots.first(where: { $0.id == part.lotID }) {
                    Text(pantryCount(lot.count))
                    Text(lot.confirmedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                }
                if part.use == .measured { LedgerQuantityFields(amount: $part.amount, unit: $part.unit) }
                else { Text(cookCompletionText("The selected batch’s remaining quantity will become unknown. Existing holds are retained for review.")) }
            } else if part.use == .untracked {
                Text(cookCompletionText("This records unresolved use without changing a pantry count. It does not mean nothing was used."))
            }
            if part.use != .undecided {
                Picker(cookCompletionText("Ingredient or substitution"), selection: $part.relation) {
                    Text(cookCompletionText("Review the food used")).tag(CookCompletionEditorModel.Relation.undecided)
                    Text(cookCompletionText("The planned ingredient")).tag(CookCompletionEditorModel.Relation.ingredient)
                    Text(cookCompletionText("A substitution")).tag(CookCompletionEditorModel.Relation.substitution)
                }.pickerStyle(.menu).accessibilityIdentifier("cook.relation.\(part.id)")
                if part.relation == .substitution {
                    TextField(cookCompletionText("Actual substituted food"), text: $part.substitution)
                    Text(cookCompletionText("Record what actually happened even if it differed from your preferences. This is not an eligibility recommendation."))
                }
            }
            Button(cookCompletionText("Review possible substitutions")) { selectingSubstitute = true }
            Button(cookCompletionText("Remove this part"), role: .destructive) { model.removePart(ingredientID: ingredientID, partID: part.id) }
        }
        .sheet(isPresented: $selectingSubstitute) {
            NavigationStack { CookSubstitutionReview(model: model, ingredientID: ingredientID, partID: part.id) }
        }
    }
}

private struct CookSubstitutionReview: View {
    @ObservedObject var model: CookCompletionEditorModel
    let ingredientID: UUID
    let partID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var food: InventoryLot?
    @State private var failed = false
    var body: some View {
        Group {
            if !model.hasAccess { Text(cookCompletionText("Private access changed. Reopen the cooking review.")) }
            else {
                List {
                    Text(cookCompletionText("Suggestions need compatible reviewed product details and currently free stock. You can separately record an actual substitution in the cooking form."))
                    ForEach(model.suggestions(for: ingredientID)) { row in
                        Section(row.lot.name) {
                            Text(pantryLocationName(row.lot.location) + " · " + pantryCount(row.lot.count))
                            LabeledContent(cookCompletionText("Currently free"), value: pantryQuantity(row.available))
                            ForEach(Array((row.issues + row.softDifferences).enumerated()), id: \.offset) { _, issue in Text(tonightIssue(issue)) }
                            Button(cookCompletionText("Review this batch’s ingredient and brand details")) { food = row.lot }
                            Button(cookCompletionText("Use as a reviewed substitution")) {
                                do { try model.chooseSuggestion(row, ingredientID: ingredientID, partID: partID); dismiss() }
                                catch { failed = true }
                            }.disabled(!row.eligible)
                        }
                    }
                    if failed { Text(cookCompletionText("The batch or preferences changed. Reopen the cooking review.")) }
                }
            }
        }.navigationTitle(cookCompletionText("Substitutions to review")).privacySensitive()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(cookCompletionText("Cancel")) { dismiss() } } }
            .sheet(item: $food) { lot in
                NavigationStack {
                    TonightFoodReview(food: .init(id: lot.id, name: lot.name,
                        detail: pantryLocationName(lot.location) + " · " + pantryCount(lot.count)),
                        authorize: { model.hasAccess }) { evidence in try model.reviewFoodDetails(lot: lot, evidence: evidence) }
                }
            }
    }
}

private struct CookCompletionReviewView: View {
    @ObservedObject var model: CookCompletionEditorModel
    let review: CookCompletion.Review
    var body: some View {
        List {
            Section(cookCompletionText("Review what was cooked")) {
                Text(review.draft.cookedTitle).font(.headline)
                LabeledContent(cookCompletionText("Servings made"), value: review.draft.servingsMade.description)
                LabeledContent(cookCompletionText("Cooked at"), value: review.draft.cookedAt.formatted(date: .abbreviated, time: .shortened))
                ForEach(review.draft.parts) { part in
                    VStack(alignment: .leading) {
                        Text(model.ingredients.first(where: { $0.id == part.contributionID })?.name ?? cookCompletionText("Ingredient"))
                        Text(cookUseText(part.use, lots: model.context?.inventory.lots ?? []))
                        if let name = part.substitution { Text(cookCompletionText("Actual substitution") + ": " + name) }
                    }
                }
            }
            Section(cookCompletionText("Resulting pantry counts")) {
                ForEach(review.changes, id: \.lot.id) { change in
                    VStack(alignment: .leading) {
                        Text(change.lot.name)
                        Text(pantryLocationName(change.lot.location) + " · " + pantryCount(change.lot.count))
                    }
                }
                if review.changes.isEmpty { Text(cookCompletionText("No pantry quantities change.")) }
                if review.needsInventoryReview { Text(cookCompletionText("Cooking will be recorded with unresolved use. Inventory still needs review.")) }
            }
            Section(cookCompletionText("Held portions")) {
                Text(cookCompletionText("Only supported holds for known amounts used by this meal are fulfilled. Other holds are retained."))
                ForEach(review.affectedHolds) { impact in
                    VStack(alignment: .leading) {
                        Text(model.context?.inventory.reservations.first(where: { $0.id == impact.id })?.name ?? cookCompletionText("Held portion"))
                        LabeledContent(cookCompletionText("Backed after cooking"), value: pantryQuantity(impact.backed))
                        LabeledContent(cookCompletionText("Shortfall after cooking"), value: pantryQuantity(impact.shortfall))
                        if impact.unresolved { Text(cookCompletionText("This hold needs inventory review.")) }
                    }
                }
                if review.affectedHolds.isEmpty { Text(cookCompletionText("No other held portions change.")) }
            }
            CookCompletionNotice(model: model)
            Section {
                Button(cookCompletionText(model.attemptedApply ? "Retry the same confirmation" : "Confirm cooked meal and inventory changes")) { Task { await model.confirm() } }
                    .disabled(!model.canConfirm).accessibilityIdentifier("cook.confirm")
                if !model.attemptedApply {
                    Button(cookCompletionText("Keep editing")) { model.keepEditing() }.disabled(model.busy)
                } else {
                    Button(cookCompletionText("Check saved completion")) { Task { await model.reload() } }.disabled(model.busy)
                }
            }
        }.navigationTitle(cookCompletionText("Confirm cooking"))
    }
}

private struct CookCompletionSavedView: View {
    @ObservedObject var model: CookCompletionEditorModel
    @ObservedObject var ledger: LedgerModel
    @ObservedObject var pickup: PickupModel
    let draft: CookCompletionDraft
    @State private var reviewingUse = false
    private var recordedNames: [UUID: String] {
        if let recovered = draft.recoveredMeal {
            return Dictionary(uniqueKeysWithValues: recovered.ingredients.map { ($0.need.id, $0.foodName) })
        }
        return Dictionary(uniqueKeysWithValues: (model.context?.shop.contributions ?? []).map { ($0.id, $0.productName) })
    }
    var body: some View {
        let names = recordedNames
        List {
            Section {
                Text(cookCompletionText("Cooking recorded")).font(.headline).accessibilityIdentifier("cook.saved")
                Text(draft.cookedTitle)
                LabeledContent(cookCompletionText("Servings made"), value: draft.servingsMade.description)
                Text(draft.cookedAt.formatted(date: .abbreviated, time: .shortened))
                Text(cookCompletionText(model.remainingUnresolvedUseIDs.isEmpty ? "Inventory changes recorded." : "Inventory needs review. Unresolved use remains linked to this cooking event."))
                    .accessibilityIdentifier("cook.inventoryStatus")
            }
            Section(cookCompletionText("Recorded ingredient use")) {
                ForEach(draft.parts) { part in
                    VStack(alignment: .leading) {
                        Text(names[part.contributionID] ?? cookCompletionText("Ingredient"))
                        Text(cookUseText(part.use, lots: model.context?.inventory.lots ?? [], recorded: true))
                        if let substitute = part.substitution { Text(cookCompletionText("Actual substitution") + ": " + substitute) }
                    }
                }
            }
            if let receipts = model.context?.completedRecord?.resolutions, !receipts.isEmpty {
                Section(cookCompletionText("Saved ingredient-use corrections")) {
                    ForEach(receipts, id: \.eventID) { receipt in
                        VStack(alignment: .leading) {
                            if let part = draft.parts.first(where: { $0.id == receipt.eventID }) {
                                Text(names[part.contributionID] ?? cookCompletionText("Ingredient"))
                            }
                            Text(cookResolutionAction(receipt.decision.action))
                            switch receipt.decision {
                            case .outsidePantry: EmptyView()
                            case .alreadyIncluded(_, let used), .recount(_, _, let used):
                                LabeledContent(cookCompletionText("Actual amount used"), value: pantryQuantity(used))
                            case .deduct(_, let used): LabeledContent(cookCompletionText("Actual amount used"), value: pantryQuantity(used))
                            }
                            Text(receipt.confirmedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                            if let after = receipt.after { Text(pantryCount(after)) }
                        }
                    }
                }
            }
            Section(cookCompletionText("Confirmed leftovers")) {
                ForEach(draft.leftovers) { output in
                    LabeledContent(output.name, value: output.portions.description + " · " + pantryLocationName(output.location))
                }
                if draft.leftovers.isEmpty { Text(cookCompletionText("No leftovers recorded.")) }
            }
            CookCompletionNotice(model: model)
            Section {
                if !model.remainingUnresolvedUseIDs.isEmpty {
                    Button(cookCompletionText("Review unresolved ingredient use")) { reviewingUse = true }
                        .disabled(model.busy || !model.hasAccess).accessibilityIdentifier("cook.resolution.open")
                }
                Button(cookCompletionText("Review Undo for this cooking")) { Task { await model.prepareUndo() } }
                    .disabled(!model.canReviewUndo).accessibilityIdentifier("cook.undo.review")
                Text(cookCompletionText("Undo is available only while the affected counts, leftovers and holds still match this cooking record."))
            }
        }
        .sheet(isPresented: $reviewingUse, onDismiss: { Task { await model.reload() } }) {
            NavigationStack {
                CookResolutionEntry(ledger: ledger, pickup: pickup, shopID: draft.shopID, mealID: draft.meal.id,
                    ingredientNames: names,
                    authorize: { model.hasAccess })
            }
        }
    }
}

private struct CookCompletionUndoView: View {
    @ObservedObject var model: CookCompletionEditorModel
    let review: PantryCookUndoReview
    var body: some View {
        List {
            Section(cookCompletionText("Review Undo")) {
                Text(cookCompletionText("Restore the input counts and holds from before this cooking and remove its confirmed leftover batches. Review these changes before confirming."))
                LabeledContent(cookCompletionText("Input counts to restore"), value: String(review.restoredInputCount))
                LabeledContent(cookCompletionText("Leftover batches to remove"), value: String(review.removedLeftoverCount))
                LabeledContent(cookCompletionText("Holds to restore"), value: String(review.restoredHoldCount))
                LabeledContent(cookCompletionText("Reviewed ingredient uses affected by Undo"), value: String(review.resolvedUseCount))
                Text(cookCompletionText("Original cooking and ingredient-use correction history is retained after Undo."))
                if !review.preservedCountNames.isEmpty {
                    Text(cookCompletionText("Current pantry counts kept unchanged")).font(.headline)
                    ForEach(Array(review.preservedCountNames.enumerated()), id: \.offset) { _, name in Text(name) }
                }
                ForEach(Array(review.restoredInputs.enumerated()), id: \.offset) { _, input in
                    LabeledContent(input.name, value: pantryCount(input.count))
                }
                ForEach(Array(review.removedLeftovers.enumerated()), id: \.offset) { _, name in
                    Text(cookCompletionText("Remove leftover batch") + ": " + name)
                }
                Text(cookCompletionText("Confirm only after checking these quantities now. The restored counts will be recorded as confirmed now, not as a fresh copy of the old check."))
            }
            CookCompletionNotice(model: model)
            Section {
                Button(cookCompletionText(model.attemptedUndo ? "Retry the same Undo" : "Confirm Undo")) { Task { await model.confirmUndo() } }
                    .disabled(!model.canConfirmUndo).accessibilityIdentifier("cook.undo.confirm")
                if model.attemptedUndo {
                    Button(cookCompletionText("Check saved completion")) { Task { await model.reload() } }.disabled(model.busy)
                } else {
                    Button(cookCompletionText("Keep cooking record")) { model.cancelUndo() }.disabled(model.busy)
                }
            }
        }.navigationTitle(cookCompletionText("Review Undo"))
    }
}

private struct CookCompletionNotice: View {
    @ObservedObject var model: CookCompletionEditorModel
    var body: some View {
        if let notice = model.notice {
            Text(cookNoticeText(notice)).accessibilityIdentifier("cook.status")
        }
        if model.busy { ProgressView(cookCompletionText("Working…")) }
    }
}
private func cookUseText(_ use: CookCompletionDraft.Part.Use, lots: [InventoryLot], recorded: Bool = false) -> String {
    switch use {
    case .notUsed: cookCompletionText("Not used")
    case .untracked: cookCompletionText(recorded ? "Food was untracked when cooking; see any later ingredient-use correction." : "Used food not tracked in this pantry — unresolved")
    case .lot(let id, _, let amount):
        (lots.first(where: { $0.id == id })?.name ?? cookCompletionText("Selected batch")) + " · " +
            (amount.map { pantryQuantity($0) } ?? cookCompletionText(recorded ? "Use was unmeasured when cooking; see any later ingredient-use correction." : "Used an unmeasured amount — remaining count becomes unknown"))
    }
}
private func cookNoticeText(_ notice: CookCompletionEditorModel.Notice) -> String {
    switch notice {
    case .unavailable: cookCompletionText("Current details could not be verified. Reopen or reload this dinner.")
    case .invalidEntry: cookCompletionText("Review every ingredient, enter positive known amounts and servings, and confirm whether leftovers remain.")
    case .reviewChanged: cookCompletionText("Counts, preferences or the dinner changed, or a unit could not be converted. Reload and review. A newer count may already include this cooking.")
    case .insufficientStock: cookCompletionText("The measured use exceeds available stock. Review the actual count and held portions, or record the use as unmeasured or untracked.")
    case .uncertain: cookCompletionText("This confirmation may have saved. Retry the same confirmation or check the saved completion before making another change.")
    case .saved: cookCompletionText("Cooking and its reviewed inventory changes were saved together.")
    case .undoChanged: cookCompletionText("Undo could not be reviewed. Counts, leftovers or holds may have changed. Reload the saved cooking record; newer food changes will not be overwritten.")
    case .undoUncertain: cookCompletionText("Undo may have saved. Retry the same Undo or check the saved completion before recording cooking again.")
    case .undone: cookCompletionText("Cooking was undone. Review every ingredient again before recording another completion.")
    case .undoIndependentCount(let name):
        cookCompletionText("Undo is unavailable because a later physical count must be preserved. Review the current food instead.") + (name.map { " · " + $0 } ?? "")
    case .undoAmendedInputChanged(let name):
        cookCompletionText("A later change affected food used by this cooking. Undo cannot overwrite its current pantry record.") + (name.map { " · " + $0 } ?? "")
    }
}
