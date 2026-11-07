import XCTest
import CoreDomain
@testable import RoomInTheCart

@MainActor final class OneChangeTests: XCTestCase {
    private var database: URL!
    override func setUp() {
        super.setUp()
        database = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("ledger.sqlite")
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: database.deletingLastPathComponent())
        super.tearDown()
    }
    private func observations() -> OneChangeDraft {
        var draft = OneChangeDraft()
        draft.change = "Defer the coffee, keep salsa for dinner"
        draft.branch = "North Market – West"
        draft.source = "Two checkout screens from the retailer app"
        draft.observed = Date(timeIntervalSince1970: 1_800_000_000)
        draft.slot = draft.observed.addingTimeInterval(7_200)
        draft.before = "40.90"
        draft.after = "36.30"
        draft.cap = "38"
        draft.beforeIncludesCharges = true
        draft.afterIncludesCharges = true
        draft.samePickup = true
        return draft
    }

    func testExplicitReviewAndSaveCreatesOneDraftWithItsActualAfterPriceAndNoInventedItems() async throws {
        let ledger = LedgerModel(databaseURL: database)
        await ledger.open()
        let draft = observations()
        let review = try draft.review(in: ledger)
        XCTAssertNil(ledger.shop)
        XCTAssertEqual(ledger.revision, 0)
        XCTAssertEqual(review.comparison.before.cap, .over(minimumCheckout: .init(minorUnits: 4090), minimumOverage: .init(minorUnits: 290)))
        XCTAssertEqual(review.comparison.after.cap, .within(maximumCheckout: .init(minorUnits: 3630), minimumHeadroom: .init(minorUnits: 170)))
        XCTAssertEqual(review.comparison.change, Money(minorUnits: -460))
        let saved = await review.save(in: ledger)
        XCTAssertTrue(saved)
        let repeated = await review.save(in: ledger)
        XCTAssertFalse(repeated)
        let rebound = LedgerModel(databaseURL: database)
        await rebound.open()
        let shop = try XCTUnwrap(rebound.shop)
        XCTAssertEqual(rebound.workspace.shops.count, 1)
        XCTAssertEqual(rebound.revision, 1)
        XCTAssertEqual(shop.id, review.id)
        XCTAssertEqual(shop.title, draft.change)
        XCTAssertEqual(shop.basis.branch, draft.branch)
        XCTAssertEqual(shop.basis.slot, draft.slot)
        XCTAssertEqual(shop.basis.cap, .init(minorUnits: 3800))
        XCTAssertEqual(shop.basis.retailerPreview?.total, .init(minorUnits: 3630))
        XCTAssertEqual(shop.basis.retailerPreview?.source, draft.source)
        XCTAssertEqual(shop.basis.retailerPreview?.capturedAt, draft.observed)
        XCTAssertTrue(shop.lines.isEmpty)
    }

    func testIncompleteRetailerPriceAndOriginalComparisonSurviveRestartAndBudgetEdits() async throws {
        let ledger = LedgerModel(databaseURL: database)
        await ledger.open()
        var draft = observations()
        draft.before = ""
        draft.afterIncludesCharges = false
        let review = try draft.review(in: ledger)
        let saved = await review.save(in: ledger)
        XCTAssertTrue(saved)
        var newBasis = review.shop.basis
        newBasis.cap = .init(minorUnits: 4600)
        newBasis.retailerPreview = nil
        let changed = await ledger.editShop(key: "update-cap", shopID: review.id) { shop in
            try shop.updateBasis(newBasis)
        }
        XCTAssertTrue(changed)
        let reopened = LedgerModel(databaseURL: database)
        await reopened.open()
        let shop = try XCTUnwrap(reopened.shop)
        let frozen = try XCTUnwrap(shop.initialCheckoutChange)
        XCTAssertEqual(frozen.basis.cap, .init(minorUnits: 3800))
        XCTAssertEqual(shop.basis.cap, .init(minorUnits: 4600))
        XCTAssertNil(frozen.before.amount)
        XCTAssertEqual(frozen.after.amount, .init(minorUnits: 3630))
        XCTAssertFalse(frozen.after.includesAllCharges)
        XCTAssertNil(frozen.basis.retailerPreview?.total)
        XCTAssertEqual(try frozen.comparison(for: shop.id), review.comparison)
        XCTAssertNil(review.comparison.change)

        // Previous ledger documents omit the newly optional property entirely.
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: reopened.exportPayload()) as? [String: Any])
        var workspace = try XCTUnwrap(document["workspace"] as? [String: Any])
        var shops = try XCTUnwrap(workspace["shops"] as? [[String: Any]])
        shops[0].removeValue(forKey: "initialCheckoutChange")
        workspace["shops"] = shops
        document["workspace"] = workspace
        let legacy = try LedgerModel.validatePayload(JSONSerialization.data(withJSONObject: document))
        XCTAssertNil(legacy.shops.first?.initialCheckoutChange)
        XCTAssertEqual(legacy.shops.first?.basis, shop.basis)

        let deletion = try await reopened.reviewWholeLedgerDeletion()
        _ = try await reopened.eraseWholeLedger(deletion)
        try await reopened.finishWholeLedgerDeletion()
        let erased = LedgerModel(databaseURL: database)
        await erased.open()
        XCTAssertTrue(erased.workspace.shops.isEmpty)
        let stale = await review.save(in: erased)
        XCTAssertFalse(stale)

    }

    func testOverageRequiresAgreementToTheActualReviewedAmount() async throws {
        let ledger = LedgerModel(databaseURL: database)
        await ledger.open()
        var draft = observations()
        draft.change = "Defer coffee and salsa; retailer delivery fee now applies"
        draft.after = "39.75"
        let first = try draft.review(in: ledger)
        XCTAssertEqual(first.comparison.after.cap, .over(minimumCheckout: .init(minorUnits: 3975), minimumOverage: .init(minorUnits: 175)))
        let noAgreement = await first.save(in: ledger)
        XCTAssertFalse(noAgreement)
        draft.after = "40.50"
        let changed = try draft.review(in: ledger)
        let oldAgreement = await changed.save(in: ledger, acceptedOverageFor: first.id)
        XCTAssertFalse(oldAgreement)
        XCTAssertNil(ledger.shop)
        let agreed = await changed.save(in: ledger, acceptedOverageFor: changed.id)
        XCTAssertTrue(agreed)
        XCTAssertEqual(ledger.shop?.basis.cap, .init(minorUnits: 3800))
    }

    func testUnknownEvidenceOrChangedPickupCannotBecomeAMatchedSaving() async throws {
        let ledger = LedgerModel(databaseURL: database)
        await ledger.open()
        var draft = observations()
        draft.samePickup = false
        XCTAssertThrowsError(try draft.review(in: ledger))
        draft.samePickup = true
        draft.after = "0"
        draft.afterIncludesCharges = false
        let partial = try draft.review(in: ledger)
        XCTAssertNil(partial.comparison.after.total.exact)
        XCTAssertEqual(partial.comparison.after.cap, .unresolved)
        XCTAssertNil(partial.comparison.change)
        XCTAssertEqual(partial.proof.after.amount, .zero)
        XCTAssertFalse(partial.proof.after.includesAllCharges)
        draft.afterIncludesCharges = true
        draft.cap = ""
        draft.slot = nil
        let zero = try draft.review(in: ledger)
        XCTAssertNil(zero.shop.basis.slot)
        XCTAssertEqual(zero.comparison.after.total.exact, .zero)
        XCTAssertEqual(zero.comparison.after.cap, .notProvided)
        draft.before = ""
        XCTAssertNil(try draft.review(in: ledger).comparison.before.total.exact)
        draft.before = "40.901"
        XCTAssertThrowsError(try draft.review(in: ledger))
        let other = await ledger.startShop(title: "Different pickup")
        XCTAssertTrue(other)
        let staleSave = await zero.save(in: ledger)
        XCTAssertFalse(staleSave)
        XCTAssertEqual(ledger.workspace.shops.map(\.title), ["Different pickup"])
    }
}
