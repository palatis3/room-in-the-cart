import SwiftUI
import HouseholdClient

struct SharedPickingLink: View {
    @ObservedObject var household: HouseholdModel
    var body: some View {
        if let shop = household.projection?.shopId.flatMap(UUID.init(uuidString:)),
           household.adultRequestScope(shop: shop, capability: "shared_picking") != nil {
            NavigationLink {
                PrivateAdultRequestSurface(household: household, shopID: shop, capability: "shared_picking") { scope in
                    SharedPickingView(household: household, scope: scope)
                }
            } label: {
                Label(householdTripText("Split this trip"), systemImage: "person.2")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.accessibilityIdentifier("household.sharedPicking")
        }
    }
}

private struct SharedPickingView: View {
    @ObservedObject var household: HouseholdModel
    @StateObject private var model: SharedPickingModel
    @State private var editing = false
    @State private var recipient: UUID?
    @State private var selected = Set<UUID>()
    @State private var expiry = Date()
    @State private var confirmEnd = false
    init(household: HouseholdModel, scope: AdultRequestViewScope) {
        self.household = household
        _model = StateObject(wrappedValue: SharedPickingModel(household: household, scope: scope))
    }
    var body: some View {
        WorkingForm {
            #if DEBUG && targetEnvironment(simulator)
            HouseholdTripOfflineControl()
            #endif
            if let page = model.page, page.expiry.map({ $0 > Date() }) ?? true {
                if page.managed {
                    Section(householdTripText("Share household rows")) {
                        if editing { editor(page) }
                        else {
                            if let id = page.recipientId, let person = page.members.first(where: { $0.id == id }) {
                                LabeledContent(householdTripText("Picking with"), value: person.label)
                            }
                            Button(householdTripText("Choose adult and rows")) {
                                recipient = page.recipientId
                                selected = Set(page.rows.map(\.id))
                                expiry = page.expiry ?? Date().addingTimeInterval(4 * 3600)
                                editing = true
                            }
                            if page.permissionId != nil { Button(householdTripText("End sharing"), role: .destructive) { confirmEnd = true } }
                        }
                    }
                }
                if let until = page.expiry {
                    Section {
                        LabeledContent(householdTripText("Shared until"), value: until.formatted(date: .abbreviated, time: .shortened))
                        Text(householdTripText("The assigned shopper handles checkout."))
                    }
                    ForEach(page.rows) { row in
                        SharedPickingRowView(row: row, permissionID: page.permissionId, model: model, household: household, managed: page.managed)
                    }
                }
            }
            if let notice = model.notice { Text(notice).accessibilityIdentifier("household.picking.notice") }
            Button(householdTripText("Refresh shared rows")) { Task { await model.refresh() } }
            if model.busy { ProgressView(ht("Checking service…")) }
        }
        .disabled(model.busy)
        .navigationTitle(householdTripText("Split this trip"))
        .confirmationDialog(householdTripText("End sharing for this trip?"), isPresented: $confirmEnd, titleVisibility: .visible) {
            Button(householdTripText("End sharing"), role: .destructive) {
                Task { await model.setPermission(recipient: nil, rowIDs: [], until: nil) }
            }
            Button(ht("Cancel"), role: .cancel) { }
        }
        .task {
            await model.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                await model.refresh()
            }
        }
        .task(id: model.page?.expiresAt) {
            guard let expiry = model.page?.expiry else { return }
            do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) } catch { return }
            await model.expire()
        }
        .onChange(of: model.page?.permissionId) { _, _ in editing = false; selected = []; recipient = nil }
        .onDisappear { model.close() }
    }
    @ViewBuilder private func editor(_ page: SharedPickingPage) -> some View {
        Picker(householdTripText("Adult picking with me"), selection: $recipient) {
            Text(householdTripText("Choose an adult")).tag(UUID?.none)
            ForEach(page.members) { Text(verbatim: $0.label).tag(Optional($0.id)) }
        }
        ForEach(page.availableRows) { row in
            Toggle(isOn: Binding(get: { selected.contains(row.id) }, set: { on in
                if on { selected.insert(row.id) } else { selected.remove(row.id) }
            })) {
                VStack(alignment: .leading) {
                    Text(verbatim: row.label)
                    LabeledContent(ht("Whole packs"), value: row.packs.formatted())
                }
            }
        }
        DatePicker(householdTripText("Shared until"), selection: $expiry, in: Date()...Date().addingTimeInterval(86_400))
        Button(householdTripText("Share selected rows")) {
            Task { await model.setPermission(recipient: recipient, rowIDs: selected, until: expiry) }
        }
        .buttonStyle(PrimaryAction()).disabled(recipient == nil || selected.isEmpty || expiry <= Date())
        .accessibilityIdentifier("household.picking.share")
        Button(ht("Cancel")) { editing = false }
    }
}

private struct SharedPickingRowView: View {
    let row: SharedPickingPage.Row
    let permissionID: UUID?
    @ObservedObject var model: SharedPickingModel
    @ObservedObject var household: HouseholdModel
    let managed: Bool
    @State private var packs = 1
    var body: some View {
        Section {
            Text(verbatim: row.label).font(.headline)
                .accessibilityIdentifier("household.picking.row." + row.id.uuidString.lowercased())
            LabeledContent(householdTripText("Packs picked"), value: String(format: householdTripText("%lld of %lld"),
                locale: .current, Int64(row.picked), Int64(row.packs)))
            if let actor = row.claimedByLabel { LabeledContent(householdTripText("Claimed by"), value: actor) }
            else if row.remaining > 0 { Text(householdTripText("Unclaimed")) }
            if let actor = row.lastActorLabel { LabeledContent(householdTripText("Last changed by"), value: actor) }
            if let change = model.pending.first(where: { $0.intent.operation.rowId == row.id }) {
                Label(householdTripText("Pending"), systemImage: "clock")
                if let count = change.intent.operation.packs { LabeledContent(householdTripText("Packs awaiting confirmation"), value: count.formatted()) }
                Button(householdTripText("Retry pending change")) { Task { await model.refresh() } }
            } else {
                if row.remaining > 0, row.claimedBy == nil {
                    Button(householdTripText("Claim this row")) { Task { await model.pick(.claim, row: row) } }
                        .accessibilityIdentifier("household.picking.claim." + row.id.uuidString.lowercased())
                }
                if row.remaining > 0, row.claimedBy == nil || row.claimedBy == model.member {
                    if row.remaining > 1 {
                        Stepper(value: $packs, in: 1...row.remaining) { LabeledContent(householdTripText("Packs to pick"), value: packs.formatted()) }
                    }
                    Button(householdTripText("Mark picked")) { Task { await model.pick(.pick, row: row, packs: min(packs, row.remaining)) } }
                        .buttonStyle(PrimaryAction()).accessibilityIdentifier("household.picking.pick." + row.id.uuidString.lowercased())
                }
                if row.undoOperationId != nil {
                    Button(householdTripText("Undo my last change")) { Task { await model.pick(.undo, row: row) } }
                }
            }
            if !managed, let field = SharedMessageField(.pickingRow, row.safetyId.uuidString, 1, .label, row.label) {
                SharedSafetyButton(channel: household.sharedSafetyChannel(afterBlock: {
                    model.close()
                    await model.refresh()
                    await household.refresh()
                }), fields: [field])
            }
        }
        .onChange(of: row.revision) { _, _ in packs = min(packs, max(1, row.remaining)) }
        .onChange(of: permissionID) { _, _ in packs = 1 }
    }
}
