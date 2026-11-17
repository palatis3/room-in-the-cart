import SwiftUI
import CoreDomain

struct CookResolutionEntry: View {
    @ObservedObject var ledger: LedgerModel
    @ObservedObject var pickup: PickupModel
    let shopID: UUID
    let mealID: UUID
    let ingredientNames: [UUID: String]
    let authorize: @MainActor () -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var visible = false
    @StateObject private var model = CookResolutionEditorModel()
    var body: some View {
        Group {
            if !authorize() {
                Text(cookCompletionText("Private access changed. Reopen the cooking review."))
            } else if let review = model.review {
                resolutionReview(review)
            } else if let context = model.context {
                resolutionForm(context)
            } else {
                List {
                    CookResolutionNotice(model: model)
                    Button(cookCompletionText("Reload saved ingredient use")) { Task { await model.reload() } }.disabled(model.busy)
                }
            }
        }
        .navigationTitle(cookCompletionText("Review unresolved ingredient use"))
        .privacySensitive().interactiveDismissDisabled(model.busy)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(cookCompletionText(model.attempted ? "Close" : "Cancel")) { dismiss() }.disabled(model.busy)
            }
        }
        .task {
            visible = true
            let current = { visible && authorize() && !Task.isCancelled }
            let session = PantryCookSession(ledger: ledger, pickup: pickup, authorize: current)
            await model.open(session: session, shopID: shopID, mealID: mealID, authorize: current)
        }
        .onDisappear { visible = false; model.invalidate() }
    }
    private func eventName(_ id: UUID, in context: PantryCookResolution.Context) -> String {
        guard let part = context.record.draft.parts.first(where: { $0.id == id }) else { return cookCompletionText("Ingredient") }
        let name = ingredientNames[part.contributionID] ?? cookCompletionText("Ingredient")
        let number = context.record.draft.parts.filter { $0.contributionID == part.contributionID }.firstIndex { $0.id == id }.map { $0 + 1 } ?? 1
        return name + " · " + String(number)
    }
    private func resolutionForm(_ context: PantryCookResolution.Context) -> some View {
        Form {
            Section {
                Text(context.record.draft.cookedTitle).font(.headline)
                Text(cookCompletionText("The original cooking record stays unchanged. Review each unresolved use separately."))
                if context.remainingEventIDs.isEmpty {
                    Text(cookCompletionText("All ingredient-use reviews are saved.")).accessibilityIdentifier("cook.resolution.complete")
                }
            }
            if !context.remainingEventIDs.isEmpty {
                Section(cookCompletionText("Ingredient use to review")) {
                    Picker(cookCompletionText("Ingredient use"), selection: Binding(get: { model.eventID }, set: { model.selectEvent($0) })) {
                        ForEach(context.remainingEventIDs, id: \.self) { id in Text(eventName(id, in: context)).tag(Optional(id)) }
                    }.pickerStyle(.menu)
                    if let part = model.selectedPart {
                        if let name = part.substitution { Text(cookCompletionText("Actual substitution") + ": " + name) }
                        switch part.use {
                        case .untracked: Text(cookCompletionText("This use was not linked to a pantry batch."))
                        case .lot: Text(cookCompletionText("This use was unmeasured and belongs to the original selected batch."))
                        case .notUsed: EmptyView()
                        }
                    }
                    Picker(cookCompletionText("Batch to reconcile"), selection: Binding(get: { model.lotID }, set: { model.selectLot($0) })) {
                        Text(cookCompletionText("Choose a batch")).tag(UUID?.none)
                        ForEach(context.lots) { lot in
                            Text(lot.name + " · " + pantryLocationName(lot.location) + " · " + String(lot.id.uuidString.suffix(6))).tag(Optional(lot.id))
                        }
                    }.pickerStyle(.menu).disabled(model.batchIsFixed)
                    if let lot = model.selectedLot {
                        LabeledContent(cookCompletionText("Current pantry count"), value: pantryCount(lot.count))
                        Text(lot.confirmedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                    }
                }
                Section(cookCompletionText("What can you confirm?")) {
                    Picker(cookCompletionText("Choose a correction"), selection: $model.action) {
                        Text(cookCompletionText("Choose a correction")).tag(PantryCookResolution.Action?.none)
                        ForEach([PantryCookResolution.Action.outsidePantry, .alreadyIncluded, .deduct, .recount], id: \.self) { action in
                            if model.actions.contains(action) { Text(cookResolutionAction(action)).tag(Optional(action)) }
                        }
                    }.pickerStyle(.menu).accessibilityIdentifier("cook.resolution.action")
                    if let action = model.action {
                        Text(cookResolutionExplanation(action))
                        if action == .recount {
                            Text(cookCompletionText("Remaining quantity checked now"))
                            LedgerQuantityFields(amount: $model.remainingAmount, unit: $model.unit)
                        }
                        if action != .outsidePantry {
                            if action != .deduct { Toggle(cookCompletionText("I also know how much was used"), isOn: $model.usedKnown) }
                            if action == .deduct || model.usedKnown {
                                Text(cookCompletionText("Actual amount used"))
                                LedgerQuantityFields(amount: $model.usedAmount, unit: $model.unit)
                            }
                        }
                    }
                }
                Section {
                    Button(cookCompletionText("Review this ingredient-use correction")) { Task { await model.prepare() } }
                        .accessibilityIdentifier("cook.resolution.review")
                    Button(cookCompletionText("Discard this draft and reload current counts")) { Task { await model.reload() } }
                }
            }
            CookResolutionNotice(model: model)
        }.disabled(!model.canEdit)
    }
    private func resolutionReview(_ review: PantryCookResolution.Review) -> some View {
        List {
            Section(cookCompletionText("Review ingredient-use correction")) {
                Text(cookResolutionAction(review.decision.action)).font(.headline)
                Text(cookResolutionExplanation(review.decision.action))
                if let basis = review.reconstructionBasis {
                    LabeledContent(cookCompletionText("Original checked count before cooking"), value: pantryQuantity(basis))
                    if let reconstruction = review.reconstruction {
                        LabeledContent(cookCompletionText("Previously accounted use"), value: pantryQuantity(Quantity(amount: reconstruction.previouslyAccounted,
                            unit: reconstruction.original.unit, originalLiteral: reconstruction.previouslyAccounted.description)))
                        LabeledContent(cookCompletionText("Other unmeasured uses"), value: String(reconstruction.otherUnmeasured))
                    }
                    Text(cookCompletionText("This recorded use is combined with other reviewed uses from the same original count. The quantity stays unknown while another unmeasured use remains."))
                }
                if let before = review.before { LabeledContent(cookCompletionText("Before"), value: pantryCount(before)) }
                if let after = review.after { LabeledContent(cookCompletionText("After"), value: pantryCount(after)) }
                switch review.decision {
                case .outsidePantry: EmptyView()
                case .alreadyIncluded(_, let used), .recount(_, _, let used):
                    LabeledContent(cookCompletionText("Actual amount used"), value: pantryQuantity(used))
                case .deduct(_, let used): LabeledContent(cookCompletionText("Actual amount used"), value: pantryQuantity(used))
                }
            }
            Section(cookCompletionText("Held portions")) {
                ForEach(review.affectedHolds) { hold in
                    VStack(alignment: .leading) {
                        Text(model.context?.reservations.first { $0.id == hold.id }?.name ?? cookCompletionText("Held portion"))
                        LabeledContent(cookCompletionText("Backed after correction"), value: pantryQuantity(hold.backed))
                        LabeledContent(cookCompletionText("Shortfall after correction"), value: pantryQuantity(hold.shortfall))
                        if hold.unresolved { Text(cookCompletionText("This hold needs inventory review.")) }
                    }
                }
                if review.affectedHolds.isEmpty { Text(cookCompletionText("No other held portions change.")) }
                LabeledContent(cookCompletionText("Other uses still requiring individual review"), value: String(review.otherUnresolvedEventsForLot.count))
            }
            CookResolutionNotice(model: model)
            Section {
                Button(cookCompletionText(model.attempted ? "Retry the same correction" : "Confirm ingredient-use correction")) { Task { await model.confirm() } }
                    .disabled(model.busy || !model.hasAccess).accessibilityIdentifier("cook.resolution.confirm")
                if model.attempted {
                    Button(cookCompletionText("Reload saved ingredient use")) { Task { await model.reload() } }.disabled(model.busy)
                } else { Button(cookCompletionText("Keep editing")) { model.keepEditing() }.disabled(model.busy) }
            }
        }
    }
}
private struct CookResolutionNotice: View {
    @ObservedObject var model: CookResolutionEditorModel
    var body: some View {
        if model.busy { ProgressView(cookCompletionText("Working…")) }
        if let notice = model.notice {
            switch notice {
            case .unavailable: Text(cookCompletionText("Saved ingredient use could not be verified. Reload before making a correction."))
            case .invalid: Text(cookCompletionText("Choose an available correction and enter the amounts you actually checked."))
            case .changed: Text(cookCompletionText("The saved use, count or holds changed. Reload and review before confirming."))
            case .uncertain: Text(cookCompletionText("This correction may have saved. Retry the same correction or reload the saved ingredient use."))
            case .saved: Text(cookCompletionText("The ingredient-use correction was saved. The original cooking record is preserved."))
            }
        }
    }
}
func cookResolutionAction(_ action: PantryCookResolution.Action) -> String {
    switch action {
    case .outsidePantry: cookCompletionText("The food came from outside this pantry")
    case .alreadyIncluded: cookCompletionText("The current count already includes this use")
    case .deduct: cookCompletionText("Deduct a known amount from the supported earlier count")
    case .recount: cookCompletionText("Replace the count with the remaining quantity checked now")
    }
}
private func cookResolutionExplanation(_ action: PantryCookResolution.Action) -> String {
    switch action {
    case .outsidePantry: cookCompletionText("Confirm that this food was outside the tracked pantry. No pantry count changes.")
    case .alreadyIncluded: cookCompletionText("Confirm that the current checked count already includes this cooking use. It will not be deducted again.")
    case .deduct: cookCompletionText("This earlier count supports a deduction. Enter only the actual amount used in this event.")
    case .recount: cookCompletionText("Count what remains now, including the effect of all earlier uses. This replaces the pantry quantity; it does not subtract the cooking amount again or close other ingredient-use reviews.")
    }
}
