import SwiftUI
import CoreDomain

struct LedgerPackChoiceView: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    let lineID: UUID
    @State private var firstLabel = ""
    @State private var firstAmount = ""
    @State private var firstUnit: UnitOfMeasure = .count
    @State private var firstPrice = ""
    @State private var secondLabel = ""
    @State private var secondAmount = ""
    @State private var secondUnit: UnitOfMeasure = .count
    @State private var secondPrice = ""
    @State private var cap = ""
    @State private var source = ""
    @State private var observedAt = Date()
    @State private var review: LedgerPackReview?
    @State private var saved = false
    @State private var validation: String?
    @State private var initialized = false
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            if saved {
                Section {
                    Text(ledgerText("Pack choice saved for checkout review."))
                    Text(ledgerText("Your ingredient needs are unchanged. Open Review checkout to apply the purchased amount and item cost. An earlier saved checkout keeps its existing terms until you review it."))
                    Button(ledgerText("Done")) { dismiss() }.accessibilityIdentifier("ledgerPackDone")
                }
            } else if let review {
                Section(ledgerText("Review whole packs for this item")) {
                    Text(review.requirement.name).font(.headline)
                    LabeledContent(ledgerText("Needed for this list"), value: ledgerQuantity(review.requirement.quantity))
                    LabeledContent(ledgerText("Protected inside that amount"), value: ledgerQuantity(review.requirement.protectedQuantity))
                    Text(ledgerText("Item-only comparison. Whole-checkout affordability still needs all groceries, fees and other charges."))
                    Text("\(review.source) · \(review.reviewedAt.formatted())")
                }
                result(review.result.offerA, offer: review.request.offerA, review: review)
                result(review.result.offerB, offer: review.request.offerB, review: review)
                Button(ledgerText("Keep editing")) { self.review = nil; validation = nil }
            } else {
                if let shop = model.workspace.shops.first(where: { $0.id == shopID }),
                   let requirement = try? LedgerPackRequirement.review(shop: shop, lineID: lineID) {
                    Section(ledgerText("Current ingredient need")) {
                        Text(requirement.name).font(.headline)
                        LabeledContent(ledgerText("Needed for this list"), value: ledgerQuantity(requirement.quantity))
                        LabeledContent(ledgerText("Protected inside that amount"), value: ledgerQuantity(requirement.protectedQuantity))
                        Text(ledgerText("Compare the usable amount of one whole pack. Confirm usable stock separately; this choice does not claim pantry or freezer food."))
                    }
                }
                Section(ledgerText("First pack")) {
                    TextField(ledgerText("First pack label"), text: $firstLabel).focused($focused)
                    TextField(ledgerText("First pack usable amount"), text: $firstAmount).keyboardType(.decimalPad).focused($focused)
                    unitPicker($firstUnit)
                    TextField(ledgerText("First pack price, USD"), text: $firstPrice).keyboardType(.decimalPad).focused($focused)
                }
                Section(ledgerText("Second pack")) {
                    TextField(ledgerText("Second pack label"), text: $secondLabel).focused($focused)
                    TextField(ledgerText("Second pack usable amount"), text: $secondAmount).keyboardType(.decimalPad).focused($focused)
                    unitPicker($secondUnit)
                    TextField(ledgerText("Second pack price, USD"), text: $secondPrice).keyboardType(.decimalPad).focused($focused)
                }
                Section(ledgerText("Reviewed price evidence")) {
                    TextField(ledgerText("Where you checked these packs and prices"), text: $source).focused($focused)
                    DatePicker(ledgerText("Checked at"), selection: $observedAt)
                    TextField(ledgerText("Item-only spending limit, optional"), text: $cap).keyboardType(.decimalPad).focused($focused)
                    Text(ledgerText("Blank amount or price stays unresolved. A resolved pack can be selected even when the other pack is unknown."))
                    Button(ledgerText("Review whole packs"), action: prepare).buttonStyle(PrimaryAction()).accessibilityIdentifier("ledgerReviewPacks")
                }
            }
            if let validation { Text(validation).foregroundStyle(Theme.warning) }
            LedgerSaveStatus(model: model)
        }
        // Start each step at its heading even when the prior form was scrolled to its last row.
        .id(saved ? "saved" : review == nil ? "entry" : "review")
        .workingSurface().scrollDismissesKeyboard(.interactively)
            .navigationTitle(ledgerText("Choose whole packs"))
            .disabled(model.saving || !model.ready)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(ledgerText("Done")) { focused = false } }
            }
            .onAppear {
                guard !initialized else { return }; initialized = true
                if let shop = model.workspace.shops.first(where: { $0.id == shopID }),
                   let requirement = try? LedgerPackRequirement.review(shop: shop, lineID: lineID) {
                    firstUnit = requirement.quantity.unit; secondUnit = requirement.quantity.unit
                }
            }
    }
    private func unitPicker(_ selection: Binding<UnitOfMeasure>) -> some View {
        Picker(ledgerText("Unit"), selection: selection) { ForEach(UnitOfMeasure.allCases, id: \.self) { Text($0.displayName).tag($0) } }
    }
    @ViewBuilder private func result(_ result: OfferResult, offer: PackOffer, review: LedgerPackReview) -> some View {
        Section(offer.label) {
            if let count = result.packsToBuy { LabeledContent(ledgerText("Whole packs to buy"), value: String(count)) }
            if let purchased = result.purchasedAmount, let unit = review.result.unit {
                LabeledContent(ledgerText("Purchased usable amount"), value: ledgerQuantity(Quantity(amount: purchased, unit: unit, originalLiteral: purchased.description)))
            }
            if let leftover = result.leftover { LabeledContent(ledgerText("Left after this need"), value: amountText(leftover)) }
            if let cost = result.totalCost { LabeledContent(ledgerText("Item cost"), value: moneyText(cost)) }
            if !result.isResolved { Text(ledgerText("This pack remains unresolved. Check its usable amount, unit and price.")) }
            if result.isResolved, result.packsToBuy.map({ $0 > 0 }) == true {
                Button(ledgerFormat("Choose %@ for checkout review", offer.label)) { Task {
                    do { saved = try await review.save(offerID: offer.id, ledger: model); validation = nil }
                    catch { validation = ledgerText("The list or reviewed source changed. Make a new pack review before choosing.") }
                } }.buttonStyle(PrimaryAction()).accessibilityIdentifier("ledgerChoosePack-\(offer.id)")
            }
        }
    }
    private func prepare() {
        do {
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !firstLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !secondLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LedgerPackError.invalidEvidence }
            review = try LedgerPackReview.prepare(ledger: model, shopID: shopID, lineID: lineID,
                offerA: PackOffer(id: "a", label: firstLabel, usableQuantity: ComparisonModel.quantity(firstAmount, firstUnit), price: ComparisonModel.money(firstPrice)),
                offerB: PackOffer(id: "b", label: secondLabel, usableQuantity: ComparisonModel.quantity(secondAmount, secondUnit), price: ComparisonModel.money(secondPrice)),
                itemCap: ComparisonModel.money(cap), at: observedAt, source: source)
            focused = false; validation = nil
        } catch { validation = ledgerText("Enter the pack labels, checked source and valid amounts. Unknown amounts stay blank.") }
    }
}
