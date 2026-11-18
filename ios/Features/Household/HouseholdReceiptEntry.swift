import CoreDomain
import Foundation
import HouseholdClient
import SwiftUI

extension ReceiptImportDraft {
    func householdReceipt(for page: HouseholdPantryPage, deliveries: [HouseholdPantryPage.Lot],
                          at now: Date = Date(), zone: TimeZone = .current) throws -> HouseholdReceiptAcquisition {
        guard workspaceID == page.householdId, dateConfirmed, purchaseDate <= now else { throw PantryReceiptError.stale }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX"); format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = zone; format.dateFormat = "yyyy-MM-dd"
        func quantity(_ text: String, unit: UnitOfMeasure) throws -> SharedMealQuantity {
            guard let q = try ComparisonModel.quantity(text, unit) else { throw PantryReceiptError.invalid }
            return .init(amount: .init(numerator: Int(q.amount.numerator), denominator: Int(q.amount.denominator)),
                         unit: q.unit.rawValue, originalLiteral: q.originalLiteral)
        }
        let rows = try selectedLines.map { row -> HouseholdReceiptLine in
            let delivery: HouseholdReceiptLine.Delivery?
            let location: HouseholdPantryLocation
            switch row.treatment {
            case .skip: throw PantryReceiptError.invalid
            case .link(let id):
                guard let lot = deliveries.first(where: { $0.id == id && $0.origin == .delivery }),
                      let original = lot.purchaseObservation else { throw PantryReceiptError.stale }
                delivery = .init(lotId: id, observationId: original.observationId)
                location = lot.location
            case .add:
                delivery = nil
                switch row.location { case .cupboard: location = .pantry; case .fridge: location = .fridge; case .freezer: location = .freezer }
            }
            let paid = row.paid.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(ordinal: row.ordinal, original: row.original, foodName: row.name.trimmingCharacters(in: .whitespacesAndNewlines),
                         received: try quantity(row.received, unit: row.unit), usable: try quantity(row.usable, unit: row.unit),
                         paidUSDMinor: paid.isEmpty ? nil : Int(try Money(decimal: paid).minorUnits),
                         location: location, delivery: delivery, printed: row.documentLine.map {
                .init(page: $0.page, line: $0.line, method: $0.method.rawValue, stage: $0.stage.rawValue)
            })
        }
        let ref = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let receipt = HouseholdReceiptAcquisition(receiptId: receiptID, imageId: imageDigest.map {
            ReceiptAcquisition.identity(["image", $0.base64EncodedString()])
        }, merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines), purchaseDay: format.string(from: purchaseDate),
        zone: zone.identifier, reference: ref.isEmpty ? nil : ref, lines: rows)
        try receipt.validate()
        return receipt
    }
}

struct HouseholdReceiptLineFacts: View {
    let row: HouseholdReceiptLine
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.foodName).font(.headline)
            Text(row.original).font(.caption)
            Text(pantryFormat("Received %@", deliveryQuantityText(row.received)))
            Text(pantryFormat("Usable %@", deliveryQuantityText(row.usable)))
            Text(pantryLocation(row.location.rawValue))
            if row.delivery != nil { Text(pantryText("Link evidence to the delivered batch. Its pantry count stays the same.")) }
            if let paid = row.paidUSDMinor {
                Text(pantryFormat("Paid line total %@", (Decimal(paid) / 100).formatted(.currency(code: "USD"))))
            } else { Text(pantryText("Paid price unknown")) }
        }
    }
}

struct HouseholdReceiptFacts: View {
    let receipt: HouseholdReceiptAcquisition
    var body: some View {
        Text(receipt.merchant).font(.headline)
        Text(receipt.purchaseDay)
        if let reference = receipt.reference { Text(reference) }
        ForEach(receipt.lines, id: \.ordinal) { HouseholdReceiptLineFacts(row: $0) }
    }
}

struct HouseholdReceiptEntry: View {
    @ObservedObject var model: HouseholdPantryModel
    let page: HouseholdPantryPage
    let household: String
    @State private var sourceID = UUID()
    @State private var scan = false
    @State private var file = false
    @State private var draft: ReceiptImportDraft?
    @State private var reviewed: HouseholdReceiptAcquisition?
    @State private var invalid = false
    @FocusState private var field: String?
    @Environment(\.dismiss) private var dismiss

    private var target: CaptureTarget {
        .init(workspaceID: page.householdId, containerID: sourceID, objectID: sourceID,
              revision: Int64(page.pantryRevision), kind: .receiptEvidence)
    }
    private var deliveries: [HouseholdPantryPage.Lot] {
        model.lots.filter { $0.origin == .delivery && $0.purchaseObservation != nil && $0.receiptEvidence == nil }
    }
    private func accept(_ source: SourceMediaRecord) {
        guard model.permitsReceiptReview(page), source.target == target else { return }
        do { draft = try ReceiptImportDraft(source: source); invalid = false } catch { invalid = true }
    }
    var body: some View {
        Form {
            Section(householdPantryText("Shared pantry destination")) {
                Text(household).font(.headline)
                Text(householdPantryText("Adults with pantry access can see the store, date, any receipt reference you enter and the selected food lines, including original wording, quantities, storage location and any prices you enter. The original file stays on this device."))
            }
            if let reviewed {
                Section(pantryText("Confirm receipt lines")) {
                    HouseholdReceiptFacts(receipt: reviewed)
                    Text(pantryText("Saving receipt evidence does not post a payment."))
                    HouseholdPantryConfirmButton(model: model, page: page, change: .receipt(reviewed),
                        title: householdPantryText("Confirm receipt for this household"), identifier: "householdReceipt.confirm")
                    Button(pantryText("Edit receipt lines")) { self.reviewed = nil }
                }
            } else if let displayed = draft {
                let value = Binding(get: { draft ?? displayed }, set: { if draft?.draftID == displayed.draftID { draft = $0 } })
                Section(pantryText("Receipt details")) {
                    TextField(pantryText("Store or branch"), text: value.merchant).focused($field, equals: "merchant")
                    TextField(pantryText("Confirmed transaction reference, if printed"), text: value.reference).focused($field, equals: "reference")
                    DatePicker(pantryText("Purchase date"), selection: value.purchaseDate, in: ...Date(), displayedComponents: .date)
                    Toggle(pantryText("I checked the purchase date."), isOn: value.dateConfirmed)
                }
                Text(pantryText("Select only food you received. Leave fees, discounts, nonfood and unreadable lines skipped."))
                ForEach(displayed.lines) { row in
                    PantryReceiptLineEditor(line: captureDraftBinding(row, in: value.lines), lots: [], purchases: [], aliases: [],
                        receiptLanguage: displayed.language, matchesCurrent: { model.permitsReceiptReview(page) },
                        verifyAlias: { _ in false }, householdDeliveries: deliveries, field: $field)
                }
                Button(pantryText("Review selected food")) {
                    do { reviewed = try value.wrappedValue.householdReceipt(for: page, deliveries: deliveries); invalid = false }
                    catch { invalid = true }
                }.disabled(!displayed.dateConfirmed || displayed.selectedLines.isEmpty)
                .accessibilityIdentifier("householdReceipt.review")
            } else {
                Button(pantryText("Read a receipt file")) { file = true }
                Button(pantryText("Scan or type receipt lines")) { scan = true }.accessibilityIdentifier("householdReceipt.scan")
            }
            if invalid { Text(pantryText("Check the store, purchase date, food, received amount, usable amount and optional paid total.")) }
        }
        .disabled(!model.permitsReceiptReview(page))
        .privacySensitive()
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: field != nil, title: pantryText("Done"), identifier: "householdReceipt.keyboardDone") { field = nil }
        .navigationTitle(householdPantryText("Add receipt to household pantry"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Close")) { dismiss() }.disabled(model.busy) } }
        .sheet(isPresented: $scan) {
            NavigationStack { ScanReviewView(kind: .receipt, target: target, authorize: { model.permitsReceiptReview(page) }) { result in
                if case .evidence(let source) = result { accept(source) }
            } }
        }
        .sheet(isPresented: $file) {
            NavigationStack { PantryReceiptDocuments(target: target, authorize: { model.permitsReceiptReview(page) }) { source, _ in accept(source) } }
        }
    }
}
