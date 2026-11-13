import SwiftUI
import CoreDomain

struct PickupSettlementView: View {
    @ObservedObject var model: PickupModel
    @State private var kind: SettlementKind = .postedCharge
    @State private var amount = ""
    @State private var evidence = ""
    @State private var creditID = ""
    @State private var charge = ""
    @State private var holdKey = ""
    private enum Field { case amount, evidence, creditID }
    @FocusState private var field: Field?
    @State private var date = Date()
    @State private var entryID = UUID()
    private var isCredit: Bool { [.pendingCredit, .postedCredit, .includedCredit].contains(kind) }
    private var pendingCredits: [SettlementEntry] {
        let entries = model.journey?.settlement.entries ?? []
        let settled = Set(entries.filter { [.postedCredit, .includedCredit].contains($0.kind) }.compactMap(\.creditID))
        return entries.filter { entry in
            entry.kind == .pendingCredit && entry.occurredAt <= model.stockReviewDate && entry.chargeEvidenceKey == charge &&
                entry.creditID.map { !settled.contains($0) } == true
        }
    }
    private var openHolds: [SettlementEntry] {
        let entries = model.journey?.settlement.entries ?? []
        let released = Set(entries.compactMap(\.holdEvidenceKey))
        return entries.filter { $0.kind == .paymentHold && $0.occurredAt <= model.stockReviewDate && !released.contains($0.evidenceKey) }
    }
    private var selectedHold: SettlementEntry? { openHolds.first { $0.evidenceKey == holdKey } }
    @State private var nextShopRequested = false
    @AccessibilityFocusState private var nextShopFocused: Bool
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            if let summary = try? model.journey?.settlement.summary(asOf: model.stockReviewDate) {
                Section(pTr("Actual money · separate from food")) {
                    LabeledContent(pTr("Paid so far"), value: pMoney(summary.paidSoFar))
                    LabeledContent(pTr("Pending credits · not deducted"), value: pMoney(summary.pendingCredits))
                    LabeledContent(pTr("Credits already included in charges"), value: pMoney(summary.includedCredits))
                    LabeledContent(pTr("Payment holds · not spending"), value: pMoney(summary.paymentHolds))
                    Text(pTr("A credit does not add food or repair a meal. A credit already included in a net charge is not subtracted again."))
                }
            }
            if let journey = model.journey, let workspaceID = model.sourceWorkspaceID {
                NavigationLink(captureText("Receipt photos and reviewed lines")) {
                    PrivateSourceReferenceEntry(target: CaptureTarget(workspaceID: workspaceID,
                        containerID: journey.id, objectID: journey.id, revision: journey.revision, kind: .receiptEvidence),
                        initialLabel: captureText("Receipt source"), sourceCurrent: {
                            model.ready && !model.saving && !model.hasPendingSave && model.sourceWorkspaceID == workspaceID &&
                            model.journey?.id == journey.id && model.journey?.revision == journey.revision
                        })
                }.accessibilityIdentifier("pickup.scanReceipt")
            }
            Section(pTr("Record evidence")) {
                Picker(pTr("Record type"), selection: $kind) {
                    Text(pTr("Posted charge")).tag(SettlementKind.postedCharge)
                    Text(pTr("Posted top-up purchase")).tag(SettlementKind.postedTopUp)
                    Text(pTr("Payment hold")).tag(SettlementKind.paymentHold)
                    Text(pTr("Confirmed full hold release")).tag(SettlementKind.holdRelease)
                    Text(pTr("Pending credit")).tag(SettlementKind.pendingCredit)
                    Text(pTr("Posted credit")).tag(SettlementKind.postedCredit)
                    Text(pTr("Credit already included in net charge")).tag(SettlementKind.includedCredit)
                }
                if kind == .holdRelease {
                    Picker(pTr("Original payment hold"), selection: $holdKey) {
                        Text(pTr("Choose a hold")).tag("")
                        ForEach(openHolds) { entry in
                            Text("\(entry.evidenceKey) · \(pMoney(entry.amount))").tag(entry.evidenceKey)
                        }
                    }
                    if let selectedHold { LabeledContent(pTr("Amount"), value: pMoney(selectedHold.amount)) }
                } else {
                    PickupEvidenceField(title: "Amount", amount: $amount).focused($field, equals: .amount)
                }
                TextField(pTr("Unique receipt or transaction evidence ID"), text: $evidence)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().focused($field, equals: .evidence)
                if isCredit {
                    Picker(pTr("Original posted charge"), selection: $charge) {
                        Text(pTr("Choose a charge")).tag("")
                        ForEach(model.journey?.settlement.entries.filter { [.postedCharge, .postedTopUp].contains($0.kind) && $0.occurredAt <= model.stockReviewDate } ?? []) { entry in Text("\(entry.evidenceKey) · \(pMoney(entry.amount))").tag(entry.evidenceKey) }
                    }
                    if [.postedCredit, .includedCredit].contains(kind), !pendingCredits.isEmpty {
                        Picker(financialText("Credit being settled"), selection: Binding(
                            get: { pendingCredits.contains { $0.creditID == creditID } ? creditID : "" },
                            set: { creditID = $0 }
                        )) {
                            Text(financialText("A separate credit")).tag("")
                            ForEach(pendingCredits) { pending in
                                if let id = pending.creditID {
                                    Text("\(id) · \(pending.evidenceKey) · \(pMoney(pending.amount))").tag(id)
                                }
                            }
                        }
                    }
                    TextField(pTr("Credit identity (same for pending and posted)"), text: $creditID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($field, equals: .creditID)
                }
                DatePicker(pTr("Evidence date"), selection: $date, in: ...model.stockReviewDate)
                Button(pTr("Save financial evidence")) { save() }
                    .disabled(model.hasPendingSave || (kind == .holdRelease && selectedHold == nil))
            }
            Section(pTr("Saved financial records")) {
                ForEach(model.journey?.settlement.entries ?? []) { entry in
                    VStack(alignment: .leading) {
                        Text("\(pTr(entry.kind.rawValue)) · \(pMoney(entry.amount))")
                        Text(entry.evidenceKey).font(.caption)
                        LabeledContent(pTr("Evidence date")) {
                            Text(entry.occurredAt, format: .dateTime.month().day().year().hour().minute())
                        }
                        if entry.occurredAt > model.stockReviewDate {
                            Text(pTr("This entry is dated later and is excluded from these totals."))
                        }
                        if let id = entry.creditID {
                            LabeledContent(pTr("Credit ID"), value: id)
                        }
                        if let original = entry.chargeEvidenceKey {
                            LabeledContent(pTr("Original posted charge"), value: original)
                        } else if let hold = entry.holdEvidenceKey {
                            LabeledContent(pTr("Original payment hold"), value: hold)
                        }
                    }
                }
            }
            Section {
                Text(pTr("Closing preserves unresolved meal needs and pending credits for later correction. Feedback is optional."))
                if let current = model.journey, current.pickup != nil || current.basket == nil, current.closedAt == nil {
                    Button(pTr("Close this pickup")) {
                        Task { await model.change { value in
                            guard value.id == current.id, value.closedAt == nil else { throw CocoaError(.validationMissingMandatoryProperty) }
                            value.closedAt = Date()
                        } }
                    }.buttonStyle(.borderedProminent)
                }
                if let closed = model.journey?.closedAt { Text("\(pTr("Closed")): \(closed.formatted())") }
                Button(pTr("Review next shop")) { nextShopRequested = true }.accessibilityFocused($nextShopFocused)
            }
            if let journey = model.journey { PickupFeedbackSection(model: model, journey: journey) }
        }.navigationTitle(pTr("Close the pickup"))
        .keyboardDoneAction(visible: field != nil, title: pTr("Done"), identifier: "pickup.settlement.doneTyping") { field = nil }
        .onChange(of: kind) { _, _ in
            holdKey = ""
            charge = ""
            creditID = ""
        }
        .onChange(of: charge) { previous, _ in
            if !previous.isEmpty { creditID = "" }
        }
        .modifier(PickupNextShopRoute(model: model, requested: $nextShopRequested) { nextShopFocused = true })
            .disabled(model.saving)
    }
    private func save() {
        do {
            let recordedAmount = kind == .holdRelease ? selectedHold?.amount : try ComparisonModel.money(amount)
            guard let money = recordedAmount, !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !isCredit || (!creditID.isEmpty && !charge.isEmpty) else { throw CocoaError(.validationMissingMandatoryProperty) }
            let entry = SettlementEntry(id: entryID, evidenceKey: evidence, kind: kind, amount: money, occurredAt: date, creditID: isCredit ? creditID : nil, chargeEvidenceKey: isCredit ? charge : nil, holdEvidenceKey: kind == .holdRelease ? selectedHold?.evidenceKey : nil)
            Task {
                if await model.settle(entry) {
                    entryID = UUID()
                    amount = ""
                    evidence = ""
                    holdKey = ""
                    charge = ""
                    creditID = ""
                    field = nil
                }
            }
        } catch { model.error = pTr("Enter a valid amount and evidence ID. Credits must link to an original posted charge.") }
    }
}

/// The shopper can cancel the selection sheet until the new draft has been saved.
/// Subsequent list, dinner and staple work uses the ordinary pushed navigation stack.
struct PickupNextShopRoute: ViewModifier {
    @ObservedObject var model: PickupModel
    @Binding var requested: Bool
    let restoreFocus: () -> Void
    @State private var review: PickupJourney?
    @State private var openedDraft: UUID?
    @State private var savedID: UUID?

    func body(content: Content) -> some View {
        content.onChange(of: requested) { _, launch in
            guard launch else { return }
            requested = false
            guard let source = model.journey else { return }
            if source.originShopID != nil, source.context == nil {
                openedDraft = source.id
            } else if let existing = model.journeys.first(where: { $0.originShopID == source.id }) {
                model.selectedID = existing.id
                openedDraft = existing.id
            } else {
                review = source
            }
        }
        .sheet(item: $review, onDismiss: {
            if let id = savedID { savedID = nil; openedDraft = id }
            else { restoreFocus() }
        }) { source in
            NavigationStack {
                PickupNextShopSelection(model: model, source: source) { id in
                    savedID = id
                    review = nil
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(tr("Cancel")) { review = nil }.disabled(model.saving || model.hasPendingSave)
                    }
                }
            }.presentationDetents([.large]).interactiveDismissDisabled(model.saving || model.hasPendingSave)
        }
        .navigationDestination(item: $openedDraft) { id in
            if model.journey?.id == id { PickupNextShopDraft(model: model, journeyID: id) }
        }
    }
}

private struct PickupNextShopSelection: View {
    @ObservedObject var model: PickupModel
    let source: PickupJourney
    let didSave: (UUID) -> Void
    @State private var choices: [UUID: NextShopDisposition] = [:]

    var body: some View {
        let remaining = try? source.nextShopMealNeeds(closing: choices, at: model.stockReviewDate)
        return Form {
            PickupSaveStatus(model: model)
            Text(pTr("Review each carryover. The new draft clears old prices, quotes, offers and checkout status. Prior history stays intact."))
            ForEach(source.deferred.filter { $0.status == "review" }) { need in
                Section(header: Text(need.line.name).foregroundStyle(Theme.secondary)) {
                    Text(pQuantity(need.line.quantity))
                    Picker(pTr("For this trip"), selection: Binding(get: { choices[need.id] ?? .keep }, set: { choices[need.id] = $0 })) {
                        Text(pTr("Keep deferred")).tag(NextShopDisposition.keep)
                        Text(pTr("Accept into the next draft and reprice")).tag(NextShopDisposition.accept)
                        Text(pTr("Already handled · no new purchase")).tag(NextShopDisposition.handled)
                        Text(pTr("Dismiss this need")).tag(NextShopDisposition.dismissed)
                    }
                    if (choices[need.id] ?? .keep) == .keep, let workspaceID = model.sourceWorkspaceID {
                        ContextualReminderLink(request: .init(target: .deferral(workspaceID: workspaceID, journeyID: source.id, needID: need.id),
                            sourceRevision: source.revision, sourceSavedAt: source.savedAt))
                            .disabled(model.saving || model.hasPendingSave)
                    }
                }
            }
            NavigationLink(HistoryCopy.text("Family decision history")) { FamilyDecisionsEntry(localShopID: source.id) }
            Section(header: Text(pTr("Open meal needs")).foregroundStyle(Theme.secondary)) {
                if let remaining {
                    ForEach(remaining.urgent) { need in
                        Text("\(need.meal): \(need.food) · \(pQuantity(need.required))")
                        if remaining.unverified.contains(need.id) { Text(pTr("Short or unverified amount. Review.")) }
                        if let due = need.due { LabeledContent(pTr("Needed by"), value: due.formatted()) }
                    }
                    ForEach(remaining.meals) { need in
                        Text("\(need.name) · \(pQuantity(need.amount))")
                        if remaining.unverified.contains(need.id) { Text(pTr("Short or unverified amount. Review.")) }
                        if let due = source.savedMealDeadline(for: need.id) { LabeledContent(pTr("Needed by"), value: due.formatted()) }
                    }
                } else {
                    Text(pTr("Could not prepare this change. Your saved pickup has not changed."))
                }
                Text(pTr("Prior receipts and money remain with the previous pickup for review."))
            }
            Button(pTr("Create fresh next-shop draft")) {
                Task {
                    guard let remaining else { return }
                    let accepted = Set(choices.filter { $0.value == .accept }.keys)
                    let closing = choices.filter { $0.value == .handled || $0.value == .dismissed }
                    _ = await model.startNextShop(accept: accepted, closing: closing, sourceID: source.id, sourceRevision: source.revision, reviewedMeals: remaining)
                }
            }.buttonStyle(.borderedProminent).disabled(remaining == nil || model.saving || model.hasPendingSave)
        }
        .navigationTitle(pTr("Next shop"))
        .onChange(of: model.selectedID) { _, newID in
            // A retried store write can also finish this exact creation.
            if let id = newID, model.journey?.originShopID == source.id { didSave(id) }
        }
    }
}

private struct PickupNextShopDraft: View {
    @ObservedObject var model: PickupModel
    let journeyID: UUID
    @Environment(\.pickupLedger) private var ledger

    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            Text(pTr("Fresh draft saved. Review its store, slot and prices before checkout."))
            if let journey = model.journey { PickupSavedStockSection(model: model, journey: journey) }
            if let ledger {
                NavigationLink(pTr("Open next shopping list")) {
                    PickupListBridgeView(model: model, ledger: ledger, journeyID: journeyID)
                }.accessibilityIdentifier("pickupOpenCreatedNextList")
                NavigationLink(dinnerText("Accepted dinners and Free reusable dinner")) {
                    NextShopDinnerContextEntry(pickup: model, ledger: ledger, journeyID: journeyID)
                }.accessibilityIdentifier("nextShop.reuseDinner")
                NavigationLink(ledgerText("Review prior staples")) {
                    PickupListBridgeView(model: model, ledger: ledger, journeyID: journeyID, reviewStaples: true)
                }
            } else { Text(pTr("Return to Shop to open the editable list for this saved draft.")) }
            NavigationLink(HistoryCopy.text("Family decision history")) { FamilyDecisionsEntry(localShopID: journeyID) }
        }.navigationTitle(pTr("Next shop"))
    }
}
