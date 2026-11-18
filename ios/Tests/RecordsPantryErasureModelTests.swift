import XCTest
@testable import RoomInTheCart

@MainActor final class RecordsPantryErasureModelTests: XCTestCase {
    private typealias Model = RecordsPantryErasureModel

    @MainActor private final class Fixture {
        let selected = Model.Choice(selection: .lot(UUID(), revision: 3), title: "Peas")
        let whole = Model.Choice(selection: .wholeOrigin, title: "")
        let pickupID = UUID()
        let collateralID = UUID()
        let copyID = UUID()
        let reviewID = UUID()
        var allowed = true
        var pending = false
        var blockers: Set<Model.Blocker> = []
        var collateral: [Model.Pickup] = []
        var prepared: [Model.Selection] = []
        var commits: [UUID] = []
        var cleanups = 0
        var pause: (() async -> Void)?
        var stale = false
        var substituteWhole = false

        func model() -> Model {
            Model(beginAuthorization: { [self] in
                guard allowed else { return nil }
                return { [self] in allowed }
            }, makeActions: { [self] authorize in
                Model.Actions(choices: {
                    guard authorize() else { throw PantryErasureCoordinator.Failure.unauthorized }
                    if self.pending { throw PantryErasureCoordinator.Failure.cleanupPending }
                    return [self.selected, self.whole]
                }, prepare: { selection in
                    self.prepared.append(selection)
                    await self.pause?()
                    // Deliberately return even after revocation to exercise presentation redaction.
                    return Model.Review(id: self.reviewID, selection: self.substituteWhole ? .wholeOrigin : selection,
                        foodNames: ["Peas", "Peas"], pickups: [.init(id: self.pickupID, title: "Tuesday pickup")],
                        collateralPickups: self.collateral, retainedReceiptFoodNames: ["Rice"],
                        affectedReservationNames: ["Dinner for two"], copyIDs: [self.copyID], pendingFileCount: 1,
                        blockers: self.blockers, canCommit: self.blockers.isEmpty, apply: {
                            guard authorize() else { throw PantryErasureCoordinator.Failure.unauthorized }
                            if self.stale { throw PantryErasureCoordinator.Failure.stale }
                            self.commits.append(self.reviewID)
                            return self.pending ? .cleanupPending : .deleted
                        })
                }, recoverCleanup: {
                    guard authorize() else { throw PantryErasureCoordinator.Failure.unauthorized }
                    self.cleanups += 1
                    guard self.pending else { return nil }
                    self.pending = false
                    return .deleted
                })
            })
        }
    }

    func testOnlyAnExplicitMatchingReviewCanCommitItsListedImpact() async throws {
        let f = Fixture(), model = f.model()
        await model.load()
        await model.prepare(.init(selection: .lot(UUID(), revision: 3), title: "Peas"))
        XCTAssertTrue(f.prepared.isEmpty)
        await model.prepare(f.selected)
        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(review.foodNames, ["Peas", "Peas"])
        XCTAssertEqual(review.pickups.map(\.title), ["Tuesday pickup"])
        XCTAssertEqual(review.pickups.map(\.id), [f.pickupID])
        XCTAssertEqual(review.affectedReservationNames, ["Dinner for two"])
        XCTAssertEqual(review.retainedReceiptFoodNames, ["Rice"])
        XCTAssertEqual(review.copyIDs, [f.copyID])
        XCTAssertEqual(review.pendingFileCount, 1)
        await model.commit(reviewID: UUID())
        XCTAssertTrue(f.commits.isEmpty)
        await model.commit(reviewID: review.id)
        f.allowed = false
        await model.commit(reviewID: review.id)
        XCTAssertTrue(model.choices.isEmpty)
        XCTAssertFalse(model.listed)
        XCTAssertEqual(f.commits, [review.id])
        XCTAssertEqual(model.notice, .deleted)
        XCTAssertNil(model.review)
    }

    func testBlockedCollateralAndUnverifiedDependenciesCannotExpandASelection() async throws {
        for blocker in [Model.Blocker.collateralPickups, .ledgerHistory, .unknownContent, .recoveredRecords] {
            let f = Fixture(), model = f.model()
            f.blockers = [blocker]
            if blocker == .collateralPickups { f.collateral = [.init(id: f.collateralID, title: "Saturday pickup")] }
            await model.load()
            await model.prepare(f.selected)
            let review = try XCTUnwrap(model.review)
            XCTAssertEqual(review.blockers, [blocker])
            XCTAssertEqual(review.collateralPickups.map(\.id), f.collateral.map(\.id))
            await model.commit(reviewID: review.id)
            XCTAssertEqual(f.prepared, [f.selected.selection])
            XCTAssertTrue(f.commits.isEmpty)
            model.cancelReview()
            XCTAssertNil(model.review)
        }
        let f = Fixture(), model = f.model()
        f.substituteWhole = true
        await model.load()
        await model.prepare(f.selected)
        XCTAssertNil(model.review)
        XCTAssertEqual(model.notice, .stale)
        XCTAssertTrue(f.commits.isEmpty)
    }

    func testStaleConfirmationRequiresAnotherReviewAndClearsPrivateDetails() async throws {
        let f = Fixture(), model = f.model()
        await model.load()
        await model.prepare(f.selected)
        let review = try XCTUnwrap(model.review)
        f.stale = true
        await model.commit(reviewID: review.id)
        XCTAssertEqual(model.notice, .stale)
        XCTAssertTrue(model.choices.isEmpty)
        XCTAssertNil(model.review)
        f.stale = false
        await model.commit(reviewID: review.id)
        XCTAssertTrue(f.commits.isEmpty)
    }

    func testPendingCleanupSurvivesReopeningAndNeverRecommitsDeletion() async throws {
        let f = Fixture(), model = f.model()
        await model.load()
        await model.prepare(f.selected)
        let review = try XCTUnwrap(model.review)
        f.pending = true
        await model.commit(reviewID: review.id)
        XCTAssertEqual(model.notice, .cleanupPending)
        model.invalidate()
        let reopened = f.model()
        await reopened.load()
        XCTAssertEqual(reopened.notice, .cleanupPending)
        XCTAssertTrue(reopened.choices.isEmpty)
        await reopened.recoverCleanup()
        await reopened.recoverCleanup()
        XCTAssertEqual(f.commits, [review.id])
        XCTAssertEqual(f.cleanups, 1)
        XCTAssertEqual(reopened.notice, .deleted)
    }

    func testScopeLossDuringPrepareCannotRepublishPrivateTitlesOrAuthorizeDeletion() async {
        let f = Fixture(), model = f.model()
        let started = expectation(description: "Source read suspended")
        var resume: CheckedContinuation<Void, Never>?
        f.pause = { await withCheckedContinuation { resume = $0; started.fulfill() } }
        await model.load()
        let work = Task { await model.prepare(f.selected) }
        await fulfillment(of: [started], timeout: 2)
        f.allowed = false
        model.invalidate()
        resume?.resume()
        await work.value
        XCTAssertTrue(model.choices.isEmpty)
        XCTAssertNil(model.review)
        XCTAssertNil(model.notice)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(f.commits.isEmpty)
    }
}
