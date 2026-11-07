import SwiftUI
import CoreDomain

struct StapleApprovalView: View {
    @ObservedObject var ledger: LedgerModel
    let shopID: UUID
    let lineID: UUID
    @State private var purpose: String
    @State private var revision: UUID
    @Environment(\.dismiss) private var dismiss
    init(ledger: LedgerModel, shop: ShoppingLedger, line: ShoppingLine) {
        self.ledger = ledger; shopID = shop.id; lineID = line.id
        _purpose = State(initialValue: line.stapleApproval?.purpose ?? "")
        _revision = State(initialValue: shop.revisionID)
    }
    var body: some View {
        Form {
            if let shop = ledger.shop, shop.id == shopID, let line = shop.lines.first(where: { $0.id == lineID }) {
                Text(line.name).font(.headline)
                LabeledContent(ledgerText("Store"), value: shop.basis.branch)
                TextField(ledgerText("Purpose for a future pickup"), text: $purpose)
                if shop.basis.branch.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    Text(ledgerText("Enter this pickup’s store before remembering a staple."))
                }
                Text(ledgerText("Remembering a staple keeps its purpose and store. You decide again how much to buy on a later trip."))
                Button(ledgerText("Remember this staple")) { save(purpose) }
                    .disabled(purpose.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || purpose.count > 512 || shop.basis.branch.isEmpty || shop.revisionID != revision)
                if let old = line.stapleApproval {
                    LabeledContent(ledgerText("Remembered store"), value: old.branch)
                    Button(ledgerText("Forget this staple"), role:.destructive) { save(nil) }.disabled(shop.revisionID != revision)
                }
                if shop.revisionID != revision { Text(ledgerText("Reopen this item to review its current details.")) }
            }
            LedgerSaveStatus(model: ledger, onRetried: { dismiss() })
        }.navigationTitle(ledgerText("Staple for future pickups")).disabled(ledger.saving)
    }
    private func save(_ value: String?) {
        Task {
            let saved = await ledger.editShop(key:"approve-staple-\(lineID)",shopID:shopID) { shop in
                guard shop.revisionID == revision else { throw LedgerError.stalePreview }
                try shop.approveStaple(lineID:lineID,purpose:value)
            }
            if saved { dismiss() }
        }
    }
}

struct StapleRecallView: View {
    @ObservedObject var ledger: LedgerModel
    let targetID: UUID
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var household: HouseholdModel
    @EnvironmentObject private var membership: MembershipCoordinator
    @EnvironmentObject private var access: WorkspaceAccess
    @State private var store = ""
    @State private var purpose = ""
    @State private var review: ReviewedStaple?
    @State private var showsMembership = false
    @AccessibilityFocusState private var membershipFocused: Bool
    private var permitted: Bool {
        access.unlocked && !household.locked && (household.projection.map { ["shopper","organizer"].contains($0.role) && $0.grantId == nil } ?? true)
            && membership.model?.hasPaidAccess == true
    }
    private var editable: Bool {
        guard ledger.shop?.id == targetID, pickup.ready, !pickup.hasPendingSave, !pickup.saving else { return false }
        if let journey = pickup.journeys.first(where: { $0.id == targetID }) {
            return journey.closedAt == nil && journey.basket?.phase == .draft
        }
        return true
    }
    var body: some View {
        List {
            if !permitted {
                Text(ledgerText("Assisted staple recall requires an active adult planning seat. You can still review open deferrals and enter items manually."))
                Button(ledgerText("Household membership")) { showsMembership = true }
                    .accessibilityFocused($membershipFocused)
            } else if !editable {
                Text(ledgerText("Open a current draft pickup to review staples for it."))
            } else {
                let items = ledger.workspace.priorStaples(for: targetID)
                Section {
                    Text(ledgerText("Choose what you need this trip. Previous checked items stay with their original pickup."))
                    Picker(ledgerText("Remembered store"), selection: $store) {
                        Text(ledgerText("All remembered stores")).tag("")
                        ForEach(Array(Set(items.map(\.approval.branch) + [store])).filter { !$0.isEmpty }.sorted(),id:\.self) { Text($0).tag($0) }
                    }
                    TextField(ledgerText("Filter by purpose"),text:$purpose)
                }
                let filtered = items.filter { (store.isEmpty || $0.approval.branch == store) &&
                    (purpose.isEmpty || $0.approval.purpose.localizedCaseInsensitiveContains(purpose)) }
                if filtered.isEmpty { Text(ledgerText("No matching staples. Open an item’s details on a previous pickup to remember its purpose and store.")) }
                ForEach(filtered) { item in
                    Button { review = item } label: {
                        VStack(alignment:.leading) {
                            Text(item.line.name).font(.headline)
                            Text(verbatim:"\(item.approval.purpose) · \(item.approval.branch)")
                            if let date = item.line.handledAt { Text(ledgerText("Previously handled") + " · " + date.formatted(date:.abbreviated,time:.omitted)) }
                            else if let date = item.line.checkedAt { Text(ledgerText("Previously checked") + " · " + date.formatted(date:.abbreviated,time:.omitted)) }
                            else { Text(ledgerText("Previously on the active list")) }
                        }
                    }
                }
            }
        }.navigationTitle(ledgerText("Review prior staples"))
            .onAppear { store = ledger.shop?.basis.branch.trimmingCharacters(in:.whitespacesAndNewlines) ?? "" }
            .task { await pickup.load() }
            .sheet(isPresented: $showsMembership, onDismiss: { membershipFocused = true }) {
                NavigationStack {
                    MembershipEntryView(household: household)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(tr("Done")) { showsMembership = false }
                            }
                        }
                }.presentationDetents([.large])
            }
            .sheet(item: $review) { item in
                NavigationStack {
                    if permitted && editable {
                        StapleReviewSheet(ledger:ledger, item:item, authorize:{ permitted && editable })
                    } else { Text(ledgerText("Open a current draft pickup to review staples for it.")) }
                }
            }
    }
}

private struct StapleReviewSheet: View {
    @ObservedObject var ledger: LedgerModel
    let item: ReviewedStaple
    let authorize: () -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var amount: String
    @State private var unit: UnitOfMeasure
    @State private var handledLineID: UUID?
    @State private var buyer = ""

    init(ledger: LedgerModel, item: ReviewedStaple, authorize: @escaping () -> Bool) {
        self.ledger = ledger; self.item = item; self.authorize = authorize
        let source = ledger.workspace.shops.first { $0.id == item.source.shopID }
        let quantity = try? source?.quantity(forLineID:item.line.id)
        _amount = State(initialValue:quantity?.amount.description ?? "")
        _unit = State(initialValue:quantity?.unit ?? .count)
    }
    var body: some View {
        Form {
            Text(item.line.name).font(.headline)
            LabeledContent(ledgerText("Purpose"), value:item.approval.purpose)
            LabeledContent(ledgerText("Remembered store"), value:item.approval.branch)
            Text(ledgerText("Review the quantity for this pickup. Enter its price separately after adding the item."))
            TextField(ledgerText("Amount for this pickup, blank if unknown"), text:$amount)
            Picker(ledgerText("Unit"), selection:$unit) {
                ForEach(UnitOfMeasure.allCases,id:\.self) { Text($0.displayName).tag($0) }
            }
            let duplicate = ledger.shop?.matchingStapleLine(named:item.line.name) != nil
            if duplicate { Text(ledgerText("This name is already on this pickup, including its history. Inspect the existing item before changing it.")) }
            Button(ledgerText("Add reviewed need to this pickup")) { apply(.needed) }.disabled(duplicate)
            if let shop = ledger.shop, !shop.openStapleMatches(named: item.line.name).isEmpty {
                Section(ledgerText("Bought by someone else")) {
                    Picker(ledgerText("Item bought on this list"), selection: $handledLineID) {
                        Text(ledgerText("Choose a list item")).tag(nil as UUID?)
                        ForEach(shop.openStapleMatches(named: item.line.name)) { line in
                            let title = ledgerFormat("Item %lld: %@", Int64(line.originalOrder + 1), line.name)
                            let quantity = ledgerQuantity(try? shop.quantity(forLineID: line.id))
                            let purposes = shop.contributions(forLineID: line.id).filter { $0.source.isMeal || $0.source.isProtected }
                                .map { ledgerSourceLabel($0, shop: shop) }.joined(separator: ", ")
                            Text(verbatim: [title, quantity, line.notes, purposes].filter { !$0.isEmpty }.joined(separator: " · ")).tag(Optional(line.id))
                        }
                    }
                    TextField(ledgerText("Handled by"), text: $buyer).submitLabel(.done)
                    Button(ledgerText("Mark this list item handled")) {
                        guard let handledLineID else { return }
                        apply(.alreadyHandled, handledLine: .init(lineID: handledLineID, boughtBy: buyer))
                    }.disabled(handledLineID == nil || buyer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || buyer.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > 512)
                }
            } else {
                Button(ledgerText("Already handled for this pickup")) { apply(.alreadyHandled) }
            }
            Button(ledgerText("Skip on this pickup")) { apply(.skip) }
            LedgerSaveStatus(model:ledger, onRetried:{ dismiss() })
        }.navigationTitle(ledgerText("Review staple")).disabled(ledger.saving || !authorize())
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button(ledgerText("Cancel")) { dismiss() } } }
    }
    private func apply(_ choice: StapleChoice, handledLine: HandledStapleLine? = nil) {
        Task {
            let saved = await ledger.change(key:"recall-\(item.targetID)-\(item.line.id)") { workspace in
                guard authorize() else { throw LedgerError.stalePreview }
                let quantity = choice == .needed ? try ComparisonModel.quantity(amount,unit) : nil
                try workspace.applyStaple(item,choice:choice,quantity:quantity,handledLine:handledLine,at:Date())
            }
            if saved { dismiss() }
        }
    }
}
