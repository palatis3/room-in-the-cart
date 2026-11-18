import SwiftUI
import UIKit
import CoreDomain

/// Default arrival keys are stable across reopening an order. Only an explicit new delivery creates a new automatic segment.
struct ArrivalDeliveryReferences {
    var receipt = ""
    var segment = ""
    private var additionalSegment: UUID?

    mutating func startAnother() {
        additionalSegment = UUID()
        segment = ""
    }

    func key(orderID: UUID, line: PickupOrderLine) -> ReceiptKey {
        let event = receipt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? orderID.uuidString : receipt
        let part = segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? additionalSegment?.uuidString ?? "1" : segment
        return ReceiptKey(sourceEventID: event, orderLineID: line.id, branchID: line.branchID, segmentID: part)
    }

    func canRecord(_ key: ReceiptKey, in pickup: PickupLedger) -> Bool {
        if additionalSegment != nil { return true }
        let previous = pickup.receipts.filter { $0.key.orderLineID == key.orderLineID }
        return previous.isEmpty || previous.contains { $0.key == key }
    }
}

private struct ArrivalLineEntry {
    let lineID: UUID?
    var disposition: ReceiptDisposition = .received {
        didSet { if disposition != oldValue { matched = false } }
    }
    var item: String {
        didSet { if item != oldValue { matched = false } }
    }
    var received = ""
    var usable = ""
    var unit: UnitOfMeasure {
        didSet { if unit != oldValue { matched = false } }
    }
    var matched = false
    var observationID = UUID()

    init(line: PickupOrderLine? = nil) {
        lineID = line?.id
        item = line?.name ?? ""
        unit = line?.ordered.unit ?? .count
    }
}

struct PickupArrivalView: View {
    private enum Field: Hashable { case item, received, usable, evidence, segment }
    @FocusState private var focused: Field?
    @ObservedObject var model: PickupModel
    @State private var entry = ArrivalLineEntry()
    @State private var references = ArrivalDeliveryReferences()
    @State private var showingReferences = false
    @State private var entryOrderID: UUID?
    @State private var occurred = Date()
    @State private var formError: String?

    private var orderLines: [PickupOrderLine] { model.journey?.pickup?.orderLines ?? [] }
    private var selectedLine: PickupOrderLine? { orderLines.first { $0.id == entry.lineID } }
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            Section(pTr("Review discrepancies")) {
                Text(pTr("Unchecked lines remain unverified. Received food and confirmed usable food are separate."))
                Picker(pTr("Original order line"), selection: Binding(get: { entry.lineID }, set: { id in
                    guard id != entry.lineID else { return }
                    entry = ArrivalLineEntry(line: orderLines.first { $0.id == id })
                    formError = nil
                })) {
                    Text(pTr("Choose a line")).tag(UUID?.none)
                    ForEach(orderLines) { line in Text(line.name).tag(Optional(line.id)) }
                }
                Picker(pTr("What happened"), selection: $entry.disposition) {
                    Text(pTr("Received")).tag(ReceiptDisposition.received)
                    Text(pTr("No fill")).tag(ReceiptDisposition.noFill)
                    Text(pTr("Partial fill")).tag(ReceiptDisposition.partial)
                    Text(pTr("Wrong item")).tag(ReceiptDisposition.wrongItem)
                    Text(pTr("Late arrival")).tag(ReceiptDisposition.late)
                }
                TextField(pTr("Actual item name"), text: $entry.item)
                    .focused($focused, equals: .item)
                quantityField(pTr("Physical amount received"), text: $entry.received, field: .received)
                quantityField(pTr("Confirmed usable amount (optional)"), text: $entry.usable, field: .usable)
                Picker(pTr("Unit"), selection: $entry.unit) { ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pTr($0.rawValue)).tag($0) } }
                Toggle(pTr("I checked the identity, units and meal constraints"), isOn: $entry.matched)
                DisclosureGroup(pTr("Delivery references (optional)"), isExpanded: $showingReferences) {
                    Text(pTr("Use the receipt number or a label for this part of a split delivery if you have one."))
                    TextField(pTr("Receipt or delivery reference"), text: receiptField($references.receipt))
                        .focused($focused, equals: .evidence)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField(pTr("Split delivery reference"), text: receiptField($references.segment))
                        .focused($focused, equals: .segment)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }.accessibilityIdentifier("arrival.references")
                DatePicker(pTr("Actual arrival"), selection: $occurred, in: ...model.stockReviewDate)
                Button(pTr("Save observed arrival")) { save() }.buttonStyle(.borderedProminent)
                    .disabled(model.hasPendingSave || needsAnotherDelivery)
                if needsAnotherDelivery {
                    Text(pTr("An arrival is already saved for this item. Start another delivery to record more, or review the saved arrival below."))
                }
                if let formError { Text(formError).foregroundStyle(.red) }
                Button(pTr("Start another delivery for this item")) {
                    entry = ArrivalLineEntry(line: selectedLine)
                    references.startAnother()
                    occurred = model.stockReviewDate
                    formError = nil
                }.disabled(selectedLine == nil || model.hasPendingSave)
            }
            Section(pTr("Saved arrivals and usable corrections")) {
                ForEach(Array((model.journey?.pickup?.receipts ?? []).enumerated()), id: \.offset) { _, receipt in
                    VStack(alignment: .leading) {
                        Text(receipt.itemName).font(.headline)
                        Text("\(pTr("Received")): \(pQuantity(receipt.received)) · \(pTr(receipt.disposition.rawValue))")
                        DisclosureGroup(pTr("Saved delivery references")) {
                            LabeledContent(pTr("Receipt or delivery reference"), value: receipt.key.sourceEventID)
                            LabeledContent(pTr("Split delivery reference"), value: receipt.key.segmentID)
                        }
                        LabeledContent(pTr("Actual arrival")) {
                            Text(receipt.receivedAt, format: .dateTime.month().day().year().hour().minute())
                        }
                        if let observation = model.journey?.pickup?.usableObservations.last(where: { $0.receipt == receipt.key }) {
                            Text("\(pTr("Usable")): \(pQuantity(observation.usable))")
                            if receipt.receivedAt > model.stockReviewDate || observation.confirmedAt > model.stockReviewDate {
                                Text(pTr("Future-dated evidence is not counted as available food."))
                            }
                        } else { Text(pTr("Usable amount unverified")) }
                        NavigationLink(pTr("Correct usable amount")) {
                            PickupUsableCorrectionView(model: model, receipt: receipt).id(receipt.key)
                        }
                    }
                }
            }
            NavigationLink(pTr("Review protected portions and repair meals")) { PickupRepairView(model: model) }
        }
        .onChange(of: model.journey?.pickup?.orderID, initial: true) { _, orderID in
            guard orderID != entryOrderID else { return }
            entryOrderID = orderID
            references = ArrivalDeliveryReferences()
            showingReferences = false
            occurred = model.stockReviewDate
            formError = nil
            let remaining = model.journey?.unobservedRetailerLines(at: occurred) ?? []
            entry = ArrivalLineEntry(line: remaining.count == 1 ? remaining.first : nil)
        }
        .keyboardDoneAction(visible: focused != nil, title: pTr("Done"), identifier: "arrival.keyboardDone") { focused = nil }
        .navigationTitle(pTr("What came home"))
        .disabled(model.saving)
    }

    private func quantityField(_ title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title)
                .font(.subheadline)
                .accessibilityHidden(true)
            TextField(title, text: text, prompt: Text(verbatim: ""))
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numbersAndPunctuation)
                .accessibilityLabel(Text(verbatim: title))
                .focused($focused, equals: field)
        }
        .accessibilityElement(children: .contain)
    }

    private var needsAnotherDelivery: Bool {
        guard let pickup = model.journey?.pickup, let line = selectedLine else { return false }
        return !references.canRecord(references.key(orderID: pickup.orderID, line: line), in: pickup)
    }

    private func receiptField(_ field: Binding<String>) -> Binding<String> {
        Binding(get: { field.wrappedValue }, set: { value in
            guard value != field.wrappedValue else { return }
            if let line = selectedLine, let pickup = model.journey?.pickup,
               pickup.receipts.contains(where: { $0.key == references.key(orderID: pickup.orderID, line: line) }) {
                entry = ArrivalLineEntry(line: line)
                formError = nil
            } else {
                entry.observationID = UUID()
            }
            field.wrappedValue = value
        })
    }

    private func save() {
        do {
            guard let line = selectedLine, let pickup = model.journey?.pickup, pickup.orderID == entryOrderID,
                  let received = try ComparisonModel.quantity(entry.received, entry.unit),
                  !entry.item.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
            let key = references.key(orderID: pickup.orderID, line: line)
            guard references.canRecord(key, in: pickup) else { return }
            let fragment = ReceiptFragment(key: key, itemName: entry.item, received: received, disposition: entry.disposition, receivedAt: occurred)
            let observed = try ComparisonModel.quantity(entry.usable, entry.unit).map {
                UsableObservation(id: entry.observationID, receipt: key, usable: $0, confirmedAt: occurred,
                                  confirmedMatchToOrderLine: entry.matched)
            }
            Task {
                guard model.journey?.pickup?.orderID == pickup.orderID else { return }
                if await model.receive(fragment, usable: observed) { formError = nil }
            }
        } catch { formError = pTr("Choose an order line and enter the amount received. For no fill, enter zero.") }
    }
}
struct PickupOfferView: View {
    @ObservedObject var model: PickupModel
    @State private var editor: OfferEditorSelection?
    private struct OfferEditorSelection: Identifiable {
        let id = UUID()
        let journey: PickupJourney
        let original: PickupOffer?
    }
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            if let journey = model.journey {
                Section(pTr("Store offer")) {
                    Button(pTr("New store offer")) {
                        editor = OfferEditorSelection(journey: journey, original: nil)
                    }.accessibilityIdentifier("pickup.offer.new").frame(minHeight: 44)
                        .disabled(model.saving || model.hasPendingSave || (journey.pickup?.orderLines.isEmpty ?? true))
                    Text(pTr("Open a saved offer to update its pending household preference or retailer response. A new offer creates a separate record."))
                }
                ForEach(journey.offers) { offer in
                    Section(offer.replacement) {
                        PickupOfferFacts(offer: offer, journey: journey)
                            .accessibilityIdentifier("pickup.offer.saved.\(offer.id.uuidString)")
                        Button(pTr("Review or edit saved offer")) {
                            editor = OfferEditorSelection(journey: journey, original: offer)
                        }.accessibilityIdentifier("pickup.offer.edit.\(offer.id.uuidString)")
                            .frame(minHeight: 44).disabled(model.saving || model.hasPendingSave)
                        if let workspaceID = model.sourceWorkspaceID {
                            ContextualReminderLink(request: .init(target: .offer(workspaceID: workspaceID, journeyID: journey.id, offerID: offer.id),
                                sourceRevision: journey.revision, sourceSavedAt: journey.savedAt))
                                .disabled(model.saving || model.hasPendingSave)
                        }
                        let copyCurrent = offer.evaluation == nil || (try? PickupOfferEvaluation.isCurrent(offer: offer, journey: journey)) == true
                        if copyCurrent {
                            Text(pickupOfferRetailerNote(offer)).textSelection(.enabled)
                        } else {
                            Text(pTr("Review the changed forecast before previewing or copying its retailer note."))
                        }
                        Button(pTr("Copy retailer note without changing decision")) { Task {
                            let note = pickupOfferRetailerNote(offer)
                            let attempt = PickupOfferAction(id: UUID(), offerID: offer.id, kind: .copyAttempted, occurredAt: Date())
                            guard await model.recordReviewedOfferAction(attempt, offer: offer, journeyID: journey.id),
                                  model.journey?.id == journey.id,
                                  model.journey?.offers.first(where: { $0.id == offer.id }) == offer,
                                  !model.saving, !model.hasPendingSave,
                                  offer.evaluation == nil || (try? PickupOfferEvaluation.isCurrent(offer: offer, journey: model.journey ?? journey)) == true else { return }
                            UIPasteboard.general.string = note
                            let copied = PickupOfferAction(id: UUID(), offerID: offer.id, kind: .copied, occurredAt: Date())
                            await model.recordReviewedOfferAction(copied, offer: offer, journeyID: journey.id)
                        } }.accessibilityIdentifier("pickup.offer.copy.\(offer.id.uuidString)")
                            .frame(minHeight: 44).disabled(model.saving || model.hasPendingSave || !copyCurrent)
                    }
                }
            }
        }
        .navigationTitle(pTr("Review store offer"))
        .sheet(item: $editor) { selected in
            NavigationStack { PickupOfferEditorView(model: model, journey: selected.journey, original: selected.original) }
        }
        .onChange(of: model.selectedID) { _, _ in editor = nil }
    }
}
