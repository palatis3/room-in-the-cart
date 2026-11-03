import XCTest
import CoreDomain
@testable import RoomInTheCart

final class PickupStockReviewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let actor = UUID()
    private let utc = TimeZone(secondsFromGMT: 0)!
    private func quantity(_ n: Int64) -> Quantity { .init(amount: try! Rational(n), unit: .count, originalLiteral: String(n)) }
    @MainActor private func scope(_ model: PickupModel, actor: UUID? = nil, subject: String? = nil,
                                  household: String? = nil, member: String? = nil, role: String? = nil) throws -> PickupStockReviewScope {
        .init(workspaceID: try XCTUnwrap(model.sourceWorkspaceID), localActorID: actor ?? self.actor,
            accountSubject: subject, householdID: household, memberID: member, role: role)
    }
    private func text(_ value: PickupJourney, _ allocation: StockAllocationResult?, language: String = "en-US") -> String {
        PickupCookProjection.text(journey: value, allocation: allocation, result: nil, language: language, at: now, timeZone: utc)
    }
    @MainActor private func start(_ model: PickupModel) async throws -> UUID {
        let food = UUID()
        let saved = await model.addUrgent(.init(id: food, food: "Wraps", meal: "Dinner", required: quantity(4),
            available: quantity(0), due: nil, confirmedAt: now))
        XCTAssertTrue(saved)
        return food
    }
    private func lot(_ amount: Int64, food: UUID, id: UUID = UUID()) -> ConfirmedStockLot {
        .init(id: id, foodID: food, name: "Freezer wraps", usable: quantity(amount), confirmedAt: now, source: .freezer)
    }

    @MainActor func testUrgentAddThenCorrectProjectsCurrentExactNeedAndReadbackAfterRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PickupModel(databaseURL: url, clock: { self.now })
        let food = try await start(model), shop = try XCTUnwrap(model.journey?.id)
        let original = lot(3, food: food), corrected = lot(1, food: food, id: original.id)
        let saved = await model.saveStockLot(original, in: shop)
        XCTAssertTrue(saved)
        let originalJourney = try XCTUnwrap(model.journey)
        let before = text(originalJourney, model.allocation)
        XCTAssertTrue(before.contains("Allocated: 3 units"), before)
        XCTAssertTrue(before.contains("Still short: 1 unit"), before)
        let bindingContext = PickupCookReadbackContext(scope: .init(localActorID: actor, accountSubject: nil,
            householdID: nil, memberID: nil, role: nil), workspaceUnlocked: true, householdLocked: false, saving: false, pendingSave: false)
        let oldReadback = try XCTUnwrap(PickupCookReadbackBinding(journey: originalJourney, allocation: model.allocation,
            result: nil, language: "en-US", includeBudget: false, text: before, context: bindingContext, at: now, timeZone: utc))
        let review = try model.previewStockLot(corrected, in: shop, replacing: original, scope: try scope(model))
        XCTAssertEqual(review.meals.first { $0.id == food }?.after?.allocated, .one)
        XCTAssertEqual(review.meals.first { $0.id == food }?.after?.shortfall, try Rational(3))
        let applied = await model.applyStockLotReview(review, scope: try scope(model), confirmed: true)
        XCTAssertTrue(applied)
        let current = try XCTUnwrap(model.journey), currentText = text(current, model.allocation)
        XCTAssertTrue(currentText.contains("Allocated: 1 unit"), currentText)
        XCTAssertTrue(currentText.contains("Still short: 3 units"), currentText)
        XCTAssertTrue(currentText.contains("Initially observed available: 0 units"), currentText)
        XCTAssertFalse(currentText.contains("Confirmed available: 0"), currentText)
        XCTAssertFalse(oldReadback.isCurrent(journey: current, allocation: model.allocation, result: nil,
            language: "en-US", includeBudget: false, text: before, context: bindingContext, at: now))
        let readback = try XCTUnwrap(PickupCookReadbackBinding(journey: current, allocation: model.allocation,
            result: nil, language: "en-US", includeBudget: false, text: currentText, context: bindingContext, at: now, timeZone: utc))
        XCTAssertEqual(readback.text, currentText)
        XCTAssertTrue(readback.isCurrent(journey: current, allocation: model.allocation, result: nil,
            language: "en-US", includeBudget: false, text: currentText, context: bindingContext, at: now))
        let spanish = text(current, model.allocation, language: "es-US")
        XCTAssertTrue(spanish.contains("Asignado: 1 unidad"), spanish)
        XCTAssertTrue(spanish.contains("Aún falta: 3 unidades"), spanish)
        let reopened = PickupModel(databaseURL: url, clock: { self.now })
        await reopened.load()
        XCTAssertEqual(text(try XCTUnwrap(reopened.journey), reopened.allocation), currentText)
        XCTAssertNil(reopened.journey?.pickup)
    }

    @MainActor func testMultiMealPreviewCancelAndExplicitApplyOnceKeepProtectedLunch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PickupModel(databaseURL: url, clock: { self.now })
        let food = try await start(model), shop = try XCTUnwrap(model.journey?.id), second = UUID(), lunch = UUID()
        let added = await model.change {
            $0.stockNeeds += [.init(id: second, foodID: food, name: "Second dinner", amount: self.quantity(3), priority: .required),
                             .init(id: lunch, foodID: food, name: "Protected lunch", amount: self.quantity(2), priority: .protected)]
        }
        XCTAssertTrue(added)
        let original = lot(7, food: food), corrected = lot(3, food: food, id: original.id)
        let saved = await model.saveStockLot(original, in: shop)
        XCTAssertTrue(saved)
        let baseline = try XCTUnwrap(model.journey)
        var cancelled: PickupStockLotReview? = try model.previewStockLot(corrected, in: shop, replacing: original, scope: try scope(model))
        XCTAssertEqual(Set(cancelled!.meals.map(\.id)), [food, second, lunch])
        XCTAssertEqual(cancelled?.meals.first { $0.id == food }?.before?.allocated, try Rational(4))
        XCTAssertEqual(cancelled?.meals.first { $0.id == food }?.after?.allocated, .one)
        XCTAssertEqual(cancelled?.meals.first { $0.id == second }?.before?.allocated, .one)
        XCTAssertEqual(cancelled?.meals.first { $0.id == second }?.after?.allocated, .zero)
        XCTAssertEqual(cancelled?.meals.first { $0.id == lunch }?.after?.allocated, try Rational(2))
        XCTAssertEqual(model.journey, baseline, "Preview must not change a revision, observation or allocation source.")
        cancelled = nil // The UI's Cancel drops only this ephemeral candidate.
        let reopenedBeforeApply = PickupModel(databaseURL: url, clock: { self.now })
        await reopenedBeforeApply.load()
        XCTAssertEqual(reopenedBeforeApply.journey, baseline, "Cancel must leave SQLite unchanged too.")
        let review = try model.previewStockLot(corrected, in: shop, replacing: original, scope: try scope(model))
        let unconfirmed = await model.applyStockLotReview(review, scope: try scope(model), confirmed: false)
        XCTAssertFalse(unconfirmed); XCTAssertEqual(model.journey, baseline)
        let applied = await model.applyStockLotReview(review, scope: try scope(model), confirmed: true)
        let revision = try XCTUnwrap(model.journey?.revision)
        let repeated = await model.applyStockLotReview(review, scope: try scope(model), confirmed: true)
        XCTAssertTrue(applied); XCTAssertTrue(repeated)
        XCTAssertEqual(revision, baseline.revision + 1); XCTAssertEqual(model.journey?.revision, revision)
        XCTAssertEqual(model.journey?.stockLots.filter { $0.id == original.id }, [corrected])
        let cook = text(try XCTUnwrap(model.journey), model.allocation)
        XCTAssertTrue(cook.contains("Protected lunch: 2 units — set aside first"), cook)
        XCTAssertTrue(cook.contains("Second dinner: 3 units"), cook)
        XCTAssertEqual(PickupCookProjection.pieces(journey: try XCTUnwrap(model.journey), allocation: model.allocation, language: "en-US")
            .filter { $0.key == "urgent/\(food)" || $0.key == "need/\(food)" }.count, 1)
    }

    @MainActor func testChangedRevisionSelectedShopAndEveryLiveScopeFieldInvalidatePreview() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PickupModel(databaseURL: url, clock: { self.now })
        let food = try await start(model), shop = try XCTUnwrap(model.journey?.id)
        let original = lot(3, food: food), corrected = lot(1, food: food, id: original.id)
        let saved = await model.saveStockLot(original, in: shop)
        XCTAssertTrue(saved)
        let live = try scope(model, subject: "adult", household: "home", member: "member", role: "shopper")
        let review = try model.previewStockLot(corrected, in: shop, replacing: original, scope: live)
        let changed = try [scope(model, actor: UUID(), subject: "adult", household: "home", member: "member", role: "shopper"),
            scope(model, subject: "other", household: "home", member: "member", role: "shopper"),
            scope(model, subject: "adult", household: "other", member: "member", role: "shopper"),
            scope(model, subject: "adult", household: "home", member: "other", role: "shopper"),
            scope(model, subject: "adult", household: "home", member: "member", role: "organizer"), scope(model)]
        for current in changed {
            let rejected = await model.applyStockLotReview(review, scope: current, confirmed: true)
            XCTAssertFalse(rejected)
        }
        let locked = await model.applyStockLotReview(review, scope: nil, confirmed: true)
        XCTAssertFalse(locked)
        model.selectedID = UUID()
        let otherShop = await model.applyStockLotReview(review, scope: live, confirmed: true)
        XCTAssertFalse(otherShop)
        model.selectedID = shop
        let changedMeal = await model.change { $0.stockNeeds.append(.init(id: UUID(), foodID: food, name: "New lunch", amount: self.quantity(1), priority: .protected)) }
        XCTAssertTrue(changedMeal)
        let baseline = model.journey
        let stale = await model.applyStockLotReview(review, scope: live, confirmed: true)
        XCTAssertFalse(stale); XCTAssertEqual(model.journey, baseline)
        XCTAssertEqual(model.journey?.stockLots.last, original)
    }

    @MainActor func testOtherProcessCommitRejectsOtherwiseCurrentPreviewWithoutOverwritingItsMeal() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PickupModel(databaseURL: url, clock: { self.now })
        let food = try await start(model), shop = try XCTUnwrap(model.journey?.id)
        let original = lot(3, food: food), corrected = lot(1, food: food, id: original.id)
        let saved = await model.saveStockLot(original, in: shop)
        XCTAssertTrue(saved)
        let review = try model.previewStockLot(corrected, in: shop, replacing: original, scope: try scope(model))
        let other = PickupModel(databaseURL: url, clock: { self.now })
        await other.load()
        let changed = await other.change { $0.stockNeeds.append(.init(id: UUID(), foodID: food, name: "Other process lunch", amount: self.quantity(1), priority: .protected)) }
        XCTAssertTrue(changed)
        let rejected = await model.applyStockLotReview(review, scope: try scope(model), confirmed: true)
        XCTAssertFalse(rejected)
        XCTAssertEqual(model.journey, other.journey)
        XCTAssertEqual(model.journey?.stockLots.last, original)
        XCTAssertFalse(model.hasPendingSave)
    }

    @MainActor func testCarriedBatchReviewExpiresWhenItsOriginalShopChanges() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = PickupModel(databaseURL: url, clock: { self.now })
        let food = try await start(model), sourceID = try XCTUnwrap(model.journey?.id)
        let original = lot(3, food: food)
        let saved = await model.saveStockLot(original, in: sourceID)
        XCTAssertTrue(saved)
        let next = await model.startNextShop(accept: [])
        XCTAssertTrue(next)
        let targetID = try XCTUnwrap(model.journey?.id), baseline = model.journey
        let review = try model.previewStockLot(lot(1, food: food, id: original.id), in: targetID, carriedFrom: original, scope: scope(model))
        XCTAssertEqual(model.journey, baseline)
        XCTAssertEqual(review.meals.first?.after?.shortfall, .zero)
        model.selectedID = sourceID
        let changedSource = await model.change { $0.urgent[0].repair = "Original batch needs another review" }
        XCTAssertTrue(changedSource)
        model.selectedID = targetID
        let stale = await model.applyStockLotReview(review, scope: try scope(model), confirmed: true)
        XCTAssertFalse(stale)
        XCTAssertEqual(model.journey, baseline)
        XCTAssertTrue(try XCTUnwrap(model.journey?.stockLots).isEmpty)
    }
}
