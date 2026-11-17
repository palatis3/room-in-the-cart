import XCTest
@testable import CoreDomain

final class PickupTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_700_000_000)

    func testSixUsableWrapsProtectTwoLunchesBeforeDinners() throws {
        let line = try orderLine()
        var ledger = try PickupLedger(orderID: UUID(), orderLines: [line])
        let receipt = try fragment(line, amount: 8)
        try ledger.receive(receipt)
        let originalUsable = try observation(receipt, amount: 6)
        try ledger.confirmUsable(originalUsable)
        let tacos = try need(line, name: "Tacos", amount: 6, priority: .required)
        let quesadillas = try need(line, name: "Quesadillas", amount: 4, priority: .required)
        let lunches = try need(line, name: "Protected lunches", amount: 2, priority: .protected)
        let result = try ledger.allocate([tacos, quesadillas, lunches])
        XCTAssertEqual(result.demands.map(\.id), [tacos.id, quesadillas.id, lunches.id])
        XCTAssertEqual(result.demands.map(\.allocated), [try Rational(4), .zero, try Rational(2)])
        XCTAssertEqual(result.demands.map(\.shortfall), [try Rational(2), try Rational(4), .zero])
        XCTAssertEqual(result.lines.first?.confirmedUsable, try Rational(6))
        XCTAssertEqual(result.lines.first?.remainingUnallocated, .zero)
        XCTAssertFalse(result.confirmedCoverageComplete)
        XCTAssertEqual(ledger.receipts.first?.received.amount, try Rational(8))
        XCTAssertEqual(ledger.usableObservations.first?.usable.amount, try Rational(6))

        // S08: correcting six usable wraps to seven increases tacos' share,
        // while retaining the received fact and protecting the same two lunches.
        let correction = try observation(receipt, amount: 7, supersedes: originalUsable.id)
        XCTAssertTrue(try ledger.confirmUsable(correction))
        XCTAssertFalse(try ledger.confirmUsable(correction), "A replay cannot create extra usable food")
        let corrected = try ledger.allocate([tacos, quesadillas, lunches])
        XCTAssertEqual(corrected.demands.map(\.id), [tacos.id, quesadillas.id, lunches.id])
        XCTAssertEqual(corrected.demands.map(\.allocated), [try Rational(5), .zero, try Rational(2)])
        XCTAssertEqual(corrected.demands.map(\.shortfall), [try Rational(1), try Rational(4), .zero])
        XCTAssertEqual(corrected.lines.first?.confirmedUsable, try Rational(7))
        XCTAssertEqual(corrected.lines.first?.remainingUnallocated, .zero)
        XCTAssertFalse(corrected.confirmedCoverageComplete)
        XCTAssertEqual(ledger.receipts, [receipt])
        XCTAssertEqual(ledger.receipts.first?.received.amount, try Rational(8))
        XCTAssertEqual(ledger.usableObservations, [originalUsable, correction])
        let restored = try JSONDecoder().decode(PickupLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored, ledger)
        XCTAssertEqual(try restored.allocate([tacos, quesadillas, lunches]), corrected)
    }

    func testReceiptRetryAddsNothingButSecondGenuineSegmentCounts() throws {
        let line = try orderLine()
        var ledger = try PickupLedger(orderID: UUID(), orderLines: [line])
        let first = try fragment(line, amount: 4, source: "delivery-event", segment: "first")
        XCTAssertTrue(try ledger.receive(first))
        XCTAssertFalse(try ledger.receive(first))
        try ledger.confirmUsable(observation(first, amount: 4))
        let second = try fragment(line, amount: 4, source: "delivery-event", segment: "second")
        XCTAssertTrue(try ledger.receive(second))
        try ledger.confirmUsable(observation(second, amount: 4))
        let result = try ledger.allocate([need(line, name: "Dinner", amount: 8, priority: .required)])
        XCTAssertTrue(result.confirmedCoverageComplete)
        XCTAssertEqual(result.allocations.count, 2)
        XCTAssertEqual(ledger.receipts.count, 2)
        let before = ledger
        let changedBody = ReceiptFragment(key: first.key, itemName: first.itemName, received: try quantity(6), disposition: .partial, receivedAt: time)
        XCTAssertThrowsError(try ledger.receive(changedBody))
        XCTAssertEqual(ledger, before)
        XCTAssertEqual(try JSONDecoder().decode(PickupLedger.self, from: JSONEncoder().encode(ledger)), ledger)
    }

    func testUnknownUsableAmountDoesNotBecomeReceivedAmountOrZeroFact() throws {
        let line = try orderLine()
        let untouched = try PickupOrderLine(id: UUID(), branchID: "north", name: "Milk", ordered: quantity(1))
        var ledger = try PickupLedger(orderID: UUID(), orderLines: [line, untouched])
        try ledger.receive(fragment(line, amount: 8))
        let result = try ledger.allocate([need(line, name: "Dinner", amount: 6, priority: .required)])
        XCTAssertEqual(result.demands.first?.allocated, .zero)
        XCTAssertEqual(result.demands.first?.shortfall, try Rational(6))
        XCTAssertTrue(try XCTUnwrap(result.demands.first).issues.contains(.usableUnverified))
        XCTAssertTrue(try XCTUnwrap(result.lines.last).issues.contains(.receiptUnverified))
        XCTAssertTrue(ledger.usableObservations.isEmpty)
    }

    func testWrongItemNeedsReviewedMatchBeforeAllocation() throws {
        let line = try orderLine()
        var ledger = try PickupLedger(orderID: UUID(), orderLines: [line])
        let wrong = try fragment(line, amount: 8, disposition: .wrongItem)
        try ledger.receive(wrong)
        let initial = try observation(wrong, amount: 6, matched: false)
        try ledger.confirmUsable(initial)
        let needs = [try need(line, name: "Dinner", amount: 6, priority: .required)]
        XCTAssertEqual(try ledger.allocate(needs).demands.first?.allocated, .zero)
        XCTAssertTrue(try XCTUnwrap(ledger.allocate(needs).demands.first).issues.contains(.identityMatchUnconfirmed))
        try ledger.confirmUsable(observation(wrong, amount: 6, supersedes: initial.id, matched: true))
        XCTAssertTrue(try ledger.allocate(needs).confirmedCoverageComplete)
    }

    func testUsableCorrectionPreservesReceivedFactAndRevisitsProtectedAllocations() throws {
        let line = try orderLine()
        var ledger = try PickupLedger(orderID: UUID(), orderLines: [line])
        let receipt = try fragment(line, amount: 8)
        try ledger.receive(receipt)
        let original = try observation(receipt, amount: 8)
        try ledger.confirmUsable(original)
        let needs = [try need(line, name: "Dinner", amount: 6, priority: .required),
                     try need(line, name: "Lunches", amount: 2, priority: .protected)]
        XCTAssertTrue(try ledger.allocate(needs).confirmedCoverageComplete)
        let before = ledger
        XCTAssertThrowsError(try ledger.confirmUsable(observation(receipt, amount: 6)))
        XCTAssertEqual(ledger, before)
        let correction = try observation(receipt, amount: 6, supersedes: original.id)
        XCTAssertTrue(try ledger.confirmUsable(correction))
        XCTAssertFalse(try ledger.confirmUsable(correction))
        let updated = try ledger.allocate(needs)
        XCTAssertEqual(updated.demands.first?.shortfall, try Rational(2))
        XCTAssertEqual(updated.demands.last?.shortfall, .zero)
        XCTAssertEqual(ledger.receipts, [receipt])
        XCTAssertEqual(ledger.usableObservations.count, 2)
    }

    func testImpossibleYieldAndWrongBranchFailWithoutMutation() throws {
        let line = PickupOrderLine(id: UUID(), branchID: "north", name: "Food", ordered: try quantity(20, unit: .ounce))
        var ledger = try PickupLedger(orderID: UUID(), orderLines: [line])
        let key = ReceiptKey(sourceEventID: "delivery", orderLineID: line.id, branchID: "north", segmentID: "one")
        let receipt = ReceiptFragment(key: key, itemName: "Food", received: try quantity(20, unit: .ounce), disposition: .received, receivedAt: time)
        try ledger.receive(receipt)
        let before = ledger
        let impossible = UsableObservation(id: UUID(), receipt: key, usable: try quantity(4176, unit: .gram), confirmedAt: time, confirmedMatchToOrderLine: true)
        XCTAssertThrowsError(try ledger.confirmUsable(impossible))
        XCTAssertEqual(ledger, before)
        let possible = UsableObservation(id: UUID(), receipt: key, usable: try quantity(566, unit: .gram), confirmedAt: time, confirmedMatchToOrderLine: true)
        XCTAssertTrue(try ledger.confirmUsable(possible))
        let wrongKey = ReceiptKey(sourceEventID: "other", orderLineID: line.id, branchID: "south", segmentID: "one")
        XCTAssertThrowsError(try ledger.receive(.init(key: wrongKey, itemName: "Food", received: quantity(1), disposition: .received, receivedAt: time)))
    }

    func testNoFillIsAnExplicitZeroAndUnknownConversionBlocksCoverage() throws {
        let line = try orderLine()
        var ledger = try PickupLedger(orderID: UUID(), orderLines: [line])
        try ledger.receive(fragment(line, amount: 0, disposition: .noFill))
        let empty = try ledger.allocate([need(line, name: "Dinner", amount: 6, priority: .required)])
        XCTAssertEqual(empty.demands.first?.shortfall, try Rational(6))
        XCTAssertTrue(try XCTUnwrap(empty.lines.first).issues.isEmpty)
        let receipt = try fragment(line, amount: 8, source: "later")
        try ledger.receive(receipt)
        try ledger.confirmUsable(observation(receipt, amount: 8))
        let weightNeed = AllocationNeed(id: UUID(), orderLineID: line.id, name: "Unknown count-to-weight basis", amount: try quantity(200, unit: .gram), priority: .protected)
        let result = try ledger.allocate([weightNeed, need(line, name: "Dinner", amount: 4, priority: .required)])
        XCTAssertNil(result.demands[0].shortfall)
        XCTAssertNil(result.demands[1].allocated)
        XCTAssertFalse(result.confirmedCoverageComplete)
        XCTAssertEqual(result.lines.first?.remainingUnallocated, try Rational(8))
    }

    func testAllocationConservationAcrossManyPartialReceipts() throws {
        for seed in 0..<100 {
            let line = try orderLine()
            var ledger = try PickupLedger(orderID: UUID(), orderLines: [line])
            let countA = Int64(seed % 9), countB = Int64((seed * 7) % 11)
            for (index, amount) in [countA, countB].enumerated() {
                let receipt = try fragment(line, amount: amount, source: "event-\(index)")
                try ledger.receive(receipt)
                try ledger.confirmUsable(observation(receipt, amount: amount))
            }
            let lunchAmount = Int64(seed % 4), dinnerAmount = Int64(seed % 13)
            let result = try ledger.allocate([need(line, name: "Dinner", amount: dinnerAmount, priority: .required),
                                              need(line, name: "Lunch", amount: lunchAmount, priority: .protected)])
            let used = try result.allocations.reduce(Rational.zero) { try $0.adding($1.amount) }
            let leftover = try XCTUnwrap(result.lines.first?.remainingUnallocated)
            XCTAssertEqual(try used.adding(leftover), try Rational(countA + countB))
            XCTAssertEqual(result.demands[1].allocated, try Rational(min(countA + countB, lunchAmount)))
            for coverage in result.demands {
                XCTAssertEqual(try XCTUnwrap(coverage.allocated).adding(XCTUnwrap(coverage.shortfall)), coverage.needed)
            }
        }
    }

    func testPendingCreditDoesNotReducePostedCashUntilPosted() throws {
        var ledger = SettlementLedger()
        let charge = entry("charge", .postedCharge, 3720)
        try ledger.append(charge)
        let pending = entry("pending", .pendingCredit, 240, credit: "refund-1", charge: "charge")
        try ledger.append(pending)
        XCTAssertEqual(try ledger.summary().paidSoFar.minorUnits, 3720)
        XCTAssertEqual(try ledger.summary().pendingCredits.minorUnits, 240)
        let posted = entry("posted", .postedCredit, 240, credit: "refund-1", charge: "charge")
        XCTAssertTrue(try ledger.append(posted))
        XCTAssertFalse(try ledger.append(posted))
        XCTAssertEqual(try ledger.summary().paidSoFar.minorUnits, 3480)
        XCTAssertEqual(try ledger.summary().pendingCredits, .zero)
        XCTAssertEqual(ledger.entries.count, 3)
        let before = ledger
        XCTAssertThrowsError(try ledger.append(entry("second-posting", .postedCredit, 240, credit: "refund-1", charge: "charge")))
        XCTAssertEqual(ledger, before)
    }

    func testIncludedCreditExplainsNetChargeWithoutSecondDeduction() throws {
        var ledger = SettlementLedger()
        try ledger.append(entry("net-charge", .postedCharge, 3480))
        try ledger.append(entry("included", .includedCredit, 240, credit: "refund-1", charge: "net-charge"))
        let result = try ledger.summary()
        XCTAssertEqual(result.paidSoFar.minorUnits, 3480)
        XCTAssertEqual(result.includedCredits.minorUnits, 240)
        XCTAssertEqual(result.pendingCredits, .zero)
        XCTAssertThrowsError(try ledger.append(entry("refund-again", .postedCredit, 240, credit: "refund-1", charge: "net-charge")))
        XCTAssertEqual(try JSONDecoder().decode(SettlementLedger.self, from: JSONEncoder().encode(ledger)), ledger)
    }

    func testIndependentEqualPurchasesSurviveWhileSameEvidenceDeduplicates() throws {
        var ledger = SettlementLedger()
        let first = entry("receipt-1", .postedCharge, 500)
        XCTAssertTrue(try ledger.append(first))
        XCTAssertFalse(try ledger.append(entry("receipt-1", .postedCharge, 500)))
        XCTAssertTrue(try ledger.append(entry("receipt-2", .postedTopUp, 500)))
        XCTAssertEqual(try ledger.summary().paidSoFar.minorUnits, 1000)
        XCTAssertEqual(ledger.entries.count, 2)
        XCTAssertThrowsError(try ledger.append(entry("receipt-1", .postedCharge, 501)))
        XCTAssertThrowsError(try ledger.append(entry("credit", .postedCredit, 10, credit: "refund", charge: "unknown-charge")))
    }

    func testReviewedReceiptAndCreditIdentifiersSurvivePasteAndLegacySpacing() throws {
        var saved = SettlementLedger()
        try saved.append(entry(" receipt-1 ", .postedCharge, 500))
        try saved.append(entry("pending", .pendingCredit, 100, credit: " refund ", charge: " receipt-1 "))
        var ledger = try JSONDecoder().decode(SettlementLedger.self, from: JSONEncoder().encode(saved))

        XCTAssertFalse(try ledger.appendReviewed(entry("receipt-1", .postedCharge, 500)))
        XCTAssertThrowsError(try ledger.appendReviewed(entry("receipt-1", .postedCharge, 501)))
        XCTAssertTrue(try ledger.appendReviewed(entry(" posted ", .postedCredit, 100, credit: "refund", charge: " receipt-1 ")))
        XCTAssertEqual(ledger.entries.last?.evidenceKey, "posted")
        XCTAssertEqual(ledger.entries.last?.creditID, " refund ")
        XCTAssertEqual(try ledger.summary().pendingCredits, .zero)
        XCTAssertEqual(try ledger.summary().paidSoFar.minorUnits, 400)
        XCTAssertThrowsError(try ledger.appendReviewed(entry("posted-again", .postedCredit, 100, credit: "refund ", charge: " receipt-1 ")))
        XCTAssertThrowsError(try ledger.appendReviewed(entry("credit-2", .pendingCredit, 50, credit: "   ", charge: " receipt-1 ")))
        XCTAssertTrue(try ledger.appendReviewed(entry(" receipt 2 ", .postedCharge, 500)))
        XCTAssertFalse(try ledger.appendReviewed(entry("receipt 2", .postedCharge, 500)))
        XCTAssertEqual(try ledger.summary().paidSoFar.minorUnits, 900)
        XCTAssertEqual(Array(ledger.entries.prefix(2)), saved.entries)

        var ambiguous = saved
        try ambiguous.append(entry("receipt-1 ", .postedCharge, 700))
        XCTAssertThrowsError(try ambiguous.appendReviewed(entry("receipt-1", .postedCharge, 500)))
        XCTAssertEqual(try ambiguous.summary().paidSoFar.minorUnits, 1200)
    }

    func testPaymentHoldAndItsReleaseNeverEnterPaidCash() throws {
        var ledger = SettlementLedger()
        try ledger.append(entry("hold", .paymentHold, 8600))
        XCTAssertEqual(try ledger.summary().paidSoFar, .zero)
        XCTAssertEqual(try ledger.summary().paymentHolds.minorUnits, 8600)
        try ledger.append(entry("charge", .postedCharge, 7800))
        let release = SettlementEntry(id: UUID(), evidenceKey: "released", kind: .holdRelease,
                                      amount: Money(minorUnits: 8600), occurredAt: time, holdEvidenceKey: "hold")
        try ledger.append(release)
        XCTAssertEqual(try ledger.summary().paidSoFar.minorUnits, 7800)
        XCTAssertEqual(try ledger.summary().paymentHolds, .zero)
        XCTAssertFalse(try ledger.append(release))
    }

    func testSettlementOverflowIsAtomic() throws {
        var ledger = SettlementLedger()
        try ledger.append(entry("large", .postedCharge, Int64.max))
        let before = ledger
        XCTAssertThrowsError(try ledger.append(entry("one", .postedCharge, 1)))
        XCTAssertEqual(ledger, before)
    }

    func testDeadlineChangesToAwaitPickupAtExactInstantWithoutInventingFill() throws {
        let deadline = try RetailerDeadline(cutoff: time, timeZoneID: "America/New_York")
        XCTAssertEqual(try deadline.status(at: time.addingTimeInterval(-0.001)), .open)
        XCTAssertEqual(try deadline.status(at: time), .awaitPickup)
        XCTAssertEqual(try deadline.status(at: time.addingTimeInterval(86_400)), .awaitPickup)
        XCTAssertThrowsError(try RetailerDeadline(cutoff: time, timeZoneID: "Invalid/Zone"))
        XCTAssertThrowsError(try deadline.status(at: Date(timeIntervalSince1970: .infinity)))
        XCTAssertEqual(try JSONDecoder().decode(RetailerDeadline.self, from: JSONEncoder().encode(deadline)), deadline)
    }

    func testCorruptPickupArchiveCannotBypassPhysicalSupplyCeiling() throws {
        let line = try orderLine()
        var ledger = try PickupLedger(orderID: UUID(), orderLines: [line])
        let receipt = try fragment(line, amount: 8)
        try ledger.receive(receipt)
        let impossible = try observation(receipt, amount: 100)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        object["usableObservations"] = [try JSONSerialization.jsonObject(with: JSONEncoder().encode(impossible))]
        XCTAssertThrowsError(try JSONDecoder().decode(PickupLedger.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testCorruptSettlementArchiveCannotDoubleCountIncludedCredit() throws {
        var ledger = SettlementLedger()
        try ledger.append(entry("charge", .postedCharge, 3480))
        try ledger.append(entry("included", .includedCredit, 240, credit: "refund", charge: "charge"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as? [String: Any])
        var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
        entries.append(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry("posted", .postedCredit, 240, credit: "refund", charge: "charge"))) as? [String: Any]))
        object["entries"] = entries
        XCTAssertThrowsError(try JSONDecoder().decode(SettlementLedger.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testUrgentRepairUsesConfirmedStockWithoutOrderOrInventedDate() throws {
        let food = UUID()
        let stock = ConfirmedStockLot(id: UUID(), foodID: food, name: "Wraps at home", usable: try quantity(6),
                                      confirmedAt: time, source: .pantry)
        let tacos = StockNeed(id: UUID(), foodID: food, name: "Tacos", amount: try quantity(6), priority: .required)
        let quesadillas = StockNeed(id: UUID(), foodID: food, name: "Quesadillas", amount: try quantity(4), priority: .required)
        let lunches = StockNeed(id: UUID(), foodID: food, name: "Lunches", amount: try quantity(2), priority: .protected)
        let result = try ConfirmedStockAllocator.allocate(lots: [stock], needs: [tacos, quesadillas, lunches])
        XCTAssertEqual(result.demands.map(\.allocated), [try Rational(4), .zero, try Rational(2)])
        XCTAssertEqual(result.demands.map(\.shortfall), [try Rational(2), try Rational(4), .zero])
        XCTAssertEqual(result.remainingLots.first?.remainingUnallocated, .zero)
        XCTAssertFalse(result.confirmedCoverageComplete)
        XCTAssertTrue(result.allocations.allSatisfy { $0.lotID == stock.id })
    }

    func testIndependentStockRequiresReviewedIdentityAndDeduplicatedLot() throws {
        let food = UUID()
        let stock = ConfirmedStockLot(id: UUID(), foodID: UUID(), name: "Wraps", usable: try quantity(8), confirmedAt: time)
        let need = StockNeed(id: UUID(), foodID: food, name: "Wraps", amount: try quantity(6), priority: .required)
        let result = try ConfirmedStockAllocator.allocate(lots: [stock], needs: [need])
        XCTAssertEqual(result.demands.first?.allocated, .zero, "Matching labels do not prove food identity")
        XCTAssertEqual(result.demands.first?.shortfall, try Rational(6))
        XCTAssertEqual(result.remainingLots.first?.remainingUnallocated, try Rational(8))
        XCTAssertThrowsError(try ConfirmedStockAllocator.allocate(lots: [stock, stock], needs: [need]))
    }

    func testIndependentStockUnknownConversionAndProtectedNeedRemainUnresolved() throws {
        let food = UUID()
        let stock = ConfirmedStockLot(id: UUID(), foodID: food, name: "Rice", usable: try quantity(200, unit: .gram), confirmedAt: time, source: .freezer)
        let cupNeed = StockNeed(id: UUID(), foodID: food, name: "Protected rice", amount: try quantity(1, unit: .cup), priority: .protected)
        let grams = StockNeed(id: UUID(), foodID: food, name: "Rice dinner", amount: try quantity(100, unit: .gram), priority: .required)
        let result = try ConfirmedStockAllocator.allocate(lots: [stock], needs: [cupNeed, grams])
        XCTAssertTrue(result.demands.allSatisfy { $0.shortfall == nil && $0.issues.contains(.conversionUnknown) })
        XCTAssertTrue(result.allocations.isEmpty)
        XCTAssertFalse(result.confirmedCoverageComplete)
        XCTAssertEqual(result.remainingLots.first?.remainingUnallocated, try Rational(200))
    }

    private func quantity(_ amount: Int64, unit: UnitOfMeasure = .count) throws -> Quantity {
        Quantity(amount: try Rational(amount), unit: unit, originalLiteral: "\(amount)")
    }
    private func orderLine() throws -> PickupOrderLine {
        PickupOrderLine(id: UUID(), branchID: "north", name: "Wraps", ordered: try quantity(12))
    }
    private func fragment(_ line: PickupOrderLine, amount: Int64, source: String = "delivery", segment: String = "one",
                          disposition: ReceiptDisposition = .received) throws -> ReceiptFragment {
        ReceiptFragment(key: ReceiptKey(sourceEventID: source, orderLineID: line.id, branchID: line.branchID, segmentID: segment),
                        itemName: line.name, received: try quantity(amount), disposition: disposition, receivedAt: time)
    }
    private func observation(_ receipt: ReceiptFragment, amount: Int64, supersedes: UUID? = nil, matched: Bool = true) throws -> UsableObservation {
        UsableObservation(id: UUID(), receipt: receipt.key, usable: try quantity(amount), confirmedAt: time,
                          supersedesID: supersedes, confirmedMatchToOrderLine: matched)
    }
    private func need(_ line: PickupOrderLine, name: String, amount: Int64, priority: AllocationPriority) throws -> AllocationNeed {
        AllocationNeed(id: UUID(), orderLineID: line.id, name: name, amount: try quantity(amount), priority: priority)
    }
    private func entry(_ key: String, _ kind: SettlementKind, _ amount: Int64, credit: String? = nil, charge: String? = nil) -> SettlementEntry {
        SettlementEntry(id: UUID(), evidenceKey: key, kind: kind, amount: Money(minorUnits: amount), occurredAt: time,
                        creditID: credit, chargeEvidenceKey: charge)
    }
}
