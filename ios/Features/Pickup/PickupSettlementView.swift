import SwiftUI
import CoreDomain

struct PickupSettlementView: View {
    @ObservedObject var model: PickupModel
    @State private var kind: SettlementKind = .postedCharge
    @State private var amount = ""
    @State private var evidence = ""
    @State private var creditID = ""
    @State private var charge = ""
    @State private var date = Date()
    @State private var entryID = UUID()
    private var isCredit: Bool { [.pendingCredit, .postedCredit, .includedCredit].contains(kind) }
    @State private var nextShopRequested = false
    @AccessibilityFocusState private var nextShopFocused: Bool
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            if let summary = try? model.journey?.settlement.summary() {
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
                PickupEvidenceField(title: "Amount", amount: $amount)
                TextField(pTr("Unique receipt or transaction evidence ID"), text: $evidence)
                if isCredit {
                    TextField(pTr("Credit identity (same for pending and posted)"), text: $creditID)
                    Picker(pTr("Original posted charge"), selection: $charge) {
                        Text(pTr("Choose a charge")).tag("")
                        ForEach(model.journey?.settlement.entries.filter { [.postedCharge, .postedTopUp].contains($0.kind) } ?? []) { entry in Text("\(entry.evidenceKey) · \(pMoney(entry.amount))").tag(entry.evidenceKey) }
                    }
                }
                if kind == .holdRelease {
                    Picker(pTr("Original payment hold"), selection: $charge) {
                        Text(pTr("Choose a hold")).tag("")
                        ForEach(model.journey?.settlement.entries.filter { $0.kind == .paymentHold } ?? []) { entry in
                            Text("\(entry.evidenceKey) · \(pMoney(entry.amount))").tag(entry.evidenceKey)
                        }
                    }
                }
                DatePicker(pTr("Evidence date"), selection: $date)
                Button(pTr("Save financial evidence")) { save() }
            }
            Section(pTr("Saved financial records")) {
                ForEach(model.journey?.settlement.entries ?? []) { entry in
                    VStack(alignment: .leading) {
                        Text("\(pTr(entry.kind.rawValue)) · \(pMoney(entry.amount))")
                        Text(entry.evidenceKey).font(.caption)
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
        .modifier(PickupNextShopRoute(model: model, requested: $nextShopRequested) { nextShopFocused = true })
            .disabled(model.saving)
    }
    private func save() {
        do {
            guard let money = try ComparisonModel.money(amount), !evidence.isEmpty,
                  !isCredit || (!creditID.isEmpty && !charge.isEmpty) else { throw CocoaError(.validationMissingMandatoryProperty) }
            let entry = SettlementEntry(id: entryID, evidenceKey: evidence, kind: kind, amount: money, occurredAt: date, creditID: isCredit ? creditID : nil, chargeEvidenceKey: isCredit ? charge : nil, holdEvidenceKey: kind == .holdRelease ? charge : nil)
            Task { if await model.settle(entry) { entryID = UUID(); amount = ""; evidence = "" } }
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
        Form {
            PickupSaveStatus(model: model)
            Text(pTr("Review each carryover. The new draft clears old prices, quotes, offers and checkout status. Prior history stays intact."))
            ForEach(source.deferred.filter { $0.status == "review" }) { need in
                Section(need.line.name) {
                    Text(pQuantity(need.line.quantity))
                    Picker(pTr("For this trip"), selection: Binding(get: { choices[need.id] ?? .keep }, set: { choices[need.id] = $0 })) {
                        Text(pTr("Keep deferred")).tag(NextShopDisposition.keep)
                        Text(pTr("Accept into the next draft and reprice")).tag(NextShopDisposition.accept)
                        Text(pTr("Already handled · no new purchase")).tag(NextShopDisposition.handled)
                        Text(pTr("Dismiss this need")).tag(NextShopDisposition.dismissed)
                    }
                }
            }
            NavigationLink(HistoryCopy.text("Family decision history")) { FamilyDecisionsEntry(localShopID: source.id) }
            Section(pTr("Open meal needs")) {
                ForEach(source.urgent.filter { !$0.resolved }) { need in
                    Text("\(need.meal): \(need.food) · \(pQuantity(need.required))")
                }
                if model.journey?.id == source.id {
                    ForEach(model.allocation?.demands.filter { $0.shortfall != .zero } ?? []) { coverage in
                        Text(source.needs.first { $0.id == coverage.id }?.name ?? pTr("Open meal need"))
                    }
                }
                Text(pTr("Prior receipts and money remain with the previous pickup for review."))
            }
            Button(pTr("Create fresh next-shop draft")) {
                Task {
                    let accepted = Set(choices.filter { $0.value == .accept }.keys)
                    let closing = choices.filter { $0.value == .handled || $0.value == .dismissed }
                    _ = await model.startNextShop(accept: accepted, closing: closing, sourceID: source.id, sourceRevision: source.revision)
                }
            }.buttonStyle(.borderedProminent).disabled(model.saving || model.hasPendingSave)
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
