import CoreDomain
import HouseholdClient
import SwiftUI

func financialText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "SharedFinancial")
}

extension ShopperFinancialEntry.Kind {
    fileprivate var label: String {
        switch self {
        case .postedCharge: pTr("Posted charge")
        case .postedTopUp: pTr("Posted top-up purchase")
        case .pendingCredit: pTr("Pending credit")
        case .postedCredit: pTr("Posted credit")
        case .includedCredit: pTr("Credit already included in net charge")
        case .paymentHold: pTr("Payment hold")
        case .holdRelease: pTr("Confirmed full hold release")
        }
    }
}

extension ShopperFinancialEntry {
    fileprivate var money: Money { Money(minorUnits: Int64(amountMinor)) }
    fileprivate var choice: String {
        let date = serviceDate(occurredAt)?.formatted(date: .abbreviated, time: .shortened) ?? occurredAt
        return "\(sourceText) · \(pMoney(money)) · \(date) · \(evidenceKey.uuidString.prefix(8))"
    }
    func settlementEntry() throws -> SettlementEntry {
        guard let kind = SettlementKind(rawValue: kind.rawValue), let date = serviceDate(occurredAt),
              currency == "USD", (0...1_000_000_000_000).contains(amountMinor) else { throw ClientError.invalidResponse }
        return .init(id: id, evidenceKey: evidenceKey.uuidString, kind: kind, amount: money, occurredAt: date,
                     creditID: creditId?.uuidString, chargeEvidenceKey: chargeEvidenceKey?.uuidString,
                     holdEvidenceKey: holdEvidenceKey?.uuidString)
    }
}

struct SharedFinancialEvidenceView: View {
    @ObservedObject var model: HouseholdShopModel
    let shopID: String
    @State private var editing: ShopperFinancialRecord?
    @State private var closing: ShopperFinancialRecord?
    private var authorized: Bool { model.canManage && model.scope.shopId == shopID }
    private var record: ShopperFinancialRecord? {
        guard authorized, let record = model.financialRecord, record.shopID == UUID(uuidString: shopID) else { return nil }
        return record
    }

    var body: some View {
        List {
            if authorized {
                if let record {
                    if let totals = model.financialSummary {
                        Section(pTr("Actual money · separate from food")) {
                            LabeledContent(pTr("Paid so far"), value: pMoney(totals.paidSoFar)).accessibilityIdentifier("financial.paid")
                            LabeledContent(pTr("Pending credits · not deducted"), value: pMoney(totals.pendingCredits)).accessibilityIdentifier("financial.pending")
                            LabeledContent(pTr("Credits already included in charges"), value: pMoney(totals.includedCredits)).accessibilityIdentifier("financial.included")
                            LabeledContent(pTr("Payment holds · not spending"), value: pMoney(totals.paymentHolds))
                        }
                    }
                    if model.financialRetry != nil {
                        Button(financialText("Retry the same financial action")) { Task { _ = await model.retryFinancial() } }
                            .accessibilityIdentifier("financial.retry")
                    } else if let shop = model.shop, shop.placedRevision != nil, shop.shopRevision == record.version.shopRevision,
                              ["placed","closed"].contains(shop.phase) {
                        Button(pTr("Record evidence")) { editing = record }.accessibilityIdentifier("financial.add")
                        if shop.phase == "placed" {
                            Button(pTr("Close this pickup")) { closing = record }.accessibilityIdentifier("financial.close")
                        } else { Text(pTr("Closed")) }
                    }
                    Section(pTr("Saved financial records")) {
                        if record.entries.isEmpty { Text(ht("No financial evidence has been entered for this shop.")) }
                        ForEach(record.entries.reversed()) { entry in
                            VStack(alignment: .leading) {
                                Text(entry.kind.label).font(.headline)
                                Text(pMoney(entry.money)); Text(entry.sourceText)
                                Text(serviceDate(entry.occurredAt)?.formatted() ?? entry.occurredAt).font(.footnote)
                                if let key = entry.chargeEvidenceKey ?? entry.holdEvidenceKey,
                                   let original = record.entries.first(where: { $0.evidenceKey == key }) {
                                    LabeledContent(entry.kind == .holdRelease ? pTr("Original payment hold") : pTr("Original posted charge"),
                                                   value: original.choice).font(.footnote)
                                }
                                if [.includedCredit, .postedCredit].contains(entry.kind), let credit = entry.creditId,
                                   let pending = record.entries.first(where: { $0.kind == .pendingCredit && $0.creditId == credit }) {
                                    LabeledContent(financialText("Credit being settled"), value: pending.choice).font(.footnote)
                                }
                            }
                        }
                    }
                }
                if let notice = model.notice { Text(notice) }
                if model.busy { ProgressView(ht("Checking service…")) }
                Button(ht("Refresh shared shop")) { Task { await refresh() } }
            } else { Text(ht("Shared shop access has ended. Return to household settings.")) }
        }
        .disabled(model.busy)
        .navigationTitle(ht("Shared financial evidence"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: shopID) { await refresh() }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing, authorized {
                SharedFinancialEditor(model: model, reviewed: editing)
            }
        }
        .confirmationDialog(pTr("Close this pickup"), isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), presenting: closing) { reviewed in
            Button(pTr("Close this pickup")) { Task { _ = await model.writeFinancial(.close, reviewed: reviewed) } }
        } message: { _ in Text(pTr("Closing preserves unresolved meal needs and pending credits for later correction. Feedback is optional.")) }
    }

    private func refresh() async {
        guard authorized else { return }
        await model.load()
        if authorized { await model.loadFinancialEntries() }
    }
}

private enum CreditSelection: Hashable {
    case none, separate, pending(UUID)
}

private struct SharedFinancialEditor: View {
    @ObservedObject var model: HouseholdShopModel
    let reviewed: ShopperFinancialRecord
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ShopperFinancialEntry.Kind = .postedCharge
    @State private var amount = ""
    @State private var evidence = ""
    @State private var date = Date()
    @State private var linked: UUID?
    @State private var credit: CreditSelection = .none
    private enum Field { case amount, evidence }
    @FocusState private var field: Field?
    private var isCredit: Bool { [.pendingCredit,.postedCredit,.includedCredit].contains(kind) }
    private var charges: [ShopperFinancialEntry] { reviewed.entries.filter { [.postedCharge,.postedTopUp].contains($0.kind) } }
    private var holds: [ShopperFinancialEntry] {
        let released = Set(reviewed.entries.compactMap(\.holdEvidenceKey))
        return reviewed.entries.filter { $0.kind == .paymentHold && !released.contains($0.evidenceKey) }
    }
    private var pendingCredits: [ShopperFinancialEntry] {
        let settled = Set(reviewed.entries.filter { [.postedCredit,.includedCredit].contains($0.kind) }.compactMap(\.creditId))
        return reviewed.entries.filter { entry in
            entry.kind == .pendingCredit && entry.chargeEvidenceKey == linked && entry.creditId.map { !settled.contains($0) } == true
        }
    }
    private var originalHold: ShopperFinancialEntry? { holds.first { $0.evidenceKey == linked } }
    private var cents: Int? {
        if kind == .holdRelease { return originalHold?.amountMinor }
        guard let money = try? ComparisonModel.money(amount), (0...1_000_000_000_000).contains(money.minorUnits) else { return nil }
        return Int(money.minorUnits)
    }
    private var needsCreditSelection: Bool { kind != .pendingCredit && isCredit && !pendingCredits.isEmpty }
    private var valid: Bool {
        !model.busy && reviewed == model.financialRecord && model.financialRetry == nil && cents != nil &&
        !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && evidence.utf8.count <= 8192 &&
        (!isCredit || linked != nil) && (!needsCreditSelection || credit != .none)
    }
    var body: some View {
        NavigationStack {
            Form {
                Picker(pTr("Record type"), selection: $kind) {
                    ForEach(ShopperFinancialEntry.Kind.allCases, id: \.self) { kind in Text(kind.label).tag(kind) }
                }.accessibilityIdentifier("financial.kind")
                if isCredit { linkage(pTr("Original posted charge"), placeholder: pTr("Choose a charge"), entries: charges) }
                if needsCreditSelection {
                    Picker(financialText("Credit being settled"), selection: $credit) {
                        Text(financialText("Choose a credit")).tag(CreditSelection.none)
                        ForEach(pendingCredits) { entry in
                            if let id = entry.creditId { Text(entry.choice).tag(CreditSelection.pending(id)) }
                        }
                        Text(financialText("A separate credit")).tag(CreditSelection.separate)
                    }.accessibilityIdentifier("financial.credit")
                }
                if kind == .holdRelease {
                    linkage(pTr("Original payment hold"), placeholder: pTr("Choose a hold"), entries: holds)
                    if let originalHold { LabeledContent(pTr("Amount"), value: pMoney(originalHold.money)) }
                } else {
                    PickupEvidenceField(title: "Amount", amount: $amount).focused($field, equals: .amount).accessibilityIdentifier("financial.amount")
                }
                TextField(financialText("Receipt or statement evidence"), text: $evidence).focused($field, equals: .evidence).accessibilityIdentifier("financial.evidence")
                DatePicker(pTr("Evidence date"), selection: $date, in: ...Date())
                if let notice = model.notice { Text(notice) }
                Button(pTr("Save financial evidence")) { save() }.disabled(!valid).accessibilityIdentifier("financial.save")
            }
            .navigationTitle(pTr("Record evidence"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() } }
            }
            .keyboardDoneAction(visible: field != nil, title: ht("Done"), identifier: "financial.doneTyping") { field = nil }
            .onChange(of: kind) { _, _ in linked = nil; credit = .none }
            .onChange(of: linked) { _, _ in credit = .none }
        }
    }
    private func linkage(_ label: String, placeholder: String, entries: [ShopperFinancialEntry]) -> some View {
        Picker(label, selection: $linked) {
            Text(placeholder).tag(UUID?.none)
            ForEach(entries) { entry in Text(entry.choice).tag(Optional(entry.evidenceKey)) }
        }.accessibilityIdentifier("financial.link")
    }
    private func save() {
        guard valid, let cents else { return }
        let creditID: UUID?
        if case .pending(let id) = credit { creditID = id } else { creditID = isCredit ? UUID() : nil }
        let entry = ShopperFinancialEntry(kind: kind, amountMinor: cents, occurredAt: date.ISO8601Format(), sourceText: evidence,
                                         creditId: creditID, chargeEvidenceKey: isCredit ? linked : nil,
                                         holdEvidenceKey: kind == .holdRelease ? linked : nil)
        Task {
            let saved = await model.writeFinancial(.append(entry), reviewed: reviewed)
            if saved || model.financialRetry != nil || model.financialRecord != reviewed { dismiss() }
        }
    }
}
