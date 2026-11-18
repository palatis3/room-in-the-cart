import CoreDomain
import SwiftUI

struct PantryReservationSummary: View {
    let edit: InventoryReservationEdit
    let claim: InventoryReservation?
    var body: some View {
        switch edit {
        case let .reserve(_, purpose, amount, day):
            Text(purpose).font(.headline)
            LabeledContent(pantryText("Set aside"), value: pantryQuantity(amount))
            if let day { LabeledContent(pantryText("For date"), value: day.iso8601) }
        case let .release(id, _, amount):
            Text(claim?.name ?? pantryFormat("Reservation %@", String(id.uuidString.suffix(8)))).font(.headline)
            if let amount { LabeledContent(pantryText("Release amount"), value: pantryQuantity(amount)) }
            else { Text(pantryText("Release this entire reservation")) }
        }
    }
}

struct PantryReservationSection: View {
    @ObservedObject var model: PantryModel
    let lot: InventoryLot
    let availabilityNeedsReview: Bool
    @State private var draft: Draft?
    @State private var purpose = ""
    @State private var amount = ""
    @State private var date = Date()
    @State private var includeDate = false
    @State private var releaseAll = false
    @FocusState private var editingAmount: Bool

    private struct Draft {
        let basis: PantryReviewedFood
        let claim: InventoryReservation?
    }

    var body: some View {
        Section(pantryText("Reservations for this batch")) {
            if let snapshot = model.snapshot {
                let rows = snapshot.availability.reservations(for: lot, among: snapshot.reservations)
                ForEach(rows) { row in
                    let claim = row.reservation
                    if !availabilityNeedsReview || claim.lotID == lot.id {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(claim.name).font(.headline)
                            LabeledContent(pantryText("Reserved need"), value: pantryQuantity(row.coverage.requested))
                            if let day = claim.personal?.day { LabeledContent(pantryText("For date"), value: day.iso8601) }
                            if !availabilityNeedsReview {
                                if let edge = row.allocation {
                                    let portion = Quantity(amount: edge.amount, unit: edge.unit, originalLiteral: edge.amount.description)
                                    coverageAmount("Confirmed from this batch", portion, identifier: "pantry.claimBacking.\(claim.id.uuidString)")
                                } else if claim.lotID == nil {
                                    Text(pantryText("This food still needs a confirmed batch."))
                                }
                                if let shortage = row.coverage.shortfall, shortage.amount > .zero {
                                    coverageAmount("Still needed across batches", shortage, identifier: "pantry.claimShortfall.\(claim.id.uuidString)")
                                }
                            }
                            if availabilityNeedsReview || row.coverage.unresolved {
                                Text(pantryText("This reservation needs review. Its promise is not released."))
                            }
                            if claim.personal != nil && claim.state == .active {
                                Button(pantryText("Release food from this reservation")) { begin(claim: claim) }
                                    .frame(minHeight: 44).disabled(!model.canEdit)
                            }
                        }
                    }
                }
                if draft == nil {
                    let free = snapshot.availability.lots.first { $0.id == lot.id }?.free
                    Button(pantryText("Reserve food")) { begin(claim: nil) }
                        .frame(minHeight: 44).accessibilityIdentifier("pantry.reserve")
                        .disabled(!model.canEdit || availabilityNeedsReview || free.map { $0.amount > .zero } != true)
                }
            }
            if let draft {
                if let claim = draft.claim {
                    Text(claim.name).font(.headline)
                    Picker(pantryText("Release from reservation"), selection: $releaseAll) {
                        Text(pantryText("Release part")).tag(false)
                        Text(pantryText("Release the entire reservation")).tag(true)
                    }
                } else {
                    TextField(pantryText("Reservation purpose"), text: $purpose)
                    Button(pantryText("Tomorrow’s lunch")) {
                        let calendar = Calendar.current
                        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) {
                            date = tomorrow; includeDate = true; purpose = pantryText("Lunch")
                        }
                    }.frame(minHeight: 44)
                    Toggle(pantryText("Set a date"), isOn: $includeDate)
                    if includeDate { DatePicker(pantryText("For date"), selection: $date, displayedComponents: .date) }
                }
                if draft.claim == nil || !releaseAll {
                    TextField(pantryFormat("Amount in %@", pantryUnit(draft.claim?.amount?.unit ?? lot.unit)), text: $amount)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($editingAmount)
                        .accessibilityIdentifier("pantry.reservationAmount")
                }
                Button(pantryText("Review reservation")) {
                    Task {
                        let action: PantryModel.ReservationAction
                        if let claim = draft.claim { action = .release(claim, amount: releaseAll ? nil : amount) }
                        else {
                            let day = includeDate ? try? MealDay(date: date, timeZoneIdentifier: TimeZone.current.identifier) : nil
                            guard !includeDate || day != nil else { return }
                            action = .reserve(purpose: purpose, amount: amount, day: day)
                        }
                        await model.prepareReservation(action, lotID: lot.id, basis: draft.basis)
                    }
                }.frame(minHeight: 44).disabled(!model.canEdit)
                Button(pantryText("Cancel")) { self.draft = nil }.frame(minHeight: 44)
            }
        }
        .toolbar {
            if editingAmount {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(pantryText("Done")) { editingAmount = false }
                        .accessibilityIdentifier("pantry.reservationAmountDone")
                }
            }
        }
        .onChange(of: model.savedLotID) { _, id in if id == lot.id { draft = nil } }
        .onChange(of: model.snapshot?.state.revision) { _, _ in draft = nil }
    }

    private func coverageAmount(_ text: String, _ amount: Quantity, identifier: String) -> some View {
        LabeledContent(pantryText(text), value: pantryQuantity(amount))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(pantryText(text))
            .accessibilityValue(pantryQuantity(amount))
            .accessibilityIdentifier(identifier)
    }

    private func begin(claim: InventoryReservation?) {
        guard let snapshot = model.snapshot else { return }
        draft = Draft(basis: PantryReviewedFood(id: lot.foodID, name: lot.name, inventoryWorkspaceID: snapshot.state.workspaceID,
                                                inventoryRevision: snapshot.state.revision), claim: claim)
        amount = ""; purpose = ""; includeDate = false; releaseAll = false
    }
}
