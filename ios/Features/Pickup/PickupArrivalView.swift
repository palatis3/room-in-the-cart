import SwiftUI
import UIKit
import CoreDomain

struct PickupArrivalView: View {
    @ObservedObject var model: PickupModel
    @State private var selectedLine: UUID?
    @State private var disposition: ReceiptDisposition = .received
    @State private var item = ""
    @State private var received = ""
    @State private var usable = ""
    @State private var unit: UnitOfMeasure = .count
    @State private var matched = false
    @State private var eventID = UUID().uuidString
    @State private var segment = ""
    @State private var occurred = Date()
    @State private var formError: String?
    @State private var observationID = UUID()
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            Section(pTr("Review discrepancies")) {
                Text(pTr("Unchecked lines remain unverified. Received food and confirmed usable food are separate."))
                Picker(pTr("Original order line"), selection: $selectedLine) {
                    Text(pTr("Choose a line")).tag(UUID?.none)
                    ForEach(model.journey?.pickup?.orderLines ?? []) { line in Text(line.name).tag(Optional(line.id)) }
                }
                Picker(pTr("What happened"), selection: $disposition) {
                    Text(pTr("Received")).tag(ReceiptDisposition.received)
                    Text(pTr("No fill")).tag(ReceiptDisposition.noFill)
                    Text(pTr("Partial fill")).tag(ReceiptDisposition.partial)
                    Text(pTr("Wrong item")).tag(ReceiptDisposition.wrongItem)
                    Text(pTr("Late arrival")).tag(ReceiptDisposition.late)
                }
                TextField(pTr("Actual item name"), text: $item)
                TextField(pTr("Physical amount received"), text: $received).keyboardType(.numbersAndPunctuation)
                TextField(pTr("Confirmed usable amount (optional)"), text: $usable).keyboardType(.numbersAndPunctuation)
                Picker(pTr("Unit"), selection: $unit) { ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pTr($0.rawValue)).tag($0) } }
                Toggle(pTr("I checked the identity, units and meal constraints"), isOn: $matched)
                TextField(pTr("Delivery or receipt evidence ID"), text: $eventID)
                TextField(pTr("Segment ID (distinct for each split delivery)"), text: $segment)
                DatePicker(pTr("Actual arrival"), selection: $occurred, in: ...model.stockReviewDate)
                Button(pTr("Save observed arrival")) { save() }.buttonStyle(.borderedProminent)
                if let formError { Text(formError).foregroundStyle(.red) }
                Button(pTr("Start another actual delivery segment")) {
                    eventID = UUID().uuidString; observationID = UUID(); segment = ""; received = ""; usable = ""; occurred = Date(); matched = false
                }
            }
            Section(pTr("Saved arrivals and usable corrections")) {
                ForEach(Array((model.journey?.pickup?.receipts ?? []).enumerated()), id: \.offset) { _, receipt in
                    VStack(alignment: .leading) {
                        Text(receipt.itemName).font(.headline)
                        Text("\(pTr("Received")): \(pQuantity(receipt.received)) · \(pTr(receipt.disposition.rawValue))")
                        Text("\(receipt.key.sourceEventID) / \(receipt.key.segmentID)").font(.caption)
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
        }.navigationTitle(pTr("What came home"))
            .disabled(model.saving)
            .onChange(of: selectedLine) { _, id in
                if let line = model.journey?.pickup?.orderLines.first(where: { $0.id == id }) { item = line.name; unit = line.ordered.unit }
            }
    }
    private func save() {
        do {
            guard let line = model.journey?.pickup?.orderLines.first(where: { $0.id == selectedLine }),
                  let received = try ComparisonModel.quantity(received, unit), !item.isEmpty, !segment.isEmpty, !eventID.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
            let key = ReceiptKey(sourceEventID: eventID, orderLineID: line.id, branchID: line.branchID, segmentID: segment)
            let fragment = ReceiptFragment(key: key, itemName: item, received: received, disposition: disposition, receivedAt: occurred)
            let observed = try ComparisonModel.quantity(usable, unit).map { UsableObservation(id: observationID, receipt: key, usable: $0, confirmedAt: occurred, confirmedMatchToOrderLine: matched) }
            Task { if await model.receive(fragment, usable: observed) { formError = nil } }
        } catch { formError = pTr("Choose a line, name the delivery segment and enter valid quantities. No fill requires zero received.") }
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
