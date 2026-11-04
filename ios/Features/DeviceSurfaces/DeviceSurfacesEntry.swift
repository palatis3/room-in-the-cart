import SwiftUI
import CoreDomain
import DeviceSurfaces

struct DeviceSurfacesEntry: View {
    @ObservedObject var composition: DeviceSurfacesComposition
    @State private var selectedShop: UUID?
    var body: some View {
        Group {
            if composition.privateAuthorized {
                List {
                    Section {
                        Text(SurfaceCopy.text("Selected text waits for your review. Nothing has been added to a shop."))
                        Picker(SurfaceCopy.text("Shopping list"), selection: $selectedShop) {
                            Text(SurfaceCopy.text("Choose a shopping list")).tag(Optional<UUID>.none)
                            ForEach(composition.shops, id: \.id) { Text($0.title).tag(Optional($0.id)) }
                        }
                    }
                    if !composition.inboxAvailable { Text(SurfaceCopy.text("Selected text is unavailable on this installation.")) }
                    ForEach(composition.entries) { entry in
                        Section {
                            Text(entry.originalText).textSelection(.enabled)
                            if let edited = entry.editedText { Text(edited) }
                            Text(entry.receipt.expiresAt.formatted(date: .abbreviated, time: .shortened)).font(.footnote)
                            Button(SurfaceCopy.text("Review selected text")) { if let selectedShop { Task { await composition.review(entry, shopID: selectedShop) } } }.disabled(selectedShop == nil)
                            Button(SurfaceCopy.text("Discard selected text"), role: .destructive) { Task { await composition.discard(entry) } }
                        }
                    }
                    Section {
                        NavigationLink(SurfaceCopy.text("Local reminders")) { SurfaceReminderList(composition: composition) }
                    }
                    if let message = composition.message { Text(message) }
                    Button(SurfaceCopy.text("Try again")) { Task { await composition.foreground() } }
                }.disabled(composition.busy)
            } else { SurfaceUnavailableView() }
        }.navigationTitle(SurfaceCopy.text("Device shortcuts"))
            .task { await composition.foreground(); if selectedShop == nil { selectedShop = composition.shops.first?.id } }
            .sheet(item: $composition.draft) { _ in NavigationStack { SurfaceImportReview(composition: composition) } }
    }
}

private struct SurfaceImportReview: View {
    @ObservedObject var composition: DeviceSurfacesComposition
    var body: some View {
        Group {
            if let draft = composition.draft, composition.privateAuthorized {
                Form {
                    Section(SurfaceCopy.text("Original wording")) { Text(draft.originalText).textSelection(.enabled) }
                    ForEach(draft.preview.lines) { row in
                        Section {
                            SurfaceImportedLineEditor(row: row, locked: draft.phase == .committing) { name, amount, unit in composition.editDraftLine(row.id, name: name, amount: amount, unit: unit) }
                            Text(row.originalText).font(.footnote)
                            if row.quantity == nil { Text(SurfaceCopy.text("Quantity unresolved")) }
                            Picker(SurfaceCopy.text("How to add this line"), selection: Binding(get: { choice(draft.decisions[row.id]) }, set: { setChoice($0, row: row, draft: draft) })) {
                                Text(SurfaceCopy.text("Choose how to add")).tag("")
                                Text(SurfaceCopy.text("Add as a separate line")).tag("new")
                                if let shop = composition.shop(draft.preview.shopID) {
                                    ForEach(shop.lines.filter { row.duplicateLineIDs.contains($0.id) }, id: \.id) { line in
                                        Text(SurfaceCopy.text("Merge same need") + ": " + line.name).tag("merge:" + line.id.uuidString)
                                        Text(SurfaceCopy.text("Add amount") + ": " + line.name).tag("add:" + line.id.uuidString)
                                    }
                                }
                                ForEach(draft.preview.lines.filter { row.duplicateLineIDs.contains($0.proposedLineID) && draft.decisions[$0.id] == .addNew }) { previous in
                                    Text(SurfaceCopy.text("Merge same need") + ": " + previous.name).tag("merge:" + previous.proposedLineID.uuidString)
                                    Text(SurfaceCopy.text("Add amount") + ": " + previous.name).tag("add:" + previous.proposedLineID.uuidString)
                                }
                                Text(SurfaceCopy.text("Skip this line")).tag("skip")
                            }.disabled(draft.phase == .committing)
                        }
                    }
                    Section {
                        Button(SurfaceCopy.text(draft.phase == .committing ? "Retry reviewed import" : "Add reviewed list")) { Task { await composition.addReviewedList() } }
                            .disabled(!draft.preview.lines.allSatisfy { draft.decisions[$0.id] != nil } || draft.preview.lines.isEmpty)
                        Button(SurfaceCopy.text("Reopen saved list before retry")) { Task { await composition.recoverImport() } }
                        Text(SurfaceCopy.text("An interrupted import reopens the same reviewed operation. It never adds the list again automatically."))
                        if let message = composition.message { Text(message) }
                    }
                }.disabled(composition.busy)
            } else { SurfaceUnavailableView() }
        }.navigationTitle(SurfaceCopy.text("Review selected text"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(SurfaceCopy.text("Cancel")) { composition.cancelReview() }.disabled(composition.busy) } }
            .interactiveDismissDisabled(composition.busy)
    }
    private func choice(_ value: ImportResolution?) -> String {
        switch value { case .addNew: return "new"; case .skip: return "skip"; case .addToLine(let id): return "add:" + id.uuidString; case .mergeDuplicate(let id): return "merge:" + id.uuidString; case nil: return "" }
    }
    private func setChoice(_ value: String, row: StagedImportLine, draft: SurfaceImportDraft) {
        var next = draft
        if value == "new" { next.decisions[row.id] = .addNew }
        else if value == "skip" { next.decisions[row.id] = .skip }
        else {
            let parts = value.split(separator: ":", maxSplits: 1)
            if parts.count == 2, let id = UUID(uuidString: String(parts[1])) { next.decisions[row.id] = parts[0] == "add" ? .addToLine(id) : .mergeDuplicate(id) }
            else { next.decisions[row.id] = nil }
        }
        if next.decisions[row.id] != .addNew {
            for other in next.preview.lines {
                if next.decisions[other.id] == .mergeDuplicate(row.proposedLineID) || next.decisions[other.id] == .addToLine(row.proposedLineID) { next.decisions[other.id] = nil }
            }
        }
        composition.saveDraft(next)
    }
}

private struct SurfaceReminderList: View {
    @ObservedObject var composition: DeviceSurfacesComposition
    var body: some View {
        List {
            Text(SurfaceCopy.text("Choose a reminder for this item. The notification contains no grocery or budget details."))
            ForEach(composition.reminderTargets) { target in
                NavigationLink(target.title) { SurfaceReminderSetup(composition: composition, target: target) }
            }
        }.navigationTitle(SurfaceCopy.text("Local reminders"))
    }
}
struct SurfaceUnavailableView: View {
    var body: some View { ContentUnavailableView(SurfaceCopy.text("Open the app to review this item"), systemImage: "lock", description: Text(SurfaceCopy.text("This shortcut is unavailable in the current workspace. Unlock or choose an authorized workspace in the app."))) }
}

struct DeviceSurfacesDestination: View {
    @ObservedObject var composition: DeviceSurfacesComposition
    let destination: SurfacePresentedDestination
    @ObservedObject var ledger: LedgerModel
    @ObservedObject var pickup: PickupModel
    @ObservedObject var household: HouseholdModel
    @State private var selected = false
    @State private var nextShopRequested = false
    @AccessibilityFocusState private var nextShopFocused: Bool
    var body: some View {
        Group {
            switch destination {
            case .ownRequest:
                if household.projection?.role == "contributor", !household.locked { HouseholdSettingsView(model: household) } else { SurfaceUnavailableView() }
            case .unavailable: SurfaceUnavailableView()
            case .capture:
                if composition.privateAuthorized, let shop = ledger.shop { LedgerImportView(model: ledger, shopID: shop.id) }
                else if composition.privateAuthorized { LedgerHomeView(model: ledger) }
                else { SurfaceUnavailableView() }
            case .shop(let id):
                if composition.privateAuthorized, selected, ledger.shop?.id == id { LedgerHomeView(model: ledger) }
                else { SurfaceUnavailableView() }
            case .offer(let journey, let offerID):
                if composition.privateAuthorized, selected, pickup.journey?.id == journey, let offer = pickup.journey?.unfilledOffers.first(where: { $0.id == offerID }) {
                    Form {
                        Text(offer.replacement)
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(pTr(context.date >= offer.deadline.cutoff ? "Await pickup · fill still unknown" : "Decision pending before cutoff"))
                        }
                        Text("\(pickupOfferCutoffText(offer)) · \(offer.deadline.timeZoneID)")
                        NavigationLink(tr("Pickup, repairs and handoffs")) { PickupHomeView(model: pickup).environment(\.pickupLedger, ledger) }
                    }
                } else { SurfaceUnavailableView() }
            case .deferral(let journey, let needID):
                if composition.privateAuthorized, selected, pickup.journey?.id == journey, let need = pickup.journey?.deferred.first(where: { $0.id == needID && $0.status == "review" }) {
                    Form { Text(need.line.name); Button(SurfaceCopy.text("Review next shop")) { nextShopRequested = true }.accessibilityFocused($nextShopFocused).environment(\.pickupLedger, ledger) }
                } else { SurfaceUnavailableView() }
            }
        }.modifier(PickupNextShopRoute(model: pickup, requested: $nextShopRequested) { nextShopFocused = true })
        .task {
            guard composition.privateAuthorized else { return }
            // A newer pickup selection can arrive after route resolution. The
            // shop view above checks identity; presentation must never reselect.
            switch destination {
            case .offer(let id, _), .deferral(let id, _): if composition.privateAuthorized { pickup.selectedID = id }
            default: break }
            selected = true
        }
    }
}

private struct SurfaceImportedLineEditor: View {
    let row: StagedImportLine
    let locked: Bool
    let apply: (String, String, UnitOfMeasure) -> Void
    @State private var name: String
    @State private var amount: String
    @State private var unit: UnitOfMeasure
    init(row: StagedImportLine, locked: Bool, apply: @escaping (String, String, UnitOfMeasure) -> Void) {
        self.row = row; self.locked = locked; self.apply = apply
        _name = State(initialValue: row.name)
        _amount = State(initialValue: row.quantity.map { ledgerAmountInput($0.amount) } ?? "")
        _unit = State(initialValue: row.quantity?.unit ?? .count)
    }
    var body: some View {
        VStack(alignment: .leading) {
            TextField(SurfaceCopy.text("Item name"), text: $name)
            TextField(SurfaceCopy.text("Amount, unknown if blank"), text: $amount).keyboardType(.decimalPad)
            Picker(SurfaceCopy.text("Unit"), selection: $unit) { ForEach(UnitOfMeasure.allCases, id: \.self) { Text($0.displayName).tag($0) } }
            Button(SurfaceCopy.text("Apply line edits")) { apply(name, amount, unit) }
        }.disabled(locked)
    }
}
