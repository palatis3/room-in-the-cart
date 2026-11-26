import CoreDomain
import SwiftUI

func tripReminderText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "TripReminders")
}

private func tripReminderFormat(_ key: String, _ value: String) -> String {
    String(format: tripReminderText(key), locale: .current, value)
}

struct TripRequestSummary: View {
    let shop: ShoppingLedger
    let line: ShoppingLine

    var body: some View {
        if shop.mainTripReasonID == line.id {
            Label(tripReminderText("Main reason for this trip"), systemImage: "flag")
                .font(.subheadline).accessibilityIdentifier("tripReason.marker")
        }
    }
}

struct TripItemSettingsLink: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let line: ShoppingLine
    @State private var showing = false

    var body: some View {
        if !line.isTrashed && !line.isHandled && (!line.isChecked || line.emptyJug != nil || shop.mainTripReasonID == line.id) {
            Button {
                showing = true
            } label: {
                Label(tripReminderText("Trip reminders"), systemImage: "checklist")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("tripReminders.edit")
            .sheet(isPresented: $showing) {
                PrivateShoppingSheet(model: model) {
                    TripReminderEditor(model: model, shopID: shop.id, lineID: line.id)
                }
            }
        }
    }
}

private struct TripReminderEditor: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    let lineID: UUID
    @Environment(\.shoppingListAuthorization) private var authorize
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WorkingForm {
            if let shop = model.shop, shop.id == shopID,
               let line = shop.lines.first(where: { $0.id == lineID && !$0.isTrashed && !$0.isHandled }) {
                let marked = shop.mainTripReasonID == line.id
                if marked || !line.isChecked {
                    Section(tripReminderText("Main reason for this trip")) {
                        if let other = shop.lines.first(where: { $0.id == shop.mainTripReasonID && $0.id != lineID && !$0.isTrashed }) {
                            Text(tripReminderFormat("Current main reason: %@", other.name))
                        }
                        Button(marked ? tripReminderText("Remove main reason") : tripReminderFormat("Make %@ the main reason", line.name)) {
                            Task {
                                await model.editShop(key: "trip-reason-\(lineID)", shopID: shopID,
                                    authorize: { authorize() && model.shop?.id == shopID }) { current in
                                    try current.setMainTripReason(marked ? nil : lineID, replacing: shop.mainTripReasonID, expectedRevision: shop.revisionID)
                                }
                            }
                        }.accessibilityIdentifier("tripReminders.mainReason")
                        .disabled(model.saving || model.hasPendingSave)
                    }
                }
                Section(tripReminderText("Before leaving home")) {
                    Text(verbatim: line.name).font(.headline)
                    Button(line.emptyJug == nil ? tripReminderText("Remind me to bring the empty jug") : tripReminderText("Remove empty jug reminder")) {
                        Task {
                            await model.editShop(key: "trip-jug-setup-\(lineID)", shopID: shopID,
                                authorize: { authorize() && model.shop?.id == shopID }) { current in
                                try current.setEmptyJug(line.emptyJug == nil ? .toPack : nil, replacing: line.emptyJug, for: lineID, expectedRevision: shop.revisionID)
                            }
                        }
                    }.accessibilityIdentifier("tripReminders.emptyJug")
                    .disabled(model.saving || model.hasPendingSave)
                }
            }
            if model.hasPendingSave || model.error != nil { LedgerSaveStatus(model: model) }
        }
        .navigationTitle(tripReminderText("Trip reminders"))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ledgerText("Done")) { dismiss() }.accessibilityIdentifier("tripReminders.closeEditor") } }
    }
}

struct TripDepartureSection: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    @Environment(\.shoppingListAuthorization) private var authorize

    var body: some View {
        let lines = shop.departureReminderLines
        if !lines.isEmpty {
            Section(tripReminderText("Before leaving home")) {
                ForEach(lines) { line in
                    let packed = line.emptyJug == .packed
                    Button {
                        Task {
                            await model.editShop(key: "trip-pack-\(line.id)", shopID: shop.id,
                                authorize: { authorize() && model.shop?.id == shop.id }) { current in
                                try current.setEmptyJug(packed ? .toPack : .packed, replacing: line.emptyJug, for: line.id, expectedRevision: shop.revisionID)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(tripReminderFormat("Empty jug for %@", line.name), systemImage: packed ? "checkmark.square" : "square")
                            Text(packed ? tripReminderText("Packed · Undo") : tripReminderText("Mark packed"))
                                .font(.subheadline)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.saving || model.hasPendingSave)
                    .accessibilityIdentifier("tripReminders.pack-\(line.id)")
                }
            }
        }
    }
}

/// The private list can reach this checklist before the shopper enters in-store mode.
struct TripDepartureLink: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    @State private var showing = false

    var body: some View {
        if !shop.departureReminderLines.isEmpty {
            Button { showing = true } label: {
                Label(tripReminderText("Before leaving home"), systemImage: "door.left.hand.open")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("tripReminders.departure")
            .sheet(isPresented: $showing) {
                PrivateShoppingSheet(model: model) {
                    WorkingForm {
                        if let current = model.shop, current.id == shop.id {
                            TripDepartureSection(model: model, shop: current)
                        }
                        if model.hasPendingSave || model.error != nil { LedgerSaveStatus(model: model) }
                    }
                    .navigationTitle(tripReminderText("Bring from home"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ledgerText("Done")) { showing = false }.accessibilityIdentifier("tripReminders.closeDeparture") } }
                }
            }
        }
    }
}

struct TripFinishButton: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    let inspect: (UUID) -> Void
    let finish: () -> Void
    @Environment(\.shoppingListAuthorization) private var authorize
    @State private var review: ShoppingLedger?

    var body: some View {
        Button(ledgerText("Done")) {
            // A pending save can be retried from the list. Closing this presentation
            // must also remain available while that save is unresolved.
            guard !model.saving, !model.hasPendingSave, model.error == nil,
                  let shop = model.shop, shop.id == shopID, authorize(), shop.mainTripReasonID != nil
            else { finish(); return }
            if shop.outstandingMainTripReason != nil { review = shop }
            else { finishReviewed(shop) }
        }
        .accessibilityIdentifier("tripReminders.finish")
        .alert(tripReminderText("Main reason for this trip"), isPresented: Binding(
            get: { review != nil }, set: { if !$0 { review = nil } }), presenting: review) { shop in
                if let line = shop.outstandingMainTripReason {
                    Button(tripReminderText("Review item")) {
                        guard authorize(), model.shop?.id == shopID, model.shop?.revisionID == shop.revisionID, model.shop?.mainTripReasonID == line.id else { return }
                        inspect(line.id)
                    }
                    Button(tripReminderText("Keep on list and finish")) { finishReviewed(shop) }
                    Button(tripReminderText("Keep shopping"), role: .cancel) {}
                }
            } message: { shop in
                if let line = shop.outstandingMainTripReason { Text(tripReminderFormat("%@ is still on your list.", line.name)) }
            }
    }

    private func finishReviewed(_ shop: ShoppingLedger) {
        Task {
            let saved = await model.editShop(key: "finish-trip-reason-\(shopID)", shopID: shopID,
                authorize: { authorize() && model.shop?.id == shopID }) { current in
                try current.setMainTripReason(nil, replacing: shop.mainTripReasonID, expectedRevision: shop.revisionID)
            }
            if saved && authorize() && model.shop?.id == shopID { finish() }
        }
    }
}
