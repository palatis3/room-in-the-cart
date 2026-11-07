import SwiftUI
import CoreDomain

private func changeText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "OneChange")
}

struct OneChangeDraft {
    var change = ""
    var branch = ""
    var source = ""
    var observed = Date()
    var slot: Date?
    var before = ""
    var after = ""
    var cap = ""
    var beforeIncludesCharges = false
    var afterIncludesCharges = false
    var samePickup = false

    @MainActor func review(in ledger: LedgerModel) throws -> OneChangeReview {
        let name = change.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !location.isEmpty, !evidence.isEmpty, samePickup,
              ledger.ready, ledger.shop == nil, let workspaceID = ledger.sourceWorkspaceID else {
            throw CheckoutError.incomparableBasis
        }
        let id = UUID()
        let beforeObservation = LedgerCheckoutChange.Observation(amount: try ComparisonModel.money(before), includesAllCharges: beforeIncludesCharges)
        let afterObservation = LedgerCheckoutChange.Observation(amount: try ComparisonModel.money(after), includesAllCharges: afterIncludesCharges)
        let preview = LedgerRetailerPreview(total: afterObservation.confirmedTotal, source: evidence, capturedAt: observed,
            includedCharges: afterIncludesCharges ? [changeText("All items, fees, discounts, tax and deposits")] : [])
        let basis = ShopBasis(branch: location, slot: slot, cap: try ComparisonModel.money(cap), retailerPreview: preview)
        let proof = LedgerCheckoutChange(name: name, basis: basis, before: beforeObservation, after: afterObservation)
        let comparison = try proof.comparison(for: id)
        let shop = ShoppingLedger(id: id, title: name, basis: basis, initialCheckoutChange: proof)
        return OneChangeReview(shop: shop, proof: proof, comparison: comparison, workspaceID: workspaceID, revision: ledger.revision)
    }
}

struct OneChangeReview: Identifiable {
    let shop: ShoppingLedger
    let proof: LedgerCheckoutChange
    let comparison: CheckoutComparison
    let workspaceID: UUID
    let revision: Int64
    var id: UUID { shop.id }

    var requiresOverageAgreement: Bool {
        if case .over = comparison.after.cap { return true }
        return false
    }

    @MainActor func save(in ledger: LedgerModel, acceptedOverageFor reviewID: UUID? = nil) async -> Bool {
        guard !requiresOverageAgreement || reviewID == id else { return false }
        guard ledger.sourceWorkspaceID == workspaceID else { return false }
        return await ledger.change(key: "one-change-\(id)") { workspace in
            guard workspace.selectedShopID == nil, ledger.revision == revision else { throw LedgerError.stalePreview }
            workspace.shops.append(shop)
            workspace.selectedShopID = id
        }
    }
}

struct CheckOneChangeView: View {
    static var title: String { changeText("Check one change") }
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var pickup: PickupModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = OneChangeDraft()
    @State private var review: OneChangeReview?
    @State private var savedChoiceID: UUID?
    @State private var acceptedOverageID: UUID?
    @State private var error: String?
    @FocusState private var field: String?

    var body: some View {
        Group {
            if let shop = ledger.shop, shop.id == savedChoiceID {
                List {
                    Section(changeText("Pickup draft saved")) {
                        Text(shop.title)
                        Text(shop.basis.branch)
                        LabeledContent(pTr("Retailer preview total"), value: shop.basis.retailerPreview?.total.map(pMoney) ?? pTr("Unresolved"))
                    }
                    Button(pTr("Done")) { dismiss() }.accessibilityIdentifier("oneChange.finish")
                }.navigationTitle(Self.title).navigationBarTitleDisplayMode(.inline)
            } else if ledger.shop != nil {
                LedgerCheckoutEntry(ledger: ledger, pickup: pickup)
            } else {
                Form {
                    contextFields
                    pricingFields
                    Section {
                        Button(changeText("Review this change")) {
                            field = nil
                            do { review = try draft.review(in: ledger); self.error = nil }
                            catch { self.error = changeText("Check the change, store, source and USD amounts, and confirm the previews cover the same pickup.") }
                        }.disabled(!ledger.ready || ledger.hasPendingSave)
                            .accessibilityIdentifier("oneChange.review")
                        if let error { Text(error).foregroundStyle(Theme.warning) }
                        Button(changeText("Leave without saving")) { dismiss() }
                    }
                    if ledger.error != nil || ledger.hasPendingSave { LedgerSaveStatus(model: ledger) }
                }
                .navigationTitle(Self.title)
                .navigationBarTitleDisplayMode(.inline)
                .scrollDismissesKeyboard(.interactively)
                .keyboardDoneAction(visible: field != nil, title: pTr("Done"), identifier: "oneChange.done") { field = nil }
                .onChange(of: draft.before) { draft.beforeIncludesCharges = false }
                .onChange(of: draft.after) { draft.afterIncludesCharges = false }
                .onChange(of: draft.change) { invalidateBasis() }
                .onChange(of: draft.branch) { invalidateBasis() }
                .onChange(of: draft.slot) { invalidateBasis() }
                .onChange(of: draft.source) { invalidateBasis() }
                .onChange(of: draft.observed) { invalidateBasis() }
            }
        }
        .task { await ledger.open() }
        .sheet(item: $review) { frozen in
            NavigationStack {
                List {
                    OneChangeEvidence(proof: frozen.proof, comparison: frozen.comparison)
                    Section {
                        Text(changeText("Save both retailer previews in a private draft named for this change. You can add the shopping list later."))
                        if frozen.requiresOverageAgreement {
                            Toggle(changeText("I accept this overage for this draft."), isOn: Binding(
                                get: { acceptedOverageID == frozen.id }, set: { acceptedOverageID = $0 ? frozen.id : nil }))
                                .accessibilityIdentifier("oneChange.acceptOverage")
                        }
                        Button(changeText("Save changed preview as a new pickup")) {
                            savedChoiceID = frozen.id
                            Task { if await frozen.save(in: ledger, acceptedOverageFor: acceptedOverageID) { review = nil } }
                        }.disabled(ledger.saving || ledger.hasPendingSave
                                   || (frozen.requiresOverageAgreement && acceptedOverageID != frozen.id)
                                   || ledger.revision != frozen.revision || ledger.sourceWorkspaceID != frozen.workspaceID)
                        .accessibilityIdentifier("oneChange.save")
                        if ledger.hasPendingSave || ledger.error != nil { LedgerSaveStatus(model: ledger) { review = nil } }
                    }
                }.navigationTitle(changeText("Review this change")).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) {
                        Button(pTr("Cancel preview")) { review = nil }
                    } }
            }
        }
    }

    private var contextFields: some View {
        Section(changeText("Compare two retailer previews")) {
            Text(changeText("Check one proposed change using the checkout totals shown by the retailer before and after it."))
            changeField(changeText("Proposed change"), $draft.change, id: "change")
            changeField(changeText("Store and branch"), $draft.branch, id: "branch")
            changeField(changeText("Source of these prices"), $draft.source, id: "source")
            DatePicker(pTr("Observed"), selection: $draft.observed)
            Toggle(changeText("Record the pickup date and time"), isOn: Binding(
                get: { draft.slot != nil }, set: { draft.slot = $0 ? Date() : nil }))
            if let slot = Binding($draft.slot) { DatePicker(pTr("Pickup or delivery slot"), selection: slot) }
        }
    }

    private var pricingFields: some View {
        Section(pTr("Whole checkout")) {
            changeField(changeText("Current checkout total in USD"), $draft.before, id: "before", money: true)
            Toggle(changeText("Current total includes every item and charge"), isOn: $draft.beforeIncludesCharges)
                .accessibilityIdentifier("oneChange.beforeIncludesCharges")
            changeField(changeText("Changed checkout total in USD"), $draft.after, id: "after", money: true)
            Toggle(changeText("Changed total includes every item and charge"), isOn: $draft.afterIncludesCharges)
                .accessibilityIdentifier("oneChange.afterIncludesCharges")
            Text(changeText("Check fees, promotions, discounts, tax and deposits on each preview. Leave an unknown amount blank."))
            changeField(changeText("Firm whole-pickup cap in USD, optional"), $draft.cap, id: "cap", money: true)
            Toggle(changeText("Both previews use the same pickup slot and keep the other quantities and protected portions."), isOn: $draft.samePickup)
                .accessibilityIdentifier("oneChange.samePickup")
        }
    }

    private func invalidateBasis() {
        draft.samePickup = false
        draft.beforeIncludesCharges = false
        draft.afterIncludesCharges = false
    }

    private func changeField(_ title: String, _ value: Binding<String>, id: String, money: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: value)
                .keyboardType(money ? .decimalPad : .default)
                .focused($field, equals: id)
                .accessibilityIdentifier("oneChange." + id)
        }
    }
}

struct SavedCheckoutChangeView: View {
    static var title: String { changeText("Saved checkout change") }
    let proof: LedgerCheckoutChange
    let shopID: UUID
    var body: some View {
        List {
            if let comparison = try? proof.comparison(for: shopID) {
                OneChangeEvidence(proof: proof, comparison: comparison)
            } else { Text(changeText("The saved comparison could not be verified.")) }
        }.navigationTitle(Self.title).navigationBarTitleDisplayMode(.inline)
    }
}

private struct OneChangeEvidence: View {
    let proof: LedgerCheckoutChange
    let comparison: CheckoutComparison
    var body: some View {
        Section(proof.name) {
            Text(proof.basis.branch)
            Text(proof.basis.slot.map { ledgerDate($0, zone: proof.basis.timeZoneIdentifier) }
                 ?? changeText("Same pickup slot, time unrecorded"))
            if let evidence = proof.basis.retailerPreview {
                Text(evidence.source)
                Text(ledgerDate(evidence.capturedAt, zone: proof.basis.timeZoneIdentifier))
            }
            if let cap = proof.basis.cap { LabeledContent(pTr("Spending cap"), value: pMoney(cap)) }
        }
        observation(changeText("Before this change"), proof.before, result: comparison.before)
        observation(changeText("After this change"), proof.after, result: comparison.after)
        if let delta = comparison.change {
            LabeledContent(changeText("Change in checkout total"), value: pMoney(delta))
                .accessibilityIdentifier("oneChange.difference")
        } else { Text(changeText("The difference is unresolved.")) }
    }

    private func observation(_ title: String, _ observation: LedgerCheckoutChange.Observation, result: CheckoutResult) -> some View {
        Section(title) {
            if let amount = observation.amount, !observation.includesAllCharges {
                LabeledContent(changeText("Amount shown by retailer"), value: pMoney(amount))
            }
            Text(observation.includesAllCharges ? changeText("All items, fees, discounts, tax and deposits")
                 : changeText("Included charges have not been confirmed.")).font(.footnote)
            PickupResultView(result: result)
        }
    }
}
