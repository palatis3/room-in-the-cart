import CoreDomain
import SwiftUI

struct InStoreBudgetSummary: View {
    let shop: ShoppingLedger

    var body: some View {
        let subtotal = shop.pickedCartSubtotal
        VStack(alignment: .leading, spacing: 3) {
            Text(shelfFormat("Unpriced picks · %lld", Int64(subtotal.picked - subtotal.priced)))
            Text(shelfText("Tax is separate.") + " " + (knownFees.map { shelfFormat("Fees · %@", moneyText($0)) }
                ?? shelfText("Fees unknown.")))
        }.font(.footnote).foregroundStyle(Theme.secondary)
    }

    private var knownFees: Money? {
        shop.basis.mode == .inStore && shop.currentStop.name == shop.basis.branch ? shop.basis.knownFees : nil
    }
}

struct InStoreCouponPickLabel: View {
    let coupon: PinnedShopCoupon
    let line: ShoppingLine
    var body: some View {
        let state = coupon.clipped ? shelfText("Clipped") : shelfText("To clip")
        VStack(alignment: .leading, spacing: 2) {
            Text(state + " · " + couponTermsLabel(coupon.terms))
            if let day = try? MealDay(date: Date(), timeZoneIdentifier: coupon.terms.validThrough.timeZoneIdentifier) {
                let check = coupon.checkedAt == line.inStorePickedAt ? coupon.pickCheck : nil
                Text(couponStatusLabel(coupon.terms.qualification(on: day, check: check)))
            }
        }.font(.footnote).foregroundStyle(Theme.secondary)
    }
}

struct InStoreBudgetItemLink: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let line: ShoppingLine

    var body: some View {
        NavigationLink {
            InStoreBudgetItem(model: model, shopID: shop.id, lineID: line.id)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if let coupon = line.pinnedCoupon {
                    InStoreCouponPickLabel(coupon: coupon, line: line)
                } else {
                    Text(line.inStorePickedAt == nil ? shelfText("Pin a coupon") : shelfText("Budget and coupon"))
                }
                if line.flexiblePick == true { Text(shelfText("Flexible pick")).font(.footnote) }
            }.frame(minHeight: 44, alignment: .leading)
        }
        .accessibilityHint(Text(line.name))
        .accessibilityIdentifier("inStoreBudget-\(line.id)")
    }
}

private struct InStoreBudgetItem: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    let lineID: UUID
    @Environment(\.shoppingListAuthorization) private var authorize
    @Environment(\.dismiss) private var dismiss
    @State private var preview: BudgetDeferralPreview?
    @State private var previewRevision: UUID?

    var body: some View {
        WorkingForm {
            if authorize(), let shop = model.shop, shop.id == shopID,
               let line = shop.lines.first(where: { $0.id == lineID && !$0.isTrashed && !$0.isHandled }) {
                Section { Text(line.name).font(.title3.weight(.semibold))
                    if let quantity = try? shop.quantity(forLineID: line.id) {
                        Text(shelfFormat("Requested · %@", ledgerQuantity(quantity)))
                    }
                }
                if line.inStorePickedAt != nil {
                    budgetSection(shop, line: line)
                }
                Section(shelfText("Item coupon")) {
                    if let pin = line.pinnedCoupon {
                        CouponTermsSummary(coupon: pin)
                        if pin.receipt != nil { CouponReceiptResult(coupon: pin) }
                    }
                    if line.pinnedCoupon?.receipt == nil {
                        NavigationLink(line.pinnedCoupon == nil ? shelfText("Pin a coupon") : shelfText("Review coupon conditions")) {
                            InStoreCouponEditor(model: model, shop: shop, line: line)
                        }
                    }
                }
            }
            if model.error != nil || model.hasPendingSave { LedgerSaveStatus(model: model, showsLastSave: false) }
        }.navigationTitle(shelfText("Budget and coupon"))
    }

    @ViewBuilder private func budgetSection(_ shop: ShoppingLedger, line: ShoppingLine) -> some View {
        Section(shelfText("What can wait")) {
            let impact = shop.budgetDinnerImpact(for: line.id)
            ForEach(Array(impact.dinners.enumerated()), id: \.offset) { _, dinner in
                Text(shelfFormat("Needed for %@", dinner))
            }
            if impact.protected {
                Label(shelfText("Set aside for a protected need"), systemImage: "lock")
            } else {
                Toggle(shelfText("Flexible pick"), isOn: Binding(get: { line.flexiblePick == true }, set: { flexible in
                    preview = nil
                    Task {
                        _ = await model.editShop(key: "flexible-\(line.id)", shopID: shop.id, authorize: authorize) { ledger in
                            guard model.workspace.selectedShopID == shop.id else { throw LedgerError.stalePreview }
                            try ledger.setBudgetFlexible(lineID: line.id, expectedRevision: shop.revisionID, flexible: flexible)
                        }
                    }
                }))
                if line.flexiblePick == true {
                    if let preview, previewRevision == shop.revisionID {
                        Text(shelfFormat("Known item subtotal · %@ → %@", moneyText(preview.before.total), moneyText(preview.after.total)))
                        Text(shelfFormat("Unpriced picks after putting it back · %lld", Int64(preview.after.picked - preview.after.priced)))
                        Text(shelfText("The item stays on your list for another trip.")).font(.footnote)
                        Button(shelfText("Leave for next time")) {
                            Task {
                                if await model.editShop(key: "leave-for-next-trip-\(line.id)", shopID: shop.id, authorize: authorize, { ledger in
                                    guard model.workspace.selectedShopID == shop.id else { throw LedgerError.stalePreview }
                                    try ledger.leaveForNextTrip(lineID: line.id, expectedRevision: shop.revisionID)
                                }) { dismiss() }
                            }
                        }.accessibilityIdentifier("inStoreLeaveForNextTime")
                    } else {
                        Button(shelfText("Preview putting it back")) {
                            preview = try? shop.previewBudgetDeferral(lineID: line.id)
                            previewRevision = shop.revisionID
                        }
                    }
                }
            }
        }.disabled(model.saving || model.hasPendingSave)
    }
}

func couponTermsLabel(_ terms: ShopCouponTerms) -> String {
    [shelfFormat("Minimum packs · %lld", Int64(terms.minimumPacks)), terms.qualifyingSize].filter { !$0.isEmpty }.joined(separator: " · ")
}

func couponStatusLabel(_ status: CouponQualification) -> String {
    switch status {
    case .uncertain: shelfText("Coupon match uncertain")
    case .wrongSizeOrCount: shelfText("Wrong size or pack count")
    case .expired: shelfText("Coupon expired")
    case .qualifies: shelfText("Meets the coupon conditions")
    }
}

struct CouponTermsSummary: View {
    let coupon: PinnedShopCoupon
    var body: some View {
        Text(coupon.clipped ? shelfText("Clipped") : shelfText("To clip"))
        Text(couponTermsLabel(coupon.terms))
        Text(shelfFormat("Valid through %@", ledgerMealDay(coupon.terms.validThrough)))
        if let url = coupon.terms.retailerURL { Link(shelfText("Retailer coupon"), destination: url) }
    }
}

struct CouponReceiptResult: View {
    let coupon: PinnedShopCoupon
    var body: some View {
        if let receipt = coupon.receipt {
            Text(receipt.itemWording).font(.footnote)
            Text(couponStatusLabel(coupon.terms.qualification(on: receipt.day, check: receipt.check)))
            switch receipt.discount {
            case .unverified: Text(shelfText("Receipt discount unverified"))
            case .absent:
                Text(coupon.missingQualifyingDiscount ? shelfText("Qualifying discount missing from receipt") : shelfText("No discount found on receipt"))
            case .printed(_, let wording, let amount):
                Text(shelfFormat("Discount on receipt · %@", moneyText(amount)))
                Text(wording).font(.footnote)
            }
        }
    }
}

struct CouponCheckFields: View {
    let termsSize: String
    @Binding var count: String
    @Binding var size: CouponPackCheck.Size
    var body: some View {
        WorkingField(shelfText("Actual pack count")) {
            workingTextField(shelfText("Actual pack count"), text: $count).keyboardType(.numberPad)
        }
        if !termsSize.isEmpty {
            Picker(shelfText("Package size"), selection: $size) {
                Text(shelfText("Uncertain")).tag(CouponPackCheck.Size.unknown)
                Text(shelfText("Matches the coupon")).tag(CouponPackCheck.Size.matches)
                Text(shelfText("Different size")).tag(CouponPackCheck.Size.different)
            }
        }
    }
    static func check(count: String, size: CouponPackCheck.Size) -> CouponPackCheck? {
        guard !count.isEmpty else { return CouponPackCheck(packCount: nil, size: size) }
        guard let value = Int(count), (0...10_000).contains(value) else { return nil }
        return CouponPackCheck(packCount: value, size: size)
    }
}

private struct InStoreCouponEditor: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let line: ShoppingLine
    @State private var revision: UUID
    @State private var termsSize: String
    @State private var minimum: String
    @State private var validThrough: Date
    @State private var retailer: String
    @State private var clipped: Bool
    @State private var count: String
    @State private var size: CouponPackCheck.Size
    @FocusState private var field: Bool
    @Environment(\.shoppingListAuthorization) private var authorize
    @Environment(\.dismiss) private var dismiss

    init(model: LedgerModel, shop: ShoppingLedger, line: ShoppingLine) {
        self.model = model; self.shop = shop; self.line = line
        let coupon = line.pinnedCoupon
        _revision = State(initialValue: shop.revisionID)
        _termsSize = State(initialValue: coupon?.terms.qualifyingSize ?? "")
        _minimum = State(initialValue: String(coupon?.terms.minimumPacks ?? 1))
        _validThrough = State(initialValue: coupon?.terms.validThrough.date ?? Date())
        _retailer = State(initialValue: coupon?.terms.retailerURL?.absoluteString ?? "")
        _clipped = State(initialValue: coupon?.clipped ?? false)
        let check = coupon?.checkedAt == line.inStorePickedAt ? coupon?.pickCheck : nil
        _count = State(initialValue: check?.packCount.map(String.init) ?? "")
        _size = State(initialValue: check?.size ?? .unknown)
    }

    private var proposed: ShopCouponTerms? {
        let address = retailer.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = address.isEmpty ? nil : URL(string: address)
        guard let minimum = Int(minimum), address.isEmpty || url != nil,
              let day = try? MealDay(date: validThrough, timeZoneIdentifier: shop.basis.timeZoneIdentifier) else { return nil }
        let terms = ShopCouponTerms(qualifyingSize: termsSize.trimmingCharacters(in: .whitespacesAndNewlines),
            minimumPacks: minimum, validThrough: day, retailerURL: url)
        return (try? terms.validate()) != nil ? terms : nil
    }
    var body: some View {
        WorkingForm {
            Section(line.name) {
                WorkingField(shelfText("Qualifying size or variant")) {
                    workingTextField(shelfText("Qualifying size or variant"), text: $termsSize).focused($field)
                }
                WorkingField(shelfText("Minimum pack count")) {
                    workingTextField(shelfText("Minimum pack count"), text: $minimum).keyboardType(.numberPad).focused($field)
                }
                DatePicker(shelfText("Valid through"), selection: $validThrough, displayedComponents: .date)
                    .environment(\.timeZone, TimeZone(identifier: shop.basis.timeZoneIdentifier) ?? .current)
                WorkingField(shelfText("Retailer link (optional)")) {
                    workingTextField(shelfText("Retailer link (optional)"), text: $retailer).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().keyboardType(.URL).focused($field)
                }
                Toggle(shelfText("Clipped"), isOn: $clipped)
            }
            if line.inStorePickedAt != nil {
                Section(shelfText("Check picked packs")) {
                    CouponCheckFields(termsSize: termsSize, count: $count, size: $size).focused($field)
                    if let terms = proposed, let day = try? MealDay(date: Date(), timeZoneIdentifier: shop.basis.timeZoneIdentifier) {
                        Text(couponStatusLabel(terms.qualification(on: day, check: CouponCheckFields.check(count: count, size: size))))
                    }
                }
            }
            if proposed == nil { Text(shelfText("Check the minimum pack count and retailer link.")) }
            if model.error != nil || model.hasPendingSave { LedgerSaveStatus(model: model, showsLastSave: false) }
            Button(shelfText("Save coupon")) { if let proposed { save(proposed) } }
                .disabled(proposed == nil || CouponCheckFields.check(count: count, size: size) == nil || model.saving || model.hasPendingSave)
            if line.pinnedCoupon != nil {
                Button(shelfText("Remove coupon"), role: .destructive) { save(nil) }.disabled(model.saving || model.hasPendingSave)
            }
        }.navigationTitle(shelfText("Item coupon"))
        .onChange(of: termsSize) { _, _ in size = .unknown }
        .keyboardDoneAction(visible: field, title: ledgerText("Done"), identifier: "inStoreCouponKeyboardDone") { field = false }
    }
    private func save(_ terms: ShopCouponTerms?) {
        let check = line.inStorePickedAt == nil ? nil : CouponCheckFields.check(count: count, size: size)
        Task {
            if await model.editShop(key: "pin-coupon-\(line.id)", shopID: shop.id, authorize: authorize, { ledger in
                guard model.workspace.selectedShopID == shop.id else { throw LedgerError.stalePreview }
                try ledger.pinCoupon(lineID: line.id, expectedRevision: revision, terms: terms, clipped: clipped, pickCheck: check)
            }) { dismiss() }
        }
    }
}
