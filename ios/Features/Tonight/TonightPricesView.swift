import SwiftUI
import CoreDomain

struct TonightPricesView: View {
    let estimate: TonightPurchaseEstimate?
    var followsFirstMeal = false
    var hasHandCheckedIngredients = false
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let estimate, let subtotal = estimate.subtotal {
                LabeledContent(tonightText(estimate.complete ? "Estimated additional groceries" : "Priced groceries so far"),
                               value: dinnerMoney(subtotal))
                ForEach(estimate.packages) { line in
                    Text(verbatim: "\(line.package) × \(line.count.formatted()) · \(dinnerMoney(line.cost))")
                    Text(verbatim: "\(line.source) · \(line.observedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                }
                if hasHandCheckedIngredients {
                    Text(tonightText("This estimate includes measured ingredients only."))
                } else if estimate.packages.isEmpty {
                    Text(tonightText(followsFirstMeal ? "No extra packages are needed for the second meal." : "Confirmed pantry food covers these recipe amounts."))
                } else {
                    Text(tonightText("Based on observed package prices. Check current prices, fees and taxes at checkout."))
                }
            }
            if estimate?.complete != true {
                Text(tonightText("Some amounts or package prices still need review."))
            }
        }
        .accessibilityIdentifier("tonight.purchaseEstimate")
    }
}

struct SecondMealPricesView: View {
    let first: PantryMealMatcher.Review
    let second: PantryMealMatcher.Review
    let input: TonightMealModel.Input
    let workspaceID: UUID
    let ledgerRevision: Int64
    let pairingRevision: UUID

    var estimate: TonightPurchaseEstimate? {
        guard input.ledgerRevision == ledgerRevision else { return nil }
        return try? TonightPurchaseEstimate.estimate(second, after: first, workspace: input.workspace,
            workspaceID: workspaceID, shopID: input.workspace.selectedShopID, at: Date())
    }

    var body: some View {
        let estimate = estimate
        TonightPricesView(estimate: estimate, followsFirstMeal: true, hasHandCheckedIngredients: first.hasHandCheckedIngredients || second.hasHandCheckedIngredients)
        if let estimate { SecondMealCashReview(estimate: estimate).id(pairingRevision) }
    }
}

private struct SecondMealCashReview: View {
    let estimate: TonightPurchaseEstimate
    @State private var entered = ""
    @State private var allReviewed = false
    @State private var draft = ""
    @State private var draftReviewed = false
    @State private var editing = false

    private var hasPurchase: Bool { !estimate.complete || !estimate.packages.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            let charge = try? DinnerEntry.money(entered)
            if let charge {
                LabeledContent(tonightText("Added fees, tax and deposits"), value: dinnerMoney(charge))
            }
            if let total = try? estimate.additionalCash(addedCharges: charge, chargesComplete: allReviewed), let known = total.known {
                LabeledContent(tonightText(total.complete ? "Estimated additional cash" : "Known additional cash so far"),
                               value: dinnerMoney(known))
                    .accessibilityIdentifier("tonight.second.cash")
            }
            if hasPurchase {
                if !allReviewed { Text(tonightText("Additional charges still need review.")) }
                Button(tonightText("Review additional charges")) {
                    draft = entered
                    draftReviewed = allReviewed
                    editing = true
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("tonight.second.fees")
            }
        }
        .onChange(of: estimate) { _, _ in
            entered = ""
            allReviewed = false
            editing = false
        }
        .sheet(isPresented: $editing) {
            NavigationStack {
                WorkingForm {
                    Text(tonightText("Enter only fees, tax and deposits added by buying groceries for this second meal. Exclude charges already due for your shop."))
                    TextField(tonightText("Known added charges in USD"), text: $draft)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("tonight.second.feeAmount")
                    Text(tonightText("Enter 0 for no added charges. Leave blank if unknown."))
                    Toggle(tonightText("All additional charges reviewed"), isOn: $draftReviewed)
                        .disabled(draft.isEmpty)
                }
                .navigationTitle(tonightText("Review additional charges"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(tonightText("Cancel")) { editing = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(tonightText("Use in estimate")) {
                            entered = draft
                            allReviewed = !draft.isEmpty && draftReviewed
                            editing = false
                        }
                        .disabled(!validDraft)
                    }
                }
            }
        }
    }

    private var validDraft: Bool {
        do {
            let charge = try DinnerEntry.money(draft)
            guard charge != nil || draft.isEmpty else { return false }
            _ = try estimate.additionalCash(addedCharges: charge, chargesComplete: draftReviewed)
            return true
        } catch { return false }
    }
}
