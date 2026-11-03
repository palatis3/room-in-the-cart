import XCTest
@testable import CoreDomain

final class StapleRecallTests: XCTestCase {
    private let lastMonth = Date(timeIntervalSince1970: 1_800_000_000)
    private func seed() throws -> (LedgerWorkspace, UUID, UUID) {
        var previous = ShoppingLedger(title:"Past market trip", basis:.init(branch:"North market"))
        let line = try previous.addManualLine(name:"Rice",quantity:.init(amount:.one,unit:.cup,originalLiteral:"one cup"), at:lastMonth)
        try previous.approveStaple(lineID:line,purpose:"School lunches",at:lastMonth)
        try previous.setChecked(lineID:line,checked:true,at:lastMonth)
        let target = ShoppingLedger(title:"Current pickup",basis:.init(branch:"North market"))
        return (LedgerWorkspace(shops:[previous,target], selectedShopID:target.id),line,target.id)
    }

    func testRecallCopiesOnlyReviewedNeedAndRetainsOldCheckAcrossSaveAndReplay() throws {
        var (workspace, line, target) = try seed()
        let original = workspace.shops[0]
        let review = try XCTUnwrap(workspace.priorStaples(for:target).first)
        XCTAssertEqual(review.approval.purpose,"School lunches"); XCTAssertEqual(review.approval.branch,"North market")
        XCTAssertEqual(review.line.checkedAt,lastMonth); XCTAssertEqual(review.line.id,line)
        XCTAssertTrue(workspace.shops[1].lines.isEmpty)
        XCTAssertThrowsError(try workspace.applyStaple(review, choice: .needed, quantity: Quantity(amount: .zero, unit: .cup, originalLiteral: "0"), at: lastMonth))
        let two = Quantity(amount:try Rational(2),unit:.cup,originalLiteral:"2")
        let now = lastMonth.addingTimeInterval(31*86400)
        try workspace.applyStaple(review,choice:.needed,quantity:two,at:now)
        let saved = try JSONEncoder().encode(workspace)
        workspace = try JSONDecoder().decode(LedgerWorkspace.self,from:saved)
        try workspace.validate()
        try workspace.applyStaple(review,choice:.needed,quantity:two,at:now)
        XCTAssertThrowsError(try workspace.applyStaple(review,choice:.needed,quantity:nil,at:now))
        XCTAssertEqual(workspace.shops[0],original)
        XCTAssertEqual(workspace.shops[1].lines.count,1)
        let newLine = try XCTUnwrap(workspace.shops[1].lines.first)
        XCTAssertNotEqual(newLine.id,line); XCTAssertFalse(newLine.isChecked)
        XCTAssertEqual(try workspace.shops[1].quantity(forLineID:newLine.id)?.amount,two.amount)
        XCTAssertNil(workspace.shops[1].quoteReference); XCTAssertTrue(workspace.packSelections.isEmpty)
        XCTAssertTrue(workspace.priorStaples(for:target).isEmpty)
    }

    func testExistingCheckedOrHandledItemIsNeverReopenedAndHandledChoiceCreatesNoPurchase() throws {
        var (workspace, _, target) = try seed()
        let existing = try workspace.shops[1].addManualLine(name:" rice ",quantity:nil)
        try workspace.shops[1].handle(lineID:existing,by:"Another shopper")
        let review = try XCTUnwrap(workspace.priorStaples(for:target).first)
        let before = workspace
        XCTAssertThrowsError(try workspace.applyStaple(review,choice:.needed,quantity:nil,at:lastMonth))
        XCTAssertEqual(workspace,before)
        try workspace.applyStaple(review,choice:.alreadyHandled,quantity:nil,at:lastMonth)
        XCTAssertEqual(workspace.shops[1].lines,before.shops[1].lines)
        XCTAssertTrue(workspace.priorStaples(for:target).isEmpty)
        XCTAssertThrowsError(try workspace.applyStaple(review,choice:.skip,quantity:nil,at:lastMonth))
    }

    func testChangedOrForgottenApprovalInvalidatesOpenReviewAndStoreIsRequired() throws {
        var (workspace, line, target) = try seed()
        let old = try XCTUnwrap(workspace.priorStaples(for:target).first)
        try workspace.shops[0].approveStaple(lineID:line,purpose:"Dinner",at:lastMonth)
        XCTAssertThrowsError(try workspace.applyStaple(old,choice:.skip,quantity:nil,at:lastMonth))
        try workspace.shops[0].approveStaple(lineID:line,purpose:nil)
        XCTAssertTrue(workspace.priorStaples(for:target).isEmpty)
        var unknown = ShoppingLedger(title:"No store")
        let item = try unknown.addManualLine(name:"Beans",quantity:nil)
        XCTAssertThrowsError(try unknown.approveStaple(lineID:item,purpose:"Tacos"))
    }
}
