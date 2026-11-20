import CoreDomain
import LocalStore
import SwiftUI

/// A saved purchase supplies the identities, including row IDs reconciled during a rescan.
struct SavedCouponReceipt {
    let header: ReviewedReceiptHeader
    let rows: [ReviewedReceiptDecision]

    var products: [ReviewedReceiptDecision] {
        rows.filter { [.stored, .keptSome, .linked, .eaten].contains($0.kind) && !CouponReceiptEvidence.isDiscountLine($0.original) }
    }

    var discounts: [ReviewedReceiptDecision] {
        rows.filter { $0.kind == .chargeOrReturn && CouponReceiptEvidence.isDiscountLine($0.original) }
    }

    func evidence(itemID: UUID?, day: MealDay, check: CouponPackCheck,
                  discount: CouponReceiptEvidence.Discount) -> CouponReceiptEvidence? {
        guard let item = products.first(where: { $0.id == itemID }) else { return nil }
        if case .printed(let id, let wording, let amount) = discount {
            guard id != item.id, discounts.contains(where: { $0.id == id && $0.original == wording }),
                  CouponReceiptEvidence.shows(amount: amount, in: wording) else { return nil }
        }
        return CouponReceiptEvidence(receiptID: header.id, itemLineID: item.id, itemWording: item.original,
                                     day: day, check: check, discount: discount)
    }

    @MainActor static func load(header: ReviewedReceiptHeader, from pantry: PantryModel,
                                authorize: @MainActor () -> Bool) async throws -> Self {
        var rows: [ReviewedReceiptDecision] = []
        var cursor: UUID?
        repeat {
            guard !Task.isCancelled, authorize() else { throw PantryReceiptError.stale }
            let page = try await pantry.reviewedReceiptDecisions(header.id, after: cursor)
            guard authorize() else { throw PantryReceiptError.stale }
            rows += page
            cursor = page.count == 50 ? page.last?.id : nil
        } while cursor != nil
        guard !rows.isEmpty else { throw PantryReceiptError.stale }
        return Self(header: header, rows: rows.sorted { $0.ordinal < $1.ordinal })
    }
}

private func couponLines(in shop: ShoppingLedger, pickupID: UUID?) -> [ShoppingLine] {
    guard pickupID == nil || pickupID == shop.id else { return [] }
    return shop.lines.filter { !$0.isTrashed && !$0.isHandled && $0.pinnedCoupon != nil }
}

struct ReceiptCouponReviewLink: View {
    enum Source {
        case draftTerms
        case purchase(PantryModel, ReviewedReceiptHeader)
    }
    let source: Source
    let pickupID: UUID?
    let authorize: @MainActor () -> Bool
    @EnvironmentObject private var ledger: LedgerModel
    @State private var reviewing = false

    private var readOnly: Bool {
        if case .draftTerms = source { return true }
        return false
    }

    var body: some View {
        if authorize(), ledger.ready, !ledger.hasPendingLedgerDeletion,
           ledger.workspace.shops.contains(where: { !couponLines(in: $0, pickupID: pickupID).isEmpty }) {
            Button {
                reviewing = true
            } label: {
                Label(shelfText(readOnly ? "Pinned coupon terms" : "Review pinned coupons"), systemImage: "tag")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }
            .accessibilityIdentifier(readOnly ? "receipt.couponTerms" : "receipt.reviewCoupons")
            .sheet(isPresented: $reviewing) {
                PrivateShoppingSheet(model: ledger) {
                    ReceiptCouponList(model: ledger, source: source, pickupID: pickupID, receiptAuthorized: authorize)
                }
            }
        }
    }
}

private struct ReceiptCouponList: View {
    @ObservedObject var model: LedgerModel
    let source: ReceiptCouponReviewLink.Source
    let pickupID: UUID?
    let receiptAuthorized: @MainActor () -> Bool
    @Environment(\.shoppingListAuthorization) private var privateAuthorized
    @Environment(\.dismiss) private var dismiss
    @State private var saved: SavedCouponReceipt?
    @State private var failed = false

    private func authorized() -> Bool { receiptAuthorized() && privateAuthorized() }

    var body: some View {
        List {
            if authorized() {
                switch source {
                case .draftTerms:
                    Text(shelfText("Select the purchased item and include its printed coupon line. Save the receipt, then review the discount."))
                case .purchase(_, let header):
                    ReviewedReceiptHeading(header: header)
                    if failed { Button(putawayText("Could not load receipt decisions.") + " " + pantryText("Retry")) { Task { await load() } } }
                    else if saved == nil { ProgressView() }
                    else if saved?.products.isEmpty == true {
                        Text(shelfText("This purchase has no saved item line to check against a coupon."))
                    }
                }
                ForEach(model.workspace.shops) { shop in
                    let lines = couponLines(in: shop, pickupID: pickupID)
                    if !lines.isEmpty {
                        Section([shop.title, shop.currentStop.name].filter { !$0.isEmpty }.joined(separator: " · ")) {
                            ForEach(lines) { line in
                                if let pin = line.pinnedCoupon {
                                    if case .purchase(let pantry, _) = source, let saved,
                                       !saved.products.isEmpty || pin.receipt != nil {
                                        NavigationLink {
                                            ReceiptCouponEditor(model: model, shop: shop, line: line, coupon: pin,
                                                                pantry: pantry, saved: saved, authorize: authorized)
                                        } label: { terms(line, pin) }
                                        .accessibilityIdentifier("receipt.couponItem." + line.id.uuidString.lowercased())
                                    } else { terms(line, pin) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(shelfText("Pinned coupon terms"))
        .task { await load() }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ledgerText("Done")) { dismiss() } } }
    }

    private func terms(_ line: ShoppingLine, _ pin: PinnedShopCoupon) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(line.name).font(.headline)
            Text(couponTermsLabel(pin.terms))
            Text(shelfFormat("Valid through %@", ledgerMealDay(pin.terms.validThrough)))
            Text(pin.clipped ? shelfText("Clipped") : shelfText("To clip"))
            if pin.receipt != nil { CouponReceiptResult(coupon: pin) }
        }
    }

    private func load() async {
        guard case .purchase(let pantry, let header) = source, authorized() else { return }
        do {
            saved = try await SavedCouponReceipt.load(header: header, from: pantry, authorize: authorized)
            failed = false
        } catch { saved = nil; failed = true }
    }
}

private struct ReceiptCouponEditor: View {
    enum DiscountEntry: Hashable { case unknown, absent, printed }
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let line: ShoppingLine
    let coupon: PinnedShopCoupon
    let pantry: PantryModel
    let saved: SavedCouponReceipt
    let authorize: @MainActor () -> Bool
    @State private var revision: UUID
    @State private var productRow: UUID?
    @State private var discountRow: UUID?
    @State private var discount: DiscountEntry
    @State private var amount: String
    @State private var count: String
    @State private var size: CouponPackCheck.Size
    @State private var checking = false
    @State private var sourceChanged = false
    @FocusState private var field: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: LedgerModel, shop: ShoppingLedger, line: ShoppingLine, coupon: PinnedShopCoupon,
         pantry: PantryModel, saved: SavedCouponReceipt, authorize: @escaping @MainActor () -> Bool) {
        self.model = model; self.shop = shop; self.line = line; self.coupon = coupon
        self.pantry = pantry; self.saved = saved; self.authorize = authorize
        _revision = State(initialValue: shop.revisionID)
        let evidence = coupon.receipt.flatMap { $0.receiptID == saved.header.id ? $0 : nil }
        _productRow = State(initialValue: evidence?.itemLineID)
        _count = State(initialValue: evidence?.check.packCount.map(String.init) ?? "")
        _size = State(initialValue: evidence?.check.size ?? .unknown)
        switch evidence?.discount {
        case .printed(let id, _, let amount) where evidence?.savings != nil:
            _discount = State(initialValue: .printed); _discountRow = State(initialValue: id)
            _amount = State(initialValue: (Decimal(amount.minorUnits) / 100).description)
        case .absent:
            _discount = State(initialValue: .absent); _amount = State(initialValue: "")
        default:
            _discount = State(initialValue: .unknown); _amount = State(initialValue: "")
        }
    }

    private var day: MealDay? {
        try? MealDay(date: saved.header.date, timeZoneIdentifier: TimeZone.current.identifier)
    }

    private func evidence(from source: SavedCouponReceipt) -> CouponReceiptEvidence? {
        guard authorize(), let day, let check = CouponCheckFields.check(count: count, size: size) else { return nil }
        let result: CouponReceiptEvidence.Discount
        switch discount {
        case .unknown: result = .unverified
        case .absent: result = .absent
        case .printed:
            guard let row = source.discounts.first(where: { $0.id == discountRow }),
                  let value = try? ComparisonModel.money(amount.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: "."))
            else { return nil }
            result = .printed(lineID: row.id, wording: row.original, amount: value)
        }
        return source.evidence(itemID: productRow, day: day, check: check, discount: result)
    }

    var body: some View {
        WorkingForm {
            if authorize() {
                Section(line.name) { CouponTermsSummary(coupon: coupon) }
                Section { ReviewedReceiptHeading(header: saved.header) }
                if let previous = coupon.receipt, previous.receiptID != saved.header.id {
                    Text(shelfText("This coupon is linked to another purchase. Clear its receipt link to review this purchase."))
                } else {
                    itemSection
                    if sourceChanged { Text(shelfText("The saved receipt changed. Reopen the purchase to review its lines.")) }
                    Button(shelfText("Save receipt coupon review")) { Task { await save() } }
                        .buttonStyle(PrimaryAction())
                        .disabled(evidence(from: saved) == nil || checking || model.saving || model.hasPendingSave)
                        .accessibilityIdentifier("receipt.couponSave")
                }
                if coupon.receipt != nil {
                    ClearCouponReceiptButton(model: model, shopID: shop.id, lineID: line.id, revision: revision,
                                             authorize: authorize, didClear: { dismiss() })
                }
                if model.error != nil || model.hasPendingSave { LedgerSaveStatus(model: model, showsLastSave: false) }
            }
        }.navigationTitle(shelfText("Receipt coupon"))
        .keyboardDoneAction(visible: field, title: pantryText("Done"), identifier: "receipt.couponKeyboardDone") { field = false }
    }

    private var itemSection: some View {
        Section(shelfText("Check against the receipt")) {
            Picker(shelfText("Purchased item line"), selection: $productRow) {
                Text(shelfText("Choose a receipt line")).tag(nil as UUID?)
                ForEach(saved.products) { row in Text(verbatim: row.original).tag(Optional(row.id)) }
            }.accessibilityIdentifier("receipt.couponProduct")
            CouponCheckFields(termsSize: coupon.terms.qualifyingSize, count: $count, size: $size).focused($field)
            if let day {
                Text(couponStatusLabel(coupon.terms.qualification(on: day,
                    check: productRow == nil ? nil : CouponCheckFields.check(count: count, size: size))))
            }
            Picker(shelfText("Discount on receipt"), selection: $discount) {
                Text(shelfText("Unverified")).tag(DiscountEntry.unknown)
                Text(shelfText("I checked the receipt and found no discount")).tag(DiscountEntry.absent)
                if !saved.discounts.isEmpty {
                    Text(shelfText("I found the printed discount")).tag(DiscountEntry.printed)
                }
            }.accessibilityIdentifier("receipt.couponOutcome")
            if saved.discounts.isEmpty {
                Text(shelfText("To add a printed coupon line, review the receipt again and include that line in this purchase."))
                    .font(.footnote)
            }
            if discount == .printed {
                Picker(shelfText("Printed discount line"), selection: $discountRow) {
                    Text(shelfText("Choose a receipt line")).tag(nil as UUID?)
                    ForEach(saved.discounts) { row in Text(verbatim: row.original).tag(Optional(row.id)) }
                }.accessibilityIdentifier("receipt.couponDiscountLine")
                WorkingField(shelfText("Discount amount shown ($)")) {
                    workingTextField(shelfText("Discount amount shown ($)"), text: $amount).keyboardType(.decimalPad)
                        .focused($field).accessibilityIdentifier("receipt.couponAmount")
                }
                if !amount.isEmpty && evidence(from: saved) == nil {
                    Text(shelfText("Check the amount against the selected printed line.")).font(.footnote)
                }
            }
        }
    }

    private func save() async {
        guard !checking, let reviewed = evidence(from: saved) else { return }
        checking = true
        defer { checking = false }
        do {
            let current = try await SavedCouponReceipt.load(header: saved.header, from: pantry, authorize: authorize)
            guard evidence(from: current) == reviewed, let state = pantry.snapshot?.state else { throw PantryReceiptError.stale }
            if await model.editShop(key: "receipt-coupon-\(line.id)", shopID: shop.id,
                                    authorize: { authorize() && pantry.snapshot?.state == state }, { ledger in
                try ledger.reviewCouponReceipt(lineID: line.id, expectedRevision: revision, evidence: reviewed)
            }) { dismiss() }
        } catch { sourceChanged = true }
    }
}
