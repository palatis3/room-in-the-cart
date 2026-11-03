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
                TextField(pTr("Physical amount received"), text: $received).keyboardType(.decimalPad)
                TextField(pTr("Confirmed usable amount (optional)"), text: $usable).keyboardType(.decimalPad)
                Picker(pTr("Unit"), selection: $unit) { ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pTr($0.rawValue)).tag($0) } }
                Toggle(pTr("I checked the identity, units and meal constraints"), isOn: $matched)
                TextField(pTr("Delivery or receipt evidence ID"), text: $eventID)
                TextField(pTr("Segment ID (distinct for each split delivery)"), text: $segment)
                DatePicker(pTr("Actual arrival"), selection: $occurred)
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
                        if let observation = model.journey?.pickup?.usableObservations.last(where: { $0.receipt == receipt.key }) {
                            Text("\(pTr("Usable")): \(pQuantity(observation.usable))")
                        } else { Text(pTr("Usable amount unverified")) }
                        NavigationLink(pTr("Correct usable amount")) { PickupUsableCorrectionView(model: model, receipt: receipt) }
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
struct PickupUsableCorrectionView: View {
    @ObservedObject var model: PickupModel
    let receipt: ReceiptFragment
    @State private var amount = ""
    @State private var matched = false
    @State private var operationID = UUID()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            Text(receipt.itemName)
            Text("\(pTr("Received")): \(pQuantity(receipt.received))")
            TextField(pTr("Correct confirmed usable amount"), text: $amount).keyboardType(.decimalPad)
            Toggle(pTr("I checked the identity, units and meal constraints"), isOn: $matched)
            Button(pTr("Save correction and recheck meals")) { Task {
                do {
                    guard let quantity = try ComparisonModel.quantity(amount, receipt.received.unit) else { return }
                    let previous = model.journey?.pickup?.usableObservations.last { $0.receipt == receipt.key }
                    let observation = UsableObservation(id: operationID, receipt: receipt.key, usable: quantity, confirmedAt: Date(), supersedesID: previous?.id, confirmedMatchToOrderLine: matched)
                    if await model.confirmUsable(observation) { dismiss() }
                } catch { model.error = pTr("Usable amount must be valid and no larger than the received amount.") }
            } }
        }.navigationTitle(pTr("Usable food"))
    }
}

struct PickupOfferView: View {
    @ObservedObject var model: PickupModel
    @State private var lineID: UUID?
    @State private var replacement = ""
    @State private var required = ""
    @State private var remaining = ""
    @State private var price = ""
    @State private var ceiling = ""
    @State private var fallback = ""
    @State private var deadline = Date()
    @State private var zone = TimeZone.current.identifier
    @State private var preference = ""
    @State private var response = ""
    @State private var operationID = UUID()
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            Section(pTr("Store offer")) {
                Picker(pTr("Original line"), selection: $lineID) {
                    Text(pTr("Choose a line")).tag(UUID?.none)
                    ForEach(model.journey?.pickup?.orderLines ?? []) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField(pTr("Replacement and offered pack"), text: $replacement)
                TextField(pTr("Required usable amount in original units"), text: $required).keyboardType(.decimalPad)
                TextField(pTr("Original amount still expected"), text: $remaining).keyboardType(.decimalPad)
                PickupEvidenceField(title: "Offered price", amount: $price)
                PickupEvidenceField(title: "Reviewed offer-specific maximum price", amount: $ceiling)
                Text(pTr("A line ceiling does not establish that the whole checkout fits. Review combined charges separately."))
                DatePicker(pTr("Retailer response cutoff"), selection: $deadline)
                TextField(pTr("Time zone"), text: $zone)
                TextField(pTr("Fallback if short"), text: $fallback)
                TextField(pTr("Household preference (not retailer acceptance)"), text: $preference)
                TextField(pTr("Retailer response (leave blank if pending)"), text: $response)
                Button(pTr("Save offer for review")) { save() }
            }
            ForEach(model.journey?.offers ?? []) { offer in
                Section(offer.replacement) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(pTr((try? offer.deadline.status(at: context.date)) == .awaitPickup ? "Await pickup · fill still unknown" : "Decision pending before cutoff"))
                    }
                    Text("\(offer.deadline.cutoff.formatted()) · \(offer.deadline.timeZoneID)")
                    Text("\(pTr("Household preference")): \(offer.householdPreference)")
                    Text("\(pTr("Retailer response")): \(offer.retailerResponse.isEmpty ? pTr("Pending") : offer.retailerResponse)")
                    Text(retailerNote(offer)).textSelection(.enabled)
                    Button(pTr("Copy retailer note without changing decision")) { Task {
                        guard await model.change({ $0.offerActions.append(PickupOfferAction(id: UUID(), offerID: offer.id, kind: .copyAttempted, occurredAt: Date())) }) else { return }
                        UIPasteboard.general.string = retailerNote(offer)
                        await model.change { $0.offerActions.append(PickupOfferAction(id: UUID(), offerID: offer.id, kind: .copied, occurredAt: Date())) }
                    } }
                }
            }
        }.navigationTitle(pTr("Review store offer"))
    }
    private func retailerNote(_ offer: PickupOffer) -> String {
        "\(offer.replacement)\n\(pTr("Required usable")): \(pQuantity(offer.required))\n\(pTr("Maximum price")): \(offer.ceiling.map(pMoney) ?? pTr("Unresolved"))\n\(pTr("Cutoff")): \(offer.deadline.cutoff.formatted()) · \(offer.deadline.timeZoneID)\n\(pTr("If short")): \(offer.fallback)"
    }
    private func save() {
        do {
            guard let line = model.journey?.pickup?.orderLines.first(where: { $0.id == lineID }),
                  let needed = try ComparisonModel.quantity(required, line.ordered.unit), let left = try ComparisonModel.quantity(remaining, line.ordered.unit), !replacement.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
            let offer = PickupOffer(id: operationID, lineID: line.id, replacement: replacement, required: needed, remainingOriginal: left, price: try pickupEvidence(price), ceiling: try ComparisonModel.money(ceiling), deadline: try RetailerDeadline(cutoff: deadline, timeZoneID: zone), fallback: fallback, householdPreference: preference, retailerResponse: response)
            Task { await model.change { value in if let index = value.offers.firstIndex(where: { $0.id == offer.id }) { value.offers[index] = offer } else { value.offers.append(offer) } } }
        } catch { model.error = pTr("Check the offer amounts, original line and time zone.") }
    }
}
