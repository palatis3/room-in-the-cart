import XCTest
import HouseholdClient
@testable import RoomInTheCart

final class HouseholdRequestMealContextTests: XCTestCase {
    @MainActor private func setup(includeMealFacts: Bool = true) async throws -> (HouseholdInboxModel, S24FixtureServer, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("outbox.json")
        let server = S24FixtureServer(cerealScenario: true, includeMealFacts: includeMealFacts)
        addTeardownBlock { server.close() }
        let model = try await s24FixtureModel(server: server, outboxURL: url)
        model.select(try XCTUnwrap(model.requests.first))
        model.choice = .add; model.price = "3.49"
        await model.review()
        return (model, server, url)
    }

    @MainActor func testCerealPreviewIncludesTwoNamedProtectedLunchesFromItsCurrentShopRevision() async throws {
        let (model, server, url) = try await setup()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let context = try XCTUnwrap(model.requestMealContext)
        XCTAssertEqual(context.protectedMeals.map(\.meal.title), ["Sam’s wrap lunch", "Mia’s wrap lunch"])
        XCTAssertEqual(context.protectedMeals.map(\.meal.kind), ["lunch", "lunch"])
        XCTAssertEqual(context.protectedMeals.map(\.meal.day), ["2026-11-04", "2026-11-05"])
        XCTAssertEqual(context.protectedMeals.map(\.meal.portions), [1, 1])
        XCTAssertEqual(context.meals, model.shop?.meals)
        XCTAssertEqual(model.preview?.before.totalMinor, 3720)
        XCTAssertEqual(model.preview?.after.totalMinor, 4069)
        XCTAssertEqual(model.preview?.after.overCapMinor, 269)
        XCTAssertEqual(model.preview?.changeMinor, 349)
        XCTAssertFalse(model.canApply, "Meal commitments never accept an overage for the shopper")
        XCTAssertEqual(server.commandCount, 0)
        let previewBody = try XCTUnwrap(server.previewBody)
        let bytes = try JSONSerialization.data(withJSONObject: previewBody)
        let text = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertFalse(text.contains("meals")); XCTAssertFalse(text.contains("wrap lunch"))
    }

    @MainActor func testUnchangedDecisionBindingCommitsKeepPreviewAndExplicitAcknowledgments() async throws {
        let (model, server, url) = try await setup()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let reviewed = try XCTUnwrap(model.preview)
        model.acceptOverage = true
        let draft = (choice: model.choice, item: model.lineItem, packs: model.packs, price: model.price,
                     feeEligible: model.feeEligible, linkedLineID: model.linkedLineID, promote: model.promote)
        // SwiftUI can write these unchanged values when editing ends or a
        // disabled Form updates. They must not erase the reviewed facts.
        model.price = draft.price; model.lineItem = draft.item; model.choice = draft.choice
        model.packs = draft.packs; model.feeEligible = draft.feeEligible
        model.linkedLineID = draft.linkedLineID; model.promote = draft.promote
        XCTAssertEqual(model.preview, reviewed)
        XCTAssertNotNil(model.requestMealContext)
        XCTAssertTrue(model.acceptOverage); XCTAssertTrue(model.canApply)
        XCTAssertEqual(server.previewCount, 1); XCTAssertEqual(server.commandCount, 0)
        model.price = "3.50"
        XCTAssertNil(model.preview); XCTAssertNil(model.requestMealContext)
        XCTAssertFalse(model.acceptOverage); XCTAssertFalse(model.canApply)
    }

    @MainActor func testUnchangedPriceCommitDuringReviewKeepsResponseButChangedPriceDiscardsIt() async throws {
        let (model, server, url) = try await setup()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let held = HeldS24PreviewResponse()
        defer { server.intercept = nil; held.release() }
        for changed in [false, true] {
            let arrived = expectation(description: "S24 preview waiting for the field commit")
            server.intercept = { task in
                guard task.request.url?.path.hasSuffix("/previews") == true else { return false }
                held.hold(task); arrived.fulfill(); return true
            }
            let review = Task { await model.review() }
            await fulfillment(of: [arrived], timeout: 3)
            XCTAssertTrue(model.busy)
            let committedPrice = changed ? "3.50" : model.price
            model.price = committedPrice
            server.intercept = nil; held.release()
            await review.value
            if changed {
                XCTAssertNil(model.preview); XCTAssertNil(model.requestMealContext)
                XCTAssertFalse(model.canApply)
            } else {
                XCTAssertEqual(model.preview?.after.totalMinor, 4069)
                XCTAssertNotNil(model.requestMealContext)
                XCTAssertFalse(model.canApply, "The overage still requires explicit acceptance")
            }
        }
        XCTAssertEqual(server.previewCount, 3); XCTAssertEqual(server.commandCount, 0)
    }

    @MainActor func testHeldReviewKeepsOriginatingServerAfterAnotherFixtureIsCreated() async throws {
        let (first, firstServer, firstURL) = try await setup()
        defer { try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent()) }
        let held = HeldS24PreviewResponse()
        defer { firstServer.intercept = nil; held.release() }
        let arrived = expectation(description: "Original cereal preview is held")
        firstServer.intercept = { task in
            guard task.request.url?.path.hasSuffix("/previews") == true else { return false }
            held.hold(task); arrived.fulfill(); return true
        }
        let firstReview = Task { await first.review() }
        await fulfillment(of: [arrived], timeout: 3)
        XCTAssertTrue(first.busy); XCTAssertEqual(firstServer.previewCount, 1)

        let secondServer = S24FixtureServer()
        addTeardownBlock { secondServer.close() }
        let secondURL = firstURL.deletingLastPathComponent().appendingPathComponent("wraps-outbox.json")
        let second = try await s24FixtureModel(server: secondServer, outboxURL: secondURL)
        second.select(try XCTUnwrap(second.requests.first)); second.choice = .add; second.price = "1.25"
        await second.review()
        XCTAssertEqual(second.preview?.after.totalMinor, 125)
        secondServer.intercept = { _ in XCTFail("A held cereal response must not use the newer fixture's interceptor"); return false }
        firstServer.intercept = { _ in XCTFail("Resuming a bound response must not reread a replaced interceptor"); return false }
        held.release()
        await firstReview.value
        XCTAssertFalse(first.busy)
        XCTAssertEqual(first.preview?.before.totalMinor, 3720)
        XCTAssertEqual(first.preview?.after.totalMinor, 4069)
        XCTAssertEqual(first.preview?.after.overCapMinor, 269)
        XCTAssertNotNil(first.requestMealContext)
        XCTAssertEqual(firstServer.previewCount, 2); XCTAssertEqual(secondServer.previewCount, 1)
        XCTAssertEqual(firstServer.commandCount, 0); XCTAssertEqual(secondServer.commandCount, 0)
    }

    @MainActor func testMissingMealsStayUnknownWhileKnownEmptyMealsStayEmpty() async throws {
        let (model, _, url) = try await setup(includeMealFacts: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let unknown = try XCTUnwrap(model.requestMealContext)
        XCTAssertNil(unknown.meals)
        XCTAssertTrue(unknown.protectedMeals.isEmpty)
        var shopJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(model.shop))) as? [String: Any])
        shopJSON["meals"] = []
        let emptyShop = try JSONDecoder().decode(ShopperShop.self, from: JSONSerialization.data(withJSONObject: shopJSON))
        let empty = try XCTUnwrap(HouseholdRequestMealContext(authorized: true, shopID: model.shopID, shop: emptyShop, request: model.selected, preview: model.preview))
        XCTAssertEqual(empty.meals, [])
        XCTAssertNotEqual(unknown, empty, "Unavailable meal facts must never imply that no commitments exist")
    }

    @MainActor func testContextRejectsAnotherShopOrRevisionAndRefreshRequiresFreshReview() async throws {
        let (model, server, url) = try await setup()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let oldShop = try XCTUnwrap(model.shop), oldPreview = try XCTUnwrap(model.preview), request = try XCTUnwrap(model.selected)
        XCTAssertNil(HouseholdRequestMealContext(authorized: false, shopID: model.shopID, shop: oldShop, request: request, preview: oldPreview))
        XCTAssertNil(HouseholdRequestMealContext(authorized: true, shopID: UUID().uuidString, shop: oldShop, request: request, preview: oldPreview))
        server.advanceSource(); await model.load()
        XCTAssertNil(model.requestMealContext)
        XCTAssertNil(HouseholdRequestMealContext(authorized: true, shopID: model.shopID, shop: model.shop, request: model.selected, preview: oldPreview))
        await model.review()
        XCTAssertNotNil(model.requestMealContext)
        XCTAssertEqual(server.commandCount, 0)
    }

    @MainActor func testCancelAndServiceScopeLossClearMealContextWithoutWrites() async throws {
        let (model, server, url) = try await setup()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let originalMeals = model.shop?.meals
        model.cancelReview()
        XCTAssertNil(model.requestMealContext); XCTAssertNil(model.preview); XCTAssertNil(model.selected)
        XCTAssertEqual(model.shop?.meals, originalMeals)
        XCTAssertEqual(model.requests.first?.status, "pending")
        XCTAssertEqual(server.commandCount, 0); XCTAssertEqual(server.lineCount, 0)
        let outbox = OperationOutbox(url: url)
        let operations = try await outbox.operations()
        XCTAssertTrue(operations.isEmpty)
        model.select(try XCTUnwrap(model.requests.first)); model.choice = .add; model.price = "3.49"
        await model.review(); XCTAssertNotNil(model.requestMealContext)
        server.revokeAccess(); await model.load()
        XCTAssertFalse(model.authorized); XCTAssertNil(model.shop); XCTAssertNil(model.preview)
        XCTAssertNil(model.requestMealContext); XCTAssertTrue(model.requests.isEmpty)
        XCTAssertEqual(server.commandCount, 0); XCTAssertEqual(server.lineCount, 0)
    }
}

private final class HeldS24PreviewResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var task: S24FixtureProtocol?
    func hold(_ value: S24FixtureProtocol) { lock.lock(); task = value; lock.unlock() }
    func release() {
        lock.lock(); let value = task; task = nil; lock.unlock()
        value?.finishResponse()
    }
}
