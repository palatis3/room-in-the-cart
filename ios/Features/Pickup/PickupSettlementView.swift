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
                Button(pTr("Close this pickup")) { Task { await model.change { $0.closedAt = Date() } } }.buttonStyle(.borderedProminent)
                if let closed = model.journey?.closedAt { Text("\(pTr("Closed")): \(closed.formatted())") }
                NavigationLink(pTr("Review next shop")) { PickupNextShopView(model: model) }
            }
        }.navigationTitle(pTr("Close the pickup"))
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

struct PickupNextShopView: View {
    @ObservedObject var model: PickupModel
    @Environment(\.pickupLedger) private var ledger
    @State private var accepted: Set<UUID> = []
    @State private var created = false
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            Text(pTr("Review each carryover. The new draft clears old prices, quotes, offers and checkout status. Prior history stays intact."))
            ForEach(model.journey?.deferred.filter { $0.status == "review" } ?? []) { need in
                Section(need.line.name) {
                    Text(pQuantity(need.line.quantity))
                    Toggle(pTr("Accept into the next draft and reprice"), isOn: Binding(get: { accepted.contains(need.id) }, set: { if $0 { accepted.insert(need.id) } else { accepted.remove(need.id) } }))
                    Button(pTr("Already handled · no new purchase")) { update(need.id, "handled") }
                    Button(pTr("Dismiss this need")) { update(need.id, "dismissed") }
                    Text(pTr("Leave unchecked to keep deferred."))
                }
            }
            Section(pTr("Open meal needs")) {
                ForEach(model.journey?.urgent.filter { !$0.resolved } ?? []) { need in
                    Text("\(need.meal): \(need.food) · \(pQuantity(need.required))")
                }
                ForEach(model.allocation?.demands.filter { $0.shortfall != .zero } ?? []) { coverage in
                    Text(model.journey?.needs.first { $0.id == coverage.id }?.name ?? pTr("Open meal need"))
                }
                Text(pTr("Prior receipts and money remain with the previous pickup for review."))
            }
            Button(pTr("Create fresh next-shop draft")) { Task { created = await model.startNextShop(accept: accepted) } }.buttonStyle(.borderedProminent).disabled(created)
            if created {
                Text(pTr("Fresh draft saved. Review its store, slot and prices before checkout."))
                if let ledger, let journeyID = model.journey?.id {
                    NavigationLink(pTr("Open next shopping list")) { PickupListBridgeView(model: model, ledger: ledger, journeyID: journeyID) }.accessibilityIdentifier("pickupOpenCreatedNextList")
                } else { Text(pTr("Return to Shop to open the editable list for this saved draft.")) }
            }
        }.navigationTitle(pTr("Next shop"))
            .onAppear { if model.journey?.originShopID != nil && model.journey?.context == nil { created = true } }
    }
    private func update(_ id: UUID, _ status: String) {
        Task { if await model.change({ value in if let index = value.deferred.firstIndex(where: { $0.id == id }) { value.deferred[index].status = status } }) { accepted.remove(id) } }
    }
}
