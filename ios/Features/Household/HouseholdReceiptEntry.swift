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
            case .skip, .keptSome, .eaten, .missing, .chargeOrReturn: throw PantryReceiptError.invalid
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
        let segmented = firstSectionDigest != nil
        guard !segmented || !ref.isEmpty else { throw PantryReceiptError.invalid }
        // Extending a previously saved single photo still resolves its existing source.
        // The confirmed transaction identifies a retaken first photo as the same purchase.
        let imageID = (firstSectionDigest ?? imageDigest).map { ReceiptAcquisition.identity(["image", $0.base64EncodedString()]) }
        // A reference may be supplied later for this same file. Keep the coordinates stable.
        let scope = ["household-receipt-layout-v1", workspaceID.uuidString, (imageID ?? receiptID).uuidString]
        let layout: UUID?
        if lines.allSatisfy({ $0.documentLine != nil }) {
            // Older saved files lack an extraction proof. Do not infer their layout from a partial selection.
            layout = documentLayoutID.map { ReceiptAcquisition.identity(scope + ["file", $0.uuidString]) }
        } else {
            layout = ReceiptAcquisition.identity(scope + ["reviewed"] + lines.map(\.original))
        }
        let receipt = HouseholdReceiptAcquisition(receiptId: receiptID, imageId: imageID, merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines), purchaseDay: format.string(from: purchaseDate),
        zone: zone.identifier, reference: ref.isEmpty ? nil : ref, lines: rows, layoutId: layout, segmentedPhotos: segmented ? true : nil)
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
    var householdModel: HouseholdModel? = nil
    @State private var tripState = ReceiptTripReviewState()
    @State private var sourceID = UUID()
    @State private var scan = false
    @State private var file = false
    @State private var draft: ReceiptImportDraft?
    @State private var reviewed: HouseholdReceiptAcquisition?
    @State private var invalid = false
    @FocusState private var field: String?
    let closeEditor: () -> Void

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
        WorkingForm {
            Section(householdPantryText("Shared pantry destination")) {
                Text(household).font(.headline)
                Text(householdPantryText("Adults with pantry access can see the store, date, any receipt reference you enter and the selected food lines, including original wording, quantities, storage location and any prices you enter. The original file stays on this device."))
            }
            if let reviewed {
                Section(pantryText("Confirm receipt lines")) {
                    Text(householdPantryText("To help prevent counting a receipt twice, the app also sends a code based on all the lines it read, in order, including skipped lines."))
                    HouseholdReceiptFacts(receipt: reviewed)
                    Text(pantryText("Saving receipt evidence does not post a payment."))
                    HouseholdPantryConfirmButton(model: model, page: page, change: .receipt(reviewed),
                        title: householdPantryText("Confirm receipt for this household"), identifier: "householdReceipt.confirm", closeEditor: closeEditor)
                    Button(pantryText("Edit receipt lines")) { self.reviewed = nil }
                }
            } else if let displayed = draft {
                let value = Binding(get: { draft ?? displayed }, set: { if draft?.draftID == displayed.draftID { draft = $0 } })
                Section(pantryText("Receipt details")) {
                    TextField(pantryText("Store or branch"), text: value.merchant).focused($field, equals: "merchant")
                    if displayed.firstSectionDigest != nil {
                        Text(captureText("Enter the printed transaction reference for this multi-photo receipt. Use the same reference when retaking or extending it. If none is printed, add genuinely missing food separately in the household pantry."))
                    }
                    let referenceTitle = displayed.firstSectionDigest == nil
                        ? putawayText("Transaction reference (optional)")
                        : captureText("Printed transaction reference (required)")
                    WorkingField(referenceTitle) {
                        TextField(referenceTitle, text: value.reference, prompt: Text(""))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .receiptInputChrome()
                            .focused($field, equals: "reference")
                            .accessibilityIdentifier("householdReceipt.transactionReference")
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { field = "reference" })
                    ReceiptPurchaseDateFields(draft: value)
                }
                if let householdModel {
                    HouseholdReceiptTripLink(household: householdModel, pantry: model, page: page, draft: displayed, state: $tripState)
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
                }.disabled(!displayed.dateConfirmed || displayed.selectedLines.isEmpty ||
                    (displayed.firstSectionDigest != nil && displayed.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .accessibilityIdentifier("householdReceipt.review")
            } else {
                ReceiptPhotoShortcuts(target: target, authorize: { model.permitsReceiptReview(page) }, reviewed: accept)
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
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Close"), action: closeEditor).disabled(model.busy) } }
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

/// Household pantry access alone does not confer access to the shopper's confirmed order.
private struct HouseholdReceiptTripLink: View {
    @ObservedObject var household: HouseholdModel
    @ObservedObject var pantry: HouseholdPantryModel
    let page: HouseholdPantryPage
    let draft: ReceiptImportDraft
    @Binding var state: ReceiptTripReviewState

    private var shopID: UUID? {
        guard pantry.permitsReceiptReview(page), household.householdPantryScope == pantry.scope,
              let actor = household.projection, actor.enrolled, actor.grantId == nil, actor.role == "shopper",
              actor.capabilities.contains("shopper_commands"), actor.capabilities.contains("confirmed_order"),
              let raw = actor.shopId else { return nil }
        return UUID(uuidString: raw)
    }
    var body: some View {
        if let shopID, let service = household.service {
            NavigationLink(captureText("Compare receipt with a planned shop")) {
                HouseholdReceiptTripRead(shopID: shopID, name: household.projection?.household.label ?? "",
                    service: service, authorize: { self.shopID == shopID }, draft: draft, state: $state)
            }.accessibilityIdentifier("householdReceipt.tripDifferences")
        }
    }
}

private struct HouseholdReceiptTripRead: View {
    let shopID: UUID
    let name: String
    let service: HouseholdService
    let authorize: @MainActor () -> Bool
    let draft: ReceiptImportDraft
    @Binding var state: ReceiptTripReviewState
    @State private var trip: ReceiptTripPlan?
    @State private var failed = false
    @State private var attempt = UUID()
    @Environment(\.scenePhase) private var scene

    var body: some View {
        Group {
            if authorize(), let trip {
                ReceiptTripDifferenceReview(trips: [trip], purchases: [], draft: draft, state: $state)
            } else if failed {
                Text(captureText("The confirmed order is unavailable. You can still review the receipt on its own."))
                Button(captureText("Try again")) { attempt = UUID() }
            } else { ProgressView() }
        }
        .task(id: attempt) {
            guard authorize(), scene == .active else { return }
            do {
                let order = try await service.confirmedOrder(shopID: shopID)
                guard !Task.isCancelled, scene == .active, authorize(), order.shopId == shopID else { return }
                let current = try ReceiptTripPlan(shared: order, household: name)
                if state.trip != current { state = .init(trip: current) }
                trip = current
            } catch { if !Task.isCancelled { trip = nil; failed = true } }
        }
        .onChange(of: scene) { _, phase in
            trip = nil; failed = false
            if phase == .active { attempt = UUID() }
        }
    }
}
