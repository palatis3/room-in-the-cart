import SwiftUI
import CoreDomain

/// The shopper can correct only the usable head they actually opened, on this physical delivery.
struct PickupReceiptHead {
    let journeyID: UUID
    let receipt: ReceiptFragment
    let previous: UsableObservation?

    init(journey: PickupJourney, receipt: ReceiptFragment) {
        journeyID = journey.id
        self.receipt = receipt
        previous = journey.pickup?.usableObservations.last { $0.receipt == receipt.key }
    }

    func matches(_ journey: PickupJourney?) -> Bool {
        guard let journey, journey.id == journeyID, let pickup = journey.pickup,
              pickup.receipts.contains(receipt) else { return false }
        return pickup.usableObservations.last { $0.receipt == receipt.key } == previous
    }
}

struct PickupUsableCorrectionReview {
    let head: PickupReceiptHead
    let revision: Int64
    let observation: UsableObservation
    let before: StockAllocationResult
    let after: StockAllocationResult
    let meals: [PickupStockMealEffect]

    init(head: PickupReceiptHead, quantity: Quantity, matched: Bool, in journey: PickupJourney, at instant: Date) throws {
        guard head.matches(journey), head.receipt.receivedAt <= instant, var pickup = journey.pickup else {
            throw PickupError.staleObservation
        }
        self.head = head
        self.revision = journey.revision
        observation = UsableObservation(id: UUID(), receipt: head.receipt.key, usable: quantity, confirmedAt: instant,
            supersedesID: head.previous?.id, confirmedMatchToOrderLine: matched)
        try pickup.confirmUsable(observation)
        var corrected = journey
        corrected.pickup = pickup
        let before = try journey.carryoverAllocation(at: instant)
        let after = try corrected.carryoverAllocation(at: instant)
        self.before = before
        self.after = after
        meals = corrected.physicalStockNeeds.filter { $0.foodID == head.receipt.key.orderLineID }.map { need in
            PickupStockMealEffect(need: need, before: before.demands.first { $0.id == need.id },
                                  after: after.demands.first { $0.id == need.id })
        }
    }

    func applied(in journey: PickupJourney?) -> Bool {
        journey?.id == head.journeyID && journey?.pickup?.usableObservations.last { $0.receipt == head.receipt.key } == observation
    }

    func apply(to journey: inout PickupJourney, at instant: Date) throws {
        guard head.matches(journey), journey.revision == revision, instant >= observation.confirmedAt,
              try journey.carryoverAllocation(at: instant) == before, var pickup = journey.pickup else {
            throw PickupError.staleObservation
        }
        try pickup.confirmUsable(observation)
        var corrected = journey
        corrected.pickup = pickup
        guard try corrected.carryoverAllocation(at: instant) == after else { throw PickupError.staleObservation }
        journey = corrected
    }
}

extension PickupModel {
    @discardableResult func applyReceiptCorrection(_ review: PickupUsableCorrectionReview) async -> Bool {
        if review.applied(in: journey) { return true }
        guard let current = journey, !saving, !hasPendingSave else { return false }
        var corrected = current
        do {
            try review.apply(to: &corrected, at: stockReviewDate)
        } catch {
            self.error = pTr("The batch or meal commitments changed. Review the effects again before saving.")
            return false
        }
        return await change {
            guard $0.id == current.id, $0.revision == current.revision else { throw PickupError.staleObservation }
            $0 = corrected
        }
    }
}

struct PickupUsableCorrectionView: View {
    @ObservedObject var model: PickupModel
    let receipt: ReceiptFragment
    @State private var head: PickupReceiptHead?
    @State private var amount = ""
    @State private var matched = false
    @State private var review: PickupUsableCorrectionReview?
    @FocusState private var amountFocused: Bool
    @AccessibilityFocusState private var reviewFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            PickupSaveStatus(model: model) {
                if let review, review.applied(in: model.journey) { dismiss() }
            }
            if let head, model.journey?.id == head.journeyID {
                Section(receipt.itemName) {
                    Text("\(receipt.key.sourceEventID) / \(receipt.key.segmentID)")
                    Text("\(pTr("Received")): \(pQuantity(receipt.received))")
                    if let previous = head.previous {
                        Text("\(pTr("Usable")): \(pQuantity(previous.usable))")
                        Text(previous.confirmedAt, format: .dateTime.month().day().year().hour().minute())
                        if !previous.confirmedMatchToOrderLine { Text(pTr("identityMatchUnconfirmed")) }
                    } else { Text(pTr("Usable amount unverified")) }
                }
                if !head.matches(model.journey) {
                    Text(pTr("The saved usable amount changed. Reopen this delivery to review the current observation."))
                } else {
                    Section {
                        TextField(pTr("Correct confirmed usable amount"), text: $amount)
                            .keyboardType(.numbersAndPunctuation).focused($amountFocused)
                        Text(pTr(receipt.received.unit.rawValue))
                        Toggle(pTr("I checked the identity, units and meal constraints"), isOn: $matched)
                        Button(pTr("Preview corrected usable amount")) { preview(head) }
                            .disabled(amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.disabled(model.saving || model.hasPendingSave)
                    if let review {
                        Section {
                            Text(pTr("Review dependent meals")).font(.headline).accessibilityAddTraits(.isHeader)
                                .accessibilityFocused($reviewFocused)
                            Text("\(pTr("Confirmed usable amount")): \(pQuantity(review.observation.usable))")
                            if !review.observation.confirmedMatchToOrderLine { Text(pTr("identityMatchUnconfirmed")) }
                            if review.meals.isEmpty { Text(pTr("No reviewed meal depends on this batch.")) }
                            ForEach(review.meals) { effect in
                                PickupStockMealEffectRow(effect: effect)
                                    .accessibilityIdentifier("receiptCorrection.meal." + effect.id.uuidString)
                            }
                            if model.journey?.revision != review.revision {
                                Text(pTr("The batch or meal commitments changed. Review the effects again before saving."))
                            }
                            Button(pTr("Save correction and recheck meals")) {
                                Task { if await model.applyReceiptCorrection(review) { dismiss() } }
                            }.disabled(model.saving || model.hasPendingSave || model.journey?.revision != review.revision)
                        }
                    }
                }
            }
        }
        .navigationTitle(pTr("Usable food"))
        .onAppear {
            if head == nil, let journey = model.journey { head = PickupReceiptHead(journey: journey, receipt: receipt) }
        }
        .onChange(of: amount) { _, _ in review = nil }
        .onChange(of: matched) { _, _ in review = nil }
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: amountFocused, title: tr("Done")) { amountFocused = false }
    }

    private func preview(_ head: PickupReceiptHead) {
        do {
            guard !model.saving, !model.hasPendingSave, let journey = model.journey,
                  let quantity = try ComparisonModel.quantity(amount, receipt.received.unit) else { throw PickupError.invalidEvidence }
            review = try PickupUsableCorrectionReview(head: head, quantity: quantity, matched: matched, in: journey, at: model.stockReviewDate)
            model.error = nil
            amountFocused = false
            reviewFocused = true
        } catch {
            review = nil
            model.error = pTr("Usable amount must be valid and no larger than the received amount.")
        }
    }
}
