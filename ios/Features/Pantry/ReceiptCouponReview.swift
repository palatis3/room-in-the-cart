import CoreDomain
import SwiftUI

private extension ReceiptImportDraft {
    func couponAppliesToReview(_ line: ShoppingLine, in shop: ShoppingLedger) -> Bool {
        guard savedPickup == nil || savedPickup?.id == shop.id,
              !line.isTrashed, !line.isHandled, let coupon = line.pinnedCoupon else { return false }
        return coupon.receipt == nil || coupon.receipt?.receiptID == receiptID
    }
}

struct ReceiptCouponReviewLink: View {
    let draft: ReceiptImportDraft
    let authorize: @MainActor () -> Bool
    @EnvironmentObject private var ledger: LedgerModel
    @State private var reviewing = false

    var body: some View {
        if authorize(), ledger.ready, !ledger.hasPendingLedgerDeletion,
           draft.lines.contains(where: \.canComparePurchase),
           ledger.workspace.shops.contains(where: { shop in shop.lines.contains { draft.couponAppliesToReview($0, in: shop) } }) {
            Button(shelfText("Review pinned coupons")) { reviewing = true }
                .accessibilityIdentifier("receipt.reviewCoupons")
                .sheet(isPresented: $reviewing) {
                    PrivateShoppingSheet(model: ledger) {
                        ReceiptCouponList(model: ledger, draft: draft, receiptAuthorized: authorize)
                    }
                }
        }
    }
}

private struct ReceiptCouponList: View {
    @ObservedObject var model: LedgerModel
    let draft: ReceiptImportDraft
    let receiptAuthorized: @MainActor () -> Bool
    @Environment(\.shoppingListAuthorization) private var privateAuthorized
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if receiptAuthorized() && privateAuthorized() {
                ForEach(model.workspace.shops) { shop in
                    let lines = shop.lines.filter { draft.couponAppliesToReview($0, in: shop) }
                    if !lines.isEmpty {
                        Section([shop.title, shop.currentStop.name].filter { !$0.isEmpty }.joined(separator: " · ")) {
                            ForEach(lines) { line in
                                if let pin = line.pinnedCoupon {
                                    NavigationLink {
                                        ReceiptCouponEditor(model: model, shop: shop, line: line, coupon: pin, draft: draft,
                                            authorize: { receiptAuthorized() && privateAuthorized() })
                                    } label: {
                                        VStack(alignment: .leading) {
                                            Text(line.name).font(.headline)
                                            Text(couponTermsLabel(pin.terms))
                                            Text(pin.clipped ? shelfText("Clipped") : shelfText("To clip"))
                                            if pin.receipt != nil { CouponReceiptResult(coupon: pin) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }.navigationTitle(shelfText("Review pinned coupons"))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ledgerText("Done")) { dismiss() } } }
    }
}

private struct ReceiptCouponEditor: View {
    enum DiscountEntry: Hashable { case unknown, absent, printed }
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let line: ShoppingLine
    let coupon: PinnedShopCoupon
    let draft: ReceiptImportDraft
    let authorize: @MainActor () -> Bool
    @State private var revision: UUID
    @State private var productRow: UUID?
    @State private var discountRow: UUID?
    @State private var discount: DiscountEntry
    @State private var amount: String
    @State private var count: String
    @State private var size: CouponPackCheck.Size
    @FocusState private var field: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: LedgerModel, shop: ShoppingLedger, line: ShoppingLine, coupon: PinnedShopCoupon,
         draft: ReceiptImportDraft, authorize: @escaping @MainActor () -> Bool) {
        self.model = model; self.shop = shop; self.line = line; self.coupon = coupon; self.draft = draft
        self.authorize = authorize
        _revision = State(initialValue: shop.revisionID)
        let evidence = coupon.receipt
        _productRow = State(initialValue: evidence?.itemLineID)
        _count = State(initialValue: evidence?.check.packCount.map(String.init) ?? "")
        _size = State(initialValue: evidence?.check.size ?? .unknown)
        switch evidence?.discount {
        case .printed(let id, _, let amount):
            _discount = State(initialValue: .printed); _discountRow = State(initialValue: id)
            _amount = State(initialValue: (Decimal(amount.minorUnits) / 100).description)
        case .absent:
            _discount = State(initialValue: .absent); _amount = State(initialValue: "")
        default:
            _discount = State(initialValue: .unknown); _amount = State(initialValue: "")
        }
    }

    private func sourceID(_ row: ReceiptImportDraft.Line) -> UUID {
        ReceiptAcquisition.lineID(receiptID: draft.receiptID, ordinal: row.ordinal, document: draft.documentLayoutID)
    }
    private var printedRows: [ReceiptImportDraft.Line] {
        draft.lines.filter { $0.documentLine?.stage != .order && $0.printed?.kind != .date && !$0.original.isEmpty }
    }
    private var evidence: CouponReceiptEvidence? {
        guard authorize(), draft.dateConfirmed, draft.purchaseDate <= Date(),
              !draft.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let day = try? MealDay(date: draft.purchaseDate, timeZoneIdentifier: TimeZone.current.identifier),
              let item = printedRows.first(where: { $0.canComparePurchase && sourceID($0) == productRow }),
              let check = CouponCheckFields.check(count: count, size: size) else { return nil }
        let result: CouponReceiptEvidence.Discount
        switch discount {
        case .unknown: result = .unverified
        case .absent: result = .absent
        case .printed:
            guard let row = printedRows.first(where: { sourceID($0) == discountRow }),
                  let value = try? ComparisonModel.money(amount.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")),
                  CouponReceiptEvidence.shows(amount: value, in: row.original) else { return nil }
            result = .printed(lineID: sourceID(row), wording: row.original, amount: value)
        }
        return CouponReceiptEvidence(receiptID: draft.receiptID, itemLineID: sourceID(item), itemWording: item.original,
            day: day, check: check, discount: result)
    }

    var body: some View {
        WorkingForm {
            if authorize() {
                Section(line.name) { CouponTermsSummary(coupon: coupon) }
                Section(shelfText("Check against the receipt")) {
                    Picker(shelfText("Purchased item line"), selection: $productRow) {
                        Text(shelfText("Choose a receipt line")).tag(nil as UUID?)
                        ForEach(printedRows.filter(\.canComparePurchase)) { row in Text(row.original).tag(Optional(sourceID(row))) }
                    }
                    CouponCheckFields(termsSize: coupon.terms.qualifyingSize, count: $count, size: $size).focused($field)
                    if draft.dateConfirmed,
                       let day = try? MealDay(date: draft.purchaseDate, timeZoneIdentifier: TimeZone.current.identifier) {
                        Text(couponStatusLabel(coupon.terms.qualification(on: day,
                            check: productRow == nil ? nil : CouponCheckFields.check(count: count, size: size))))
                    } else { Text(shelfText("Confirm the purchase date in receipt details.")) }
                    Picker(shelfText("Discount on receipt"), selection: $discount) {
                        Text(shelfText("Unverified")).tag(DiscountEntry.unknown)
                        Text(shelfText("I checked the receipt and found no discount")).tag(DiscountEntry.absent)
                        Text(shelfText("I found the printed discount")).tag(DiscountEntry.printed)
                    }
                    if discount == .printed {
                        Picker(shelfText("Printed discount line"), selection: $discountRow) {
                            Text(shelfText("Choose a receipt line")).tag(nil as UUID?)
                            ForEach(printedRows) { row in Text(row.original).tag(Optional(sourceID(row))) }
                        }
                        WorkingField(shelfText("Discount amount shown ($)")) {
                            workingTextField(shelfText("Discount amount shown ($)"), text: $amount).keyboardType(.decimalPad).focused($field)
                        }
                        if !amount.isEmpty && evidence == nil {
                            Text(shelfText("Check the amount against the selected printed line.")).font(.footnote)
                        }
                    }
                }
                if model.error != nil || model.hasPendingSave { LedgerSaveStatus(model: model, showsLastSave: false) }
                Button(shelfText("Save receipt coupon review")) {
                    guard let evidence else { return }
                    Task {
                        if await model.editShop(key: "receipt-coupon-\(line.id)", shopID: shop.id, authorize: authorize, { current in
                            try current.reviewCouponReceipt(lineID: line.id, expectedRevision: revision, evidence: evidence)
                        }) { dismiss() }
                    }
                }.disabled(evidence == nil || model.saving || model.hasPendingSave)
            }
        }.navigationTitle(shelfText("Receipt coupon"))
        .keyboardDoneAction(visible: field, title: pantryText("Done"), identifier: "receipt.couponKeyboardDone") { field = false }
    }
}
