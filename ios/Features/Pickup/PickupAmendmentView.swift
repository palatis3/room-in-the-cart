import SwiftUI
import CoreDomain

struct PickupAmendmentSection: View {
    @ObservedObject var model: PickupModel
    let shopID: UUID
    let placement: ReportedPlacement
    @EnvironmentObject private var access: WorkspaceAccess

    var body: some View {
        if access.unlocked, let journey = model.journey, journey.id == shopID,
           journey.basket?.placements.first == placement {
            if let base = PickupAmendmentBase(journey: journey, workspaceID: model.sourceWorkspaceID, actorID: access.localActorID) {
                Section {
                    NavigationLink(pTr("Record a retailer-confirmed change")) {
                        PickupAmendmentEditor(model: model, base: base)
                    }.accessibilityIdentifier("pickup.amendment.open")
                }
            }
        }
    }
}

struct PickupAmendmentHistory: View {
    let basket: BasketPlan?
    @EnvironmentObject private var access: WorkspaceAccess

    var body: some View {
        if let basket, !basket.amendments.isEmpty {
            Section(pTr("Current confirmed order")) {
                if basket.effectiveOrderLines?.isEmpty == true { Text(pTr("All ordered items were cancelled.")) }
                Text(pTr("Recheck the amended checkout total with the retailer."))
                ForEach(basket.effectiveOrderLines ?? []) { line in
                    Text(line.name)
                    Text(pQuantity(line.quantity))
                    Text(pickupOfferPriceText(line.expectedCost)).font(.caption)
                }
            }
            ForEach(Array(basket.amendments.enumerated().reversed()), id: \.element.id) { index, event in
                Section(pTr("Retailer confirmation")) {
                    Text(event.retailerReference).textSelection(.enabled)
                    LabeledContent(pTr("Reported by"), value: pickupReporterLabel(event.recordedByLocalActorID, localActorID: access.localActorID))
                    Text(event.confirmedAt.formatted(date: .long, time: .shortened))
                    AmendmentChanges(before: index == 0 ? basket.reportedOrderLines ?? [] : basket.amendments[index - 1].lines,
                                     after: event.lines)
                }
            }
        }
    }
}

private struct AmendmentChanges: View {
    let before: [BasketLine]
    let after: [BasketLine]

    var body: some View {
        ForEach(PickupAmendmentDelta.differences(from: before, to: after)) { change in
            VStack(alignment: .leading, spacing: 5) {
                Text(change.after?.name ?? change.before?.name ?? "").font(.headline)
                if let before = change.before {
                    Text(pTr("Previously ordered"))
                    Text(pQuantity(before.quantity))
                    Text(pickupOfferPriceText(before.expectedCost)).font(.caption)
                }
                if let after = change.after {
                    Text(pTr("Confirmed by the retailer"))
                    Text(pQuantity(after.quantity))
                    Text(pickupOfferPriceText(after.expectedCost)).font(.caption)
                } else {
                    Text(pTr("Removed from this order"))
                }
            }
        }
    }
}

private struct AmendmentLineSelection: Identifiable {
    let id: UUID
    let line: BasketLine?

    init(_ line: BasketLine? = nil) {
        id = line?.id ?? UUID()
        self.line = line
    }
}

private struct PickupAmendmentEditor: View {
    @ObservedObject var model: PickupModel
    @EnvironmentObject private var access: WorkspaceAccess
    @Environment(\.dismiss) private var dismiss
    @State private var base: PickupAmendmentBase
    @State private var lines: [BasketLine]
    @State private var editing: AmendmentLineSelection?
    @State private var reference = ""
    @State private var confirmedAt = Date()
    @State private var review: PickupAmendmentReview?
    @FocusState private var referenceFocused: Bool

    init(model: PickupModel, base: PickupAmendmentBase) {
        self.model = model
        _base = State(initialValue: base)
        _lines = State(initialValue: base.lines)
    }

    private var canAccess: Bool {
        access.unlocked && access.localActorID == base.actorID && model.sourceWorkspaceID == base.workspaceID &&
            model.selectedID == base.shopID && model.journey?.basket?.placements.first?.id == base.placementID
    }

    var body: some View {
        Form {
            if canAccess {
                PickupSaveStatus(model: model)
                if let review {
                    Section(pTr("Retailer confirmation")) {
                        Text(review.event.retailerReference)
                        Text(review.event.confirmedAt.formatted())
                        AmendmentChanges(before: base.lines, after: review.event.lines)
                    }
                    Button(pTr("Confirm retailer amendment")) {
                        Task {
                            if await model.confirmRetailerAmendment(review, currentActor: {
                                access.unlocked ? access.localActorID : nil
                            }) { dismiss() }
                        }
                    }.accessibilityIdentifier("pickup.amendment.confirm")
                    Button(pTr("Edit this review")) { self.review = nil }.disabled(model.hasPendingSave)
                } else {
                    Section {
                        Text(pTr("Enter only changes the retailer confirmed. Record arrivals and payments separately."))
                        ForEach(lines) { line in
                            Button(String(format: pTr("Edit %@"), line.name)) { editing = AmendmentLineSelection(line) }
                        }
                        Button(pTr("Add a confirmed item")) { editing = AmendmentLineSelection() }
                    }
                    Section(pTr("Retailer confirmation")) {
                        TextField(pTr("Retailer reference or confirmation details"), text: $reference)
                            .focused($referenceFocused).accessibilityIdentifier("pickup.amendment.reference")
                        DatePicker(pTr("Retailer confirmed at"), selection: $confirmedAt, in: ...Date())
                    }
                    Button(pTr("Review confirmed changes")) {
                        referenceFocused = false
                        let event = ConfirmedAmendment(id: UUID(), placementID: base.placementID, previousAmendmentID: base.predecessor,
                            lines: lines, confirmedAt: confirmedAt, retailerReference: reference, recordedByLocalActorID: base.actorID)
                        review = PickupAmendmentReview(base: base, event: event)
                    }.accessibilityIdentifier("pickup.amendment.preview")
                        .disabled(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || base.lines == lines)
                }
            }
        }
        .navigationTitle(pTr("Amend placed order"))
        .keyboardDoneAction(visible: referenceFocused, title: pTr("Done")) { referenceFocused = false }
        .disabled(model.saving)
        .sheet(item: $editing) { selection in
            if canAccess {
                AmendmentLineEditor(selection: selection) { updated in
                    guard canAccess else { return }
                    if let index = lines.firstIndex(where: { $0.id == selection.id }) {
                        if let updated { lines[index] = updated } else { lines.remove(at: index) }
                    } else if let updated { lines.append(updated) }
                    editing = nil
                }
            }
        }
        .onChange(of: canAccess) { _, active in
            if !active { editing = nil; dismiss() }
        }
    }
}

private struct AmendmentLineEditor: View {
    let selection: AmendmentLineSelection
    let save: (BasketLine?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var amount: String
    @State private var unit: UnitOfMeasure
    @State private var price = ""
    @State private var invalid = false
    @FocusState private var focused: Field?
    private enum Field { case name, amount, price }

    init(selection: AmendmentLineSelection, save: @escaping (BasketLine?) -> Void) {
        self.selection = selection
        self.save = save
        _name = State(initialValue: selection.line?.name ?? "")
        _amount = State(initialValue: selection.line?.quantity.amount.description ?? "")
        _unit = State(initialValue: selection.line?.quantity.unit ?? .count)
    }

    var body: some View {
        NavigationStack {
            Form {
                if selection.line == nil {
                    TextField(pTr("Item name"), text: $name).focused($focused, equals: .name)
                } else { Text(name) }
                TextField(pTr("Confirmed ordered amount"), text: $amount)
                    .focused($focused, equals: .amount).accessibilityIdentifier("pickup.amendment.amount")
                Picker(pTr("Unit"), selection: $unit) {
                    ForEach(UnitOfMeasure.allCases.filter { selection.line?.quantity.unit.dimension == nil ||
                        $0.dimension == selection.line?.quantity.unit.dimension }, id: \.self) { Text(pTr($0.rawValue)).tag($0) }
                }
                TextField(pTr("Confirmed line total (USD), if provided"), text: $price)
                    .keyboardType(.decimalPad).focused($focused, equals: .price)
                if invalid { Text(pTr("Enter an item, a positive exact amount and a valid line total if provided.")) }
                Button(pTr("Keep line for review")) { keepLine() }.accessibilityIdentifier("pickup.amendment.keepLine")
                if selection.line != nil {
                    Button(pTr("Remove from the amended order"), role: .destructive) { save(nil) }
                }
            }
            .navigationTitle(pTr("Confirmed order line"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pTr("Cancel")) { dismiss() } } }
            .keyboardDoneAction(visible: focused != nil, title: pTr("Done")) { focused = nil }
        }
    }

    private func keepLine() {
        do {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let entered = try LedgerEntry.quantity(amount, unit), entered.amount > .zero else {
                invalid = true
                return
            }
            let old = selection.line
            let sameAmount = old?.quantity.amount == entered.amount && old?.quantity.unit == unit
            let quantity = sameAmount ? old?.quantity ?? entered : entered
            let cost: CostEvidence
            if let money = try ComparisonModel.money(price) {
                cost = .exact(money)
            } else if sameAmount, let old {
                cost = old.expectedCost
            } else {
                cost = .unknown(reason: pTr("Retailer line total not confirmed"))
            }
            save(BasketLine(id: selection.id, name: old?.name ?? trimmed, quantity: quantity, expectedCost: cost,
                            itemExclusions: old?.itemExclusions ?? [], packages: sameAmount ? old?.packages ?? [] : []))
        } catch { invalid = true }
    }
}
