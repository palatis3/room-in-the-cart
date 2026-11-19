import XCTest
import CryptoKit
import UIKit
import CoreDomain
import LocalStore
import SQLite3
import CoreImage
@testable import RoomInTheCart

@MainActor
final class PantryModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func database(active: Bool = true) async throws -> (URL, ComparisonStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        if active {
            let token = try await store.inventorySourceToken()
            let state = try await store.inventoryState()
            _ = try await store.commitInventory(InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(),
                expectedRevision: state.revision, request: Data("reviewed empty pantry".utf8), mode: .activate, sourceToken: token), at: now)
        }
        return (directory, store)
    }

    private func model(_ store: ComparisonStore) -> PantryModel {
        PantryModel(repository: PantryRepository(store: store, authorize: { true }), clock: { self.now })
    }

    private func add(_ model: PantryModel, name: String = "Wraps", amount: String = "8", foodID: UUID? = nil) async throws -> InventoryLot {
        await model.prepareNewFood(name: name, existingFoodID: foodID, location: .cupboard, amount: amount, unit: .count)
        _ = try XCTUnwrap(model.review)
        await model.confirmReview(acknowledgingReservations: true)
        return try XCTUnwrap(model.snapshot?.lots.first { $0.id == model.savedLotID })
    }

    func testCoveredDigestRemountRetainsOnlyThePreviouslyLoadedPantry() async throws {
        let (directory, store) = try await database()
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        cleanup.track(store)
        var allowed = true
        let model = PantryModel(repository: PantryRepository(store: store, authorize: { allowed }))
        await model.load()
        let lot = try await add(model)
        allowed = false

        await model.loadOnAppearance(accessAllowed: true, holdsLoadedReview: true)
        XCTAssertEqual(model.snapshot?.lots.first?.id, lot.id)
        do {
            try await model.verifyDigestLot(lot, origin: store.workspaceID)
            XCTFail("A covered review cannot authorize a batch action.")
        } catch {}

        allowed = true
        await model.loadOnAppearance(accessAllowed: true)
        try await model.verifyDigestLot(lot, origin: store.workspaceID)

        allowed = false
        await model.loadOnAppearance(accessAllowed: false, holdsLoadedReview: true)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.phase, .accessDenied)
        await model.loadOnAppearance(accessAllowed: true, holdsLoadedReview: true)
        XCTAssertNil(model.snapshot)
        await model.loadDigestReview { false }
        XCTAssertNil(model.snapshot)
        allowed = true
        await model.loadDigestReview { true }
        XCTAssertEqual(model.snapshot?.lots.first?.id, lot.id)
    }

    private func reserve(_ lot: InventoryLot, store: ComparisonStore) async throws -> InventoryReservation {
        let state = try await store.inventoryState()
        let claim = InventoryReservation(id: UUID(), originID: store.workspaceID, revision: 1,
            foodID: lot.foodID, lotID: lot.id, name: "Tomorrow's lunch",
            amount: Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2"), priority: .protected)
        _ = try await store.commitInventory(InventoryBatch(workspaceID: store.workspaceID, operationID: UUID(),
            expectedRevision: state.revision, request: Data("lunch reservation".utf8),
            writes: [InventoryWrite(record: InventoryRecord(key: .init(.reservation, claim.id), revision: 1,
                payload: try JSONEncoder().encode(claim), lotID: lot.id), expectedRevision: 0)]), at: now)
        return claim
    }

    func testRecentUsageIncludesTodayAndPrevious29LocalDaysAcrossDaylightSaving() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let formatter = ISO8601DateFormatter()
        let now = try XCTUnwrap(formatter.date(from: "2026-11-18T18:00:00Z"))
        let times = [
            "2026-10-20T03:59:59Z", // October 19 in New York
            "2026-10-20T04:00:00Z", // First included local midnight (EDT)
            "2026-11-18T05:00:00Z", // Today's local midnight (EST)
            "2026-11-18T18:00:00Z",
            "2026-11-18T18:00:01Z"
        ]
        let entries = try times.map { text in
            PantryUsageHistoryRow(id: UUID(), occurredAt: try XCTUnwrap(formatter.date(from: text)),
                                 kind: .some, remainingWording: nil)
        }
        XCTAssertEqual(PantryUsageHistoryRow.usesInLast30Days(entries, asOf: now, timeZone: zone), 3)
    }

    func testPhotoExcerptOnlyProposesCompletePackageLinesAndPreservesUnicode() throws {
        func candidate(_ label: String) throws -> PantryProductBatch.Candidate {
            var batch = PantryProductBatch(workspaceID: UUID())
            let photo = ScannedSource(originalText: label, uncertainLines: [], originalImageData: Data([1]),
                                      referenceJPEG: Data(), barcodes: [])
            XCTAssertEqual(try batch.addPhoto(photo), 1)
            return try XCTUnwrap(batch.candidates.first)
        }

        let firstLine = String(repeating: "A", count: 505) + "\n"
        let clipped = try candidate(firstLine + "1 gallon of milk")
        XCTAssertTrue(clipped.original.hasSuffix("1 g…"))
        XCTAssertEqual(clipped.original.utf8.count, 512)
        XCTAssertTrue(clipped.perPack.isEmpty)
        let oldBoundary = String(repeating: "A", count: 508) + "\n1 g"
        XCTAssertTrue(try candidate(oldBoundary + "allon").perPack.isEmpty)
        let exactLimit = try candidate(oldBoundary)
        XCTAssertEqual(exactLimit.perPack, "1")
        XCTAssertTrue(exactLimit.original.hasSuffix("1 g"))
        let complete = try candidate(firstLine + "1 g\nOther wording")
        XCTAssertEqual(complete.perPack, "1")
        XCTAssertEqual(complete.unit, .gram)

        let spanishLabel = "Café\n" + String(repeating: "x", count: 502)
        let unicode = try candidate(spanishLabel + "ñandú")
        XCTAssertEqual(unicode.original, spanishLabel + "…")
        XCTAssertEqual(unicode.name, "Café")
    }

    func testTwoLocalProductPhotosAndRepeatedBarcodeCommitOnlyReviewedPackagesOnce() async throws {
        let (directory, db) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pantry = model(db)
        await pantry.load()
        let reader = OnDeviceScanService()
        func photo(_ text: String) throws -> Data {
            let bounds = CGRect(x: 0, y: 0, width: 1000, height: 360)
            let image = UIGraphicsImageRenderer(bounds: bounds).image { context in
                UIColor.white.setFill(); context.fill(bounds)
                (text as NSString).draw(in: bounds.insetBy(dx: 45, dy: 45),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 60), .foregroundColor: UIColor.black])
            }
            return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
        }
        let lentils = try await reader.scan(photo("LENTILS\n500 g"))
        let rice = try await reader.scan(photo("RICE\n1 kg"))
        XCTAssertTrue(lentils.barcodes.isEmpty && rice.barcodes.isEmpty)
        XCTAssertTrue(lentils.originalText.localizedCaseInsensitiveContains("lentils"))
        XCTAssertTrue(rice.originalText.localizedCaseInsensitiveContains("rice"))
        var batch = PantryProductBatch(workspaceID: db.workspaceID)
        XCTAssertEqual(try batch.addPhoto(lentils), 1)
        XCTAssertEqual(try batch.addPhoto(rice), 1)
        XCTAssertEqual(try batch.addPhoto(lentils), 0)
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("3017620422003".utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let qr = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let cg = try XCTUnwrap(CIContext().createCGImage(qr, from: qr.extent))
        let codePhoto = try await reader.scan(XCTUnwrap(UIImage(cgImage: cg).pngData()))
        XCTAssertEqual(codePhoto.barcodes.map(\.value), ["3017620422003"])
        XCTAssertEqual(try batch.addPhoto(codePhoto), 1)
        XCTAssertEqual(try batch.addPhoto(codePhoto), 0)
        XCTAssertFalse(try batch.addManual(name: "Repeat", code: "03017620422003"))
        var multiple = PantryProductBatch(workspaceID: db.workspaceID)
        let secondCode = CapturedBarcode(symbology: "EAN13", value: "4006381333931")
        let sharedFrame = ScannedSource(originalText: "Unassigned label", uncertainLines: [],
            originalImageData: codePhoto.originalImageData, referenceJPEG: codePhoto.referenceJPEG,
            barcodes: codePhoto.barcodes + [secondCode] + codePhoto.barcodes)
        XCTAssertEqual(try multiple.addPhoto(sharedFrame), 2)
        XCTAssertEqual(try multiple.addPhoto(sharedFrame), 0)
        XCTAssertTrue(multiple.candidates.allSatisfy { $0.name.isEmpty && $0.packages.isEmpty })
        multiple.revokePhotos()
        XCTAssertTrue(multiple.candidates.isEmpty)
        for index in 0..<11 { _ = try multiple.addManual(name: "Typed product " + String(index), code: nil) }
        XCTAssertThrowsError(try multiple.addPhoto(sharedFrame))
        XCTAssertEqual(multiple.candidates.count, 11, "An over-limit frame must leave the existing review intact")
        let package = ProductCatalogProposal(barcode: "3017620422003", name: "Proposed jar", quantity: "900 g", fetched: now, modified: nil)
        batch.candidates[2].use(package)
        XCTAssertEqual(batch.candidates[2].perPack, "900")
        XCTAssertTrue(batch.candidates[2].packages.isEmpty)
        XCTAssertThrowsError(try batch.draft(merchant: "Market", purchaseDate: now, confirmed: true))
        batch.candidates[0].name = "Green lentils"
        batch.candidates[0].perPack = "450"; batch.candidates[0].unit = .gram; batch.candidates[0].packages = "1"
        batch.candidates[1].name = "Brown rice"; batch.candidates[1].perPack = "2"
        batch.candidates[1].included = false
        batch.candidates[2].name = "Reviewed bean jar"; batch.candidates[2].perPack = "375"
        batch.candidates[2].unit = .gram; batch.candidates[2].packages = "2"
        XCTAssertThrowsError(try batch.draft(merchant: "Market", purchaseDate: now, confirmed: false))
        let initial = try await pantry.reviewReceipt(batch.draft(merchant: "Market", purchaseDate: now, confirmed: true))
        XCTAssertEqual(initial.facts.count, 2)
        XCTAssertEqual(pantry.snapshot?.lots.count, 0)
        batch.candidates[0].perPack = "400"
        batch.candidates[0].usable = "401"
        XCTAssertThrowsError(try batch.draft(merchant: "Market", purchaseDate: now, confirmed: true))
        batch.candidates[0].usable = "360"
        let draft = try batch.draft(merchant: "Market", purchaseDate: now, confirmed: true)
        let final = try await pantry.reviewReceipt(draft)
        XCTAssertEqual(final.facts.map(\.received.amount), [try Rational(400), try Rational(750)])
        XCTAssertTrue(final.facts[1].originalLine.contains("Open Food Facts"))
        try await pantry.saveReceipt(final)
        let replay = try await pantry.reviewReceipt(draft)
        XCTAssertNil(replay.batch)
        try await pantry.saveReceipt(replay)
        try await db.close()
        let reopened = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let fresh = model(reopened); await fresh.load()
        XCTAssertEqual(Set(try XCTUnwrap(fresh.snapshot).lots.map(\.name)), ["Green lentils", "Reviewed bean jar"])
        let history = try await fresh.receiptHistory()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.first(where: { $0.name == "Green lentils" })?.usable.amount, try Rational(360))
        XCTAssertEqual(history.first(where: { $0.name == "Reviewed bean jar" })?.usable.amount, try Rational(750))
        try await reopened.close()
    }

    func testReviewCancelAndExplicitFoodIdentityNeverMergeNames() async throws {
        let (directory, store) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(store)
        await model.load()
        await model.prepareNewFood(name: "Wraps", location: .cupboard, amount: "8", unit: .count)
        let uncommitted = try XCTUnwrap(model.review)
        XCTAssertEqual(uncommitted.proposedLot.count.quantity?.amount, try Rational(8))
        XCTAssertEqual(model.snapshot?.lots.count, 0)
        model.cancelReview()
        XCTAssertNil(model.review)
        let first = try await add(model)
        model.cancelReview() // The dismissed review sheet calls this after a successful save.
        XCTAssertEqual(model.notice, .saved)
        XCTAssertEqual(model.savedLotID, first.id)
        let second = try await add(model)
        XCTAssertNotEqual(first.foodID, second.foodID)
        let third = try await add(model, foodID: first.foodID)
        XCTAssertEqual(third.foodID, first.foodID)
        XCTAssertNotEqual(third.id, first.id)
        XCTAssertEqual(model.snapshot?.lots.count, 3)
        try await store.close()
        let reopened = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let reopenedModel = self.model(reopened)
        await reopenedModel.load()
        XCTAssertEqual(Set(reopenedModel.snapshot?.lots.map(\.id) ?? []), Set([first.id, second.id, third.id]))
        try await reopened.close()
    }

    func testSameScopeAppearanceKeepsReviewWhileExplicitRefreshAndLossClearIt() async throws {
        let (dir, db) = try await database()
        defer { try? FileManager.default.removeItem(at: dir) }
        var allowed = true
        let model = PantryModel(repository: PantryRepository(store: db, authorize: { allowed }))
        await model.loadOnAppearance(accessAllowed: true)
        let lot = try await add(model)
        await model.prepare(lotID: lot.id, action: .someLeft)
        let original = try XCTUnwrap(model.review?.command.id)
        await model.loadOnAppearance(accessAllowed: true)
        XCTAssertEqual(model.review?.command.id, original)
        await model.load()
        XCTAssertNil(model.review)
        await model.prepare(lotID: lot.id, action: .someLeft)
        XCTAssertNotNil(model.review)
        allowed = false
        await model.loadOnAppearance(accessAllowed: true)
        XCTAssertNil(model.review)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.phase, .accessDenied)
        try await db.close()
    }
    func testOversizedReviewDoesNotTrapPendingSaveAndSmallerEditStillWorks() async throws {
        let (directory, store) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = PantryModel(repository: PantryRepository(store: store,
            limits: .init(payloadBytes: PantryRepository.ReadLimits.standard.payloadBytes, observations: 1), authorize: { true }),
            clock: { self.now })
        await model.load()
        let lot = try await add(model)
        await model.prepare(lotID: lot.id, action: .someLeft)
        XCTAssertNil(model.review)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.notice, .changeTooLarge)
        XCTAssertTrue(model.canEdit)
        XCTAssertEqual(model.snapshot?.lots.first?.count, lot.count)
        await model.prepare(lotID: lot.id, action: .move(.freezer))
        XCTAssertNotNil(model.review)
        await model.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(model.notice, .saved)
        XCTAssertEqual(model.snapshot?.lots.first?.location, .freezer)
        XCTAssertEqual(model.snapshot?.lots.first?.count, lot.count)
        try await store.close()
    }

    func testReservationImpactRequiresAcknowledgmentAndQualitativeCountDoesNotFreeFood() async throws {
        let (directory, store) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(store)
        await model.load()
        let lot = try await add(model)
        let claim = try await reserve(lot, store: store)
        await model.load()
        await model.prepare(lotID: lot.id, action: .someLeft)
        XCTAssertEqual(model.review?.affectedReservations.map(\.id), [claim.id])
        await model.confirmReview(acknowledgingReservations: false)
        XCTAssertEqual(model.notice, .reservationReviewRequired)
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.snapshot?.lots.first?.count.quantity?.amount, try Rational(8))
        await model.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(model.snapshot?.lots.first?.count, .someLeft)
        XCTAssertNil(model.snapshot?.availability.lots.first?.free)
        XCTAssertEqual(model.snapshot?.reservations, [claim])
        await model.prepare(lotID: lot.id, action: .recount("3", .count))
        await model.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(model.snapshot?.availability.lots.first?.held?.amount, try Rational(2))
        XCTAssertEqual(model.snapshot?.availability.lots.first?.free?.amount, .one)
        await model.prepare(lotID: lot.id, action: .move(.freezer))
        await model.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(model.snapshot?.lots.first?.id, lot.id)
        XCTAssertEqual(model.snapshot?.lots.first?.location, .freezer)
        XCTAssertEqual(model.snapshot?.lots.first?.count.quantity?.amount, try Rational(3))
        try await store.close()
    }

    func testNewReservationMakesReviewedSaveStaleAndRequiresExplicitFreshReview() async throws {
        let (directory, store) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(store)
        await model.load()
        let lot = try await add(model)
        await model.prepare(lotID: lot.id, action: .usedUp)
        let original = try XCTUnwrap(model.review)
        _ = try await reserve(lot, store: store)
        await model.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(model.pending?.command, original.command)
        XCTAssertEqual(model.pending?.reviewedInventoryRevision, original.before.state.revision)
        XCTAssertTrue(model.requiresFreshReview)
        XCTAssertFalse(model.canEdit)
        await model.load()
        XCTAssertEqual(model.pending?.command, original.command)
        XCTAssertEqual(model.pending?.reviewedInventoryRevision, original.before.state.revision)
        await model.retryPending()
        XCTAssertEqual(model.notice, .stale)
        await model.discardStaleReview()
        XCTAssertNil(model.pending)
        XCTAssertTrue(model.canEdit)
        XCTAssertEqual(model.snapshot?.lots.first?.count.quantity?.amount, try Rational(8))
        await model.prepare(lotID: lot.id, action: .usedUp)
        XCTAssertNotEqual(model.review?.command.id, original.command.id)
        XCTAssertEqual(model.review?.affectedReservations.count, 1)
        try await store.close()
    }

    func testLockedDatabaseKeepsExactPendingInputAcrossRefreshAndRetry() async throws {
        let (directory, store) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(store)
        await model.load()
        await model.prepareNewFood(name: "Milk", location: .fridge, amount: "1,5", unit: .liter)
        let review = try XCTUnwrap(model.review)
        var lock: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("pickup.sqlite").path, &lock), SQLITE_OK)
        defer { sqlite3_close(lock) }
        XCTAssertEqual(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)
        await model.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(model.notice, .saveFailed)
        let pending = try XCTUnwrap(model.pending)
        XCTAssertEqual(pending.command, review.command)
        XCTAssertEqual(pending.reviewedInventoryRevision, review.before.state.revision)
        XCTAssertFalse(model.requiresFreshReview)
        model.cancelReview()
        XCTAssertEqual(model.pending, pending)
        XCTAssertEqual(sqlite3_exec(lock, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        await model.load()
        XCTAssertEqual(model.pending, pending)
        await model.retryPending()
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.snapshot?.lots.count, 1)
        XCTAssertEqual(model.snapshot?.lots.first?.count.quantity?.amount, try Rational(3, 2))
        await model.retryPending()
        let events = try await store.inventoryRecords(kind: .event)
        XCTAssertEqual(events.count, 1)
        try await store.close()
    }

    func testInactiveDoesNotActivateAndRevocationClearsAllPrivateState() async throws {
        let (inactiveDirectory, inactive) = try await database(active: false)
        defer { try? FileManager.default.removeItem(at: inactiveDirectory) }
        let unavailable = model(inactive)
        await unavailable.load()
        XCTAssertEqual(unavailable.phase, .migrationRequired)
        XCTAssertNil(unavailable.snapshot)
        let inactiveState = try await inactive.inventoryState()
        XCTAssertFalse(inactiveState.active)
        try await inactive.close()

        let (directory, store) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        var authorized = true
        let model = PantryModel(repository: PantryRepository(store: store, authorize: { authorized }), clock: { self.now })
        await model.load()
        let lot = try await add(model)
        await model.prepare(lotID: lot.id, action: .usedUp)
        authorized = false
        await model.confirmReview(acknowledgingReservations: true)
        XCTAssertEqual(model.phase, .accessDenied)
        XCTAssertNil(model.snapshot)
        XCTAssertNil(model.review)
        XCTAssertNil(model.pending)
        XCTAssertNil(model.savedLotID)
        XCTAssertFalse(model.busy)
        authorized = true
        await model.load()
        XCTAssertEqual(model.snapshot?.lots.first?.count.quantity?.amount, try Rational(8))
        model.accessLost()
        XCTAssertNil(model.snapshot)
        try await store.close()
    }
}

@MainActor private final class DigestSchedulerSpy: PantryDigestScheduling {
    var granted = false
    var requests = 0
    var replacementCount = 0
    var interruptNextReplacement = false
    var delivered = Set<UUID>()
    var onRequest: (() -> Void)?
    var deliveries: [PantryDigestDelivery] = []
    var removed = Set<UUID>()
    func permission(request: Bool, presenting: PantryNotificationPresenter?) async throws -> Bool {
        if request { requests += 1; onRequest?() }
        return granted
    }
    func replace(_ deliveries: [PantryDigestDelivery], keepingDelivered: Set<UUID>) async throws {
        replacementCount += 1
        if interruptNextReplacement {
            interruptNextReplacement = false
            throw CancellationError()
        }
        delivered.formIntersection(keepingDelivered)
        self.deliveries = deliveries
    }
    func prune(keepingPending: Set<UUID>, keepingDelivered: Set<UUID>) async {
        deliveries.removeAll { !keepingPending.contains($0.handle) }
        delivered.formIntersection(keepingDelivered)
    }
    func remove(_ handles: Set<UUID>) async {
        removed.formUnion(handles)
        delivered.subtract(handles)
        deliveries.removeAll { handles.contains($0.handle) }
    }
}

extension PantryModelTests {
    func testReviewedFoodKeeperRangeReopensAndSourceChangesRetireOnlyDerivedDates() async throws {
        let (directory, db) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pantry = model(db)
        await pantry.load()
        await pantry.prepareNewFood(name: "Pollo enlatado", location: .fridge, amount: "2", unit: .count)
        await pantry.confirmReview(acknowledgingReservations: true)
        let lot = try XCTUnwrap(pantry.snapshot?.lots.first)
        let scope = PantryDigestScope(origin: db.workspaceID, identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        let folder = directory.appendingPathComponent("ranges")
        let scheduler = DigestSchedulerSpy()
        scheduler.granted = true
        let digest = PantryDigestStore(folder: folder, scheduler: scheduler, now: { self.now })
        let today = try MealDay(date: now, timeZoneIdentifier: "America/New_York")
        let yesterday = try MealDay(date: now.addingTimeInterval(-86_400), timeZoneIdentifier: today.timeZoneIdentifier)
        let reference = try FoodKeeperReference.bundled()
        func reviewed(_ start: MealDay) throws -> FoodKeeperReviewedRange {
            try XCTUnwrap(reference.reviewedRange(productID: 142, condition: .refrigeratedOpened, storage: .refrigerator,
                                                  event: .opened, start: start, asOf: today, historyConfirmed: true))
        }
        let original = try reviewed(yesterday)
        try await digest.saveRange(original, scope: scope, lot: lot, authorized: { true })
        try await digest.setAlerts(scope, enabled: true, minute: 600, authorized: { true })
        XCTAssertEqual(scheduler.deliveries.count, 1)
        let reopened = PantryDigestStore(folder: folder, scheduler: scheduler, now: { self.now })
        let saved = try XCTUnwrap(reopened.document(scope).currentGuideRange(for: lot))
        XCTAssertEqual(saved, original)
        let matches = reference.search("chicken", language: .english)
        XCTAssertGreaterThan(matches.count, 1)
        XCTAssertTrue(matches.contains { $0.id == saved.productID })
        let lookup = FoodKeeperLookupContext(foodName: "Chicken", storage: .refrigerator, openedDay: nil, reviewedRange: saved)
        XCTAssertEqual(lookup.recordedStart(productID: 142, condition: .refrigeratedOpened), yesterday)
        XCTAssertNil(lookup.recordedStart(productID: 142, condition: .refrigeratedPurchased))
        XCTAssertNil(lookup.recordedStart(productID: 17, condition: .refrigeratedOpened))
        let other = PantryDigestScope(origin: scope.origin, identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        XCTAssertNil(try reopened.document(other).currentGuideRange(for: lot))
        XCTAssertEqual(try reopened.document(scope).rules.first?.day, original.earliest)
        let corrected = try reviewed(today)
        try await reopened.saveRange(corrected, scope: scope, lot: lot, authorized: { true })
        XCTAssertEqual(try reopened.document(scope).rules.first?.day, corrected.earliest)
        await pantry.prepare(lotID: lot.id, action: .opened)
        await pantry.confirmReview(acknowledgingReservations: true)
        let openedLot = try XCTUnwrap(pantry.snapshot?.lots.first)
        try await reopened.reconcile(scope, lots: [openedLot])
        XCTAssertTrue(scheduler.deliveries.isEmpty)
        XCTAssertTrue(try reopened.document(scope).rules.isEmpty)
        XCTAssertFalse(try XCTUnwrap(reopened.document(scope).selections.first).applies(to: openedLot))
        XCTAssertNil(try reopened.document(scope).currentGuideRange(for: openedLot))
        try await reopened.saveDay(scope, lot: openedLot, day: original.latest, authorized: { true })
        try await reopened.saveRange(corrected, scope: scope, lot: openedLot, authorized: { true })
        XCTAssertNil(try reopened.document(scope).rules.first?.source)
        await pantry.prepare(lotID: lot.id, action: .move(.freezer))
        await pantry.confirmReview(acknowledgingReservations: true)
        let frozen = try XCTUnwrap(pantry.snapshot?.lots.first)
        try await reopened.reconcile(scope, lots: [frozen])
        XCTAssertEqual(try reopened.document(scope).rules.first?.day, original.latest)
        XCTAssertFalse(try XCTUnwrap(reopened.document(scope).selections.first).applies(to: frozen))
        XCTAssertNil(try reopened.document(scope).currentGuideRange(for: frozen))
        do {
            try await reopened.saveRange(corrected, scope: scope, lot: frozen, authorized: { true })
            XCTFail("A refrigerated range cannot be saved for a frozen lot")
        } catch PantryDigestFailure.changed {}
        try await reopened.saveRange(nil, scope: scope, lot: frozen, authorized: { true })
        XCTAssertTrue(try reopened.document(scope).selections.isEmpty)
        XCTAssertEqual(try reopened.document(scope).rules.first?.day, original.latest)
        try await reopened.erase(origin: db.workspaceID, whole: true, inventory: db)
        XCTAssertTrue(try reopened.document(scope).rules.isEmpty)
        try await db.close()
    }

    func testPrintedPackageDateRecognizesSelectedSpanishLabelAndPreservesCorrectionAcrossReopen() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 890, height: 250)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            UIColor.white.setFill()
            UIRectFill(bounds)
            for (index, text) in ["CONSUMO PREFERENTE", "2027-11-25", "LOTE 25840"].enumerated() {
                (text as NSString).draw(at: CGPoint(x: 25, y: 12 + index * 72),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 40), .foregroundColor: UIColor.black])
            }
        }
        let bytes = try XCTUnwrap(image.pngData())
        let recognized = try await OnDeviceTextCapture().recognize(bytes)
        let selected = recognized.text.components(separatedBy: .newlines).prefix(2).joined(separator: "\n")
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let zone = "Europe/Madrid"
        let draft = try PrintedPackageDate.reviewingPhoto(selected, digest: digest, zone: zone)
        XCTAssertEqual(draft.meaning, .bestBefore)
        XCTAssertEqual(draft.day?.iso8601, "2027-11-25")
        XCTAssertFalse(try XCTUnwrap(draft.selectedPhotoText).contains("25840"))
        XCTAssertEqual(PrintedPackageDate.proposedDay(in: "25 de noviembre de 2027", zone: zone), draft.day)
        for wording in ["03/04/27", "JAN 2027", "2027-02-29", "2027-11-24 2027-11-25"] {
            XCTAssertNil(PrintedPackageDate.proposedDay(in: wording, zone: zone))
        }
        XCTAssertEqual(PrintedDateMeaning.suggested(for: "Packed on / best before"), .other)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let lot = UUID()
        let scope = PantryDigestScope(origin: UUID(), identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        let store = PantryPackageDateStore(folder: folder)
        let corrected = PrintedPackageDate(wording: "Consumo preferente: 26 NOV 2027", meaning: .bestBefore,
            day: try MealDay(year: 2027, month: 11, day: 26, timeZoneIdentifier: zone),
            selectedPhotoText: draft.selectedPhotoText, photoDigest: digest)
        try store.replace(nil, with: corrected, scope: scope, lot: lot, authorized: { true })
        let reopened = PantryPackageDateStore(folder: folder)
        XCTAssertEqual(try reopened.load(scope, lot: lot), corrected)
        XCTAssertThrowsError(try reopened.replace(nil, with: draft, scope: scope, lot: lot, authorized: { true }))
        XCTAssertThrowsError(try reopened.replace(corrected, with: nil, scope: scope, lot: lot, authorized: { false }))
        try reopened.replace(corrected, with: nil, scope: scope, lot: lot, authorized: { true })
        XCTAssertNil(try reopened.load(scope, lot: lot))
    }

    func testPrivatePrintedLabelKeepsManualCheckAcrossMoveAndFollowsLotAndOriginErasure() async throws {
        let (dir, db) = try await database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = model(db)
        await model.load()
        let lot = try await add(model)
        let origin = db.workspaceID
        func scope(_ origin: UUID) -> PantryDigestScope {
            .init(origin: origin, identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        }
        let adult = scope(origin), anotherAdult = scope(origin), otherWorkspace = scope(UUID())
        let folder = dir.appendingPathComponent("labels")
        let digest = PantryDigestStore(folder: folder, scheduler: DigestSchedulerSpy())
        let store = digest.packageDates
        let printed = PrintedPackageDate(wording: "BEST BY 03/04", meaning: .bestBefore, day: nil, selectedPhotoText: nil, photoDigest: nil)
        let check = try MealDay(year: 2027, month: 8, day: 5, timeZoneIdentifier: "America/New_York")
        try await digest.saveDay(adult, lot: lot, day: check, authorized: { true })
        try store.replace(nil, with: printed, scope: adult, lot: lot.id, authorized: { true })
        XCTAssertNil(try store.load(anotherAdult, lot: lot.id))
        XCTAssertNil(try store.load(otherWorkspace, lot: lot.id))
        let removedLot = UUID()
        for owner in [adult, anotherAdult, otherWorkspace] {
            try store.replace(nil, with: printed, scope: owner, lot: removedLot, authorized: { true })
        }
        XCTAssertEqual(try digest.document(adult).rules.first?.day, check)
        XCTAssertTrue(try digest.document(adult).selections.isEmpty)
        await model.prepare(lotID: lot.id, action: .move(.freezer))
        await model.confirmReview(acknowledgingReservations: true)
        try await digest.reconcile(adult, lots: try XCTUnwrap(model.snapshot?.lots))
        try await digest.erase(origin: origin, whole: false, inventory: db)
        XCTAssertEqual(try store.load(adult, lot: lot.id), printed)
        XCTAssertNil(try store.load(adult, lot: removedLot))
        XCTAssertNil(try store.load(anotherAdult, lot: removedLot))
        XCTAssertEqual(try digest.document(adult).rules.first?.day, check)
        try await digest.erase(origin: origin, whole: true, inventory: db)
        XCTAssertNil(try store.load(adult, lot: lot.id))
        XCTAssertEqual(try store.load(otherWorkspace, lot: removedLot), printed)
        try await db.close()
    }

    func testColdPantryOpensWithManualDateWhileSystemNotificationCleanupIsBlocked() async throws {
        let (directory, db) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = model(db)
        await original.load()
        let lot = try await add(original, name: "Cranberry beans")
        let scope = PantryDigestScope(origin: db.workspaceID, identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        let folder = directory.appendingPathComponent("digest")
        let saved = PantryDigestStore(folder: folder, scheduler: DigestSchedulerSpy())
        let day = try MealDay(year: 2027, month: 3, day: 14, timeZoneIdentifier: "America/New_York")
        try await saved.saveDay(scope, lot: lot, day: day, authorized: { true })
        let handle = try XCTUnwrap(saved.document(scope).rules.first?.handle)
        let identifier = PantryDigestNotifications.prefix + handle.uuidString
        let started = expectation(description: "Notification cleanup started")
        let release = DispatchSemaphore(value: 0)
        let system = PantryDigestNotifications(isolated: false) { pending, delivered in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(pending, [identifier])
            XCTAssertEqual(delivered, [identifier])
            started.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
        }
        let reopened = PantryDigestStore(folder: folder, scheduler: system)
        let cleanup = Task { try await reopened.reconcile(scope, lots: [lot]) }
        await fulfillment(of: [started], timeout: 5)

        let coldPantry = model(db)
        await coldPantry.loadOnAppearance(accessAllowed: true)
        XCTAssertEqual(coldPantry.snapshot?.lots.map(\.id), [lot.id])
        XCTAssertEqual(try reopened.document(scope).rules.map(\.day), [day])
        release.signal()
        try await cleanup.value
        try await db.close()
    }

    func testDigestDenialKeepsManualDatesAndConfirmedDailyGroupSurvivesReopen() async throws {
        let (dir, db) = try await database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = model(db)
        await model.load()
        let first = try await add(model), second = try await add(model, name: "Lentils")
        let scope = PantryDigestScope(origin: db.workspaceID, identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        let day = try MealDay(year: 2027, month: 3, day: 14, timeZoneIdentifier: "America/New_York")
        let spy = DigestSchedulerSpy(), folder = dir.appendingPathComponent("digest")
        let digest = PantryDigestStore(folder: folder, scheduler: spy, now: { self.now })
        try await digest.saveDay(scope, lot: first, day: day, authorized: { true })
        let travelDay = try MealDay(year: day.year, month: day.month, day: day.day, timeZoneIdentifier: "Europe/Madrid")
        try await digest.saveDay(scope, lot: second, day: travelDay, authorized: { true })
        XCTAssertEqual(spy.requests, 0)
        XCTAssertEqual(spy.replacementCount, 0)
        XCTAssertTrue(spy.deliveries.isEmpty)
        do {
            try await digest.setAlerts(scope, enabled: true, minute: 570, timeZone: try XCTUnwrap(TimeZone(identifier: day.timeZoneIdentifier)), authorized: { true })
            XCTFail("Denied permission enabled this digest")
        } catch PantryDigestFailure.denied {}
        XCTAssertFalse(try digest.document(scope).enabled)
        XCTAssertEqual(try digest.document(scope).rules.count, 2)
        spy.granted = true
        try await digest.setAlerts(scope, enabled: true, minute: 570, timeZone: try XCTUnwrap(TimeZone(identifier: day.timeZoneIdentifier)), authorized: { true })
        XCTAssertEqual(spy.deliveries.count, 1)
        let fire = try XCTUnwrap(spy.deliveries.first)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = try XCTUnwrap(TimeZone(identifier: day.timeZoneIdentifier))
        XCTAssertEqual(cal.component(.hour, from: fire.date), 9)
        XCTAssertEqual(cal.component(.minute, from: fire.date), 30)
        let reopened = PantryDigestStore(folder: folder, scheduler: spy, now: { self.now })
        try await reopened.reconcile(scope, lots: try XCTUnwrap(model.snapshot).lots)
        XCTAssertEqual(spy.deliveries, [fire])
        XCTAssertEqual(spy.requests, 2)
        await model.prepare(lotID: first.id, action: .usedUp)
        await model.confirmReview(acknowledgingReservations: true)
        try await reopened.reconcile(scope, lots: try XCTUnwrap(model.snapshot).lots)
        XCTAssertEqual(try reopened.document(scope).rules.map(\.lotID), [second.id])
        XCTAssertEqual(spy.deliveries, [fire])
        try await reopened.saveDay(scope, lot: second, day: nil, authorized: { true })
        XCTAssertTrue(spy.deliveries.isEmpty)
        try await db.close()
    }

    func testDigestPermissionScopeAndDateChangesReplaceAlertsWhileKeepingInAppChoices() async throws {
        let (dir, db) = try await database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = model(db); await model.load()
        let lot = try await add(model)
        let owner = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        let scope = PantryDigestScope(origin: db.workspaceID, identity: owner)
        let scheduler = DigestSchedulerSpy(); scheduler.granted = true
        let folder = dir.appendingPathComponent("digest")
        let digest = PantryDigestStore(folder: folder, scheduler: scheduler, now: { self.now })
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let first = try MealDay(year: 2027, month: 12, day: 11, timeZoneIdentifier: zone.identifier)
        let later = try MealDay(year: 2027, month: 12, day: 12, timeZoneIdentifier: zone.identifier)
        try await digest.saveDay(scope, lot: lot, day: first, authorized: { true })
        let document = try digest.document(scope)
        let checkDay = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-12-11T05:00:00Z"))
        XCTAssertEqual(try document.homeSummaryCount(lots: [lot], now: checkDay, zone: zone), 1)
        XCTAssertEqual(try document.homeSummaryCount(lots: [lot], now: checkDay.addingTimeInterval(-1), zone: zone), 0)
        XCTAssertEqual(try document.homeSummaryCount(lots: [], now: checkDay, zone: zone), 0)
        XCTAssertFalse(document.enabled, "Reviewed dates can be summarized independently of notification permission")
        var allowed = true
        scheduler.onRequest = { allowed = false }
        do {
            try await digest.setAlerts(scope, enabled: true, minute: 600, timeZone: zone, authorized: { allowed })
            XCTFail("A late system grant cannot enable another session")
        } catch PantryDigestFailure.changed {}
        XCTAssertFalse(try digest.document(scope).enabled)
        XCTAssertTrue(scheduler.deliveries.isEmpty)
        scheduler.onRequest = nil
        try await digest.setAlerts(scope, enabled: true, minute: 600, timeZone: zone, authorized: { true })
        let before = try XCTUnwrap(scheduler.deliveries.first)
        // A notification already shown for this date must still open the digest after saving the same day.
        scheduler.delivered.insert(before.handle)
        let afterDelivery = PantryDigestStore(folder: folder, scheduler: scheduler, now: { before.date.addingTimeInterval(1) })
        try await afterDelivery.saveDay(scope, lot: lot, day: first, authorized: { true })
        XCTAssertTrue(scheduler.deliveries.isEmpty)
        XCTAssertEqual(try digest.document(scope).rules.first?.handle, before.handle)
        XCTAssertTrue(scheduler.delivered.contains(before.handle))
        try await afterDelivery.saveDay(scope, lot: lot, day: later, authorized: { true })
        XCTAssertFalse(scheduler.delivered.contains(before.handle))
        let replacement = try XCTUnwrap(scheduler.deliveries.first)
        XCTAssertEqual(scheduler.deliveries.count, 1)
        XCTAssertNotEqual(before.handle, replacement.handle)
        XCTAssertEqual(replacement.date.timeIntervalSince(before.date), 86_400)
        scheduler.granted = false
        try await digest.reconcile(scope, lots: [lot])
        XCTAssertTrue(scheduler.deliveries.isEmpty)
        XCTAssertTrue(digest.notificationsUnavailable)
        XCTAssertEqual(try digest.document(scope).rules.first?.day, later)
        try await digest.setAlerts(scope, enabled: false, minute: 600, timeZone: zone, authorized: { true })
        XCTAssertFalse(try digest.document(scope).enabled)
        XCTAssertEqual(try digest.document(scope).rules.first?.day, later)
        try await db.close()
    }

    func testScopeChangeCancelsOrphanedDigestAfterInterruptedDateCorrection() async throws {
        let (dir, db) = try await database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pantry = model(db)
        await pantry.load()
        let lot = try await add(pantry)
        let original = PantryDigestScope(origin: db.workspaceID, identity: .init(actorID: UUID(), subject: nil,
            householdID: nil, memberID: nil, role: nil))
        let other = PantryDigestScope(origin: db.workspaceID, identity: .init(actorID: UUID(), subject: nil,
            householdID: nil, memberID: nil, role: nil))
        let day = try MealDay(year: 2027, month: 6, day: 1, timeZoneIdentifier: "America/New_York")
        let corrected = try MealDay(year: 2027, month: 6, day: 2, timeZoneIdentifier: day.timeZoneIdentifier)
        let folder = dir.appendingPathComponent("digest")
        let scheduler = DigestSchedulerSpy()
        scheduler.granted = true
        for alreadyDelivered in [false, true] {
            let store = PantryDigestStore(folder: folder, scheduler: scheduler, now: { self.now })
            try await store.saveDay(original, lot: lot, day: day, authorized: { true })
            try await store.setAlerts(original, enabled: true, minute: 600, authorized: { true })
            let oldHandle = try XCTUnwrap(scheduler.deliveries.first?.handle)
            if alreadyDelivered {
                scheduler.deliveries.removeAll()
                scheduler.delivered.insert(oldHandle)
            }
            // Stop between the atomic date write and the notification center's replacement.
            scheduler.interruptNextReplacement = true
            do {
                try await store.saveDay(original, lot: lot, day: corrected, authorized: { true })
                XCTFail("The interrupted replacement unexpectedly completed")
            } catch is CancellationError {}

            let reopened = PantryDigestStore(folder: folder, scheduler: scheduler, now: { self.now })
            let rule = try XCTUnwrap(reopened.document(original).rules.first)
            XCTAssertEqual(rule.day, corrected)
            XCTAssertNotEqual(rule.handle, oldHandle)
            XCTAssertTrue(try reopened.document(other).rules.isEmpty)
            try await reopened.reconcile(other, lots: [lot])
            XCTAssertTrue(scheduler.deliveries.isEmpty, "The previous shopper's pending alert survived")
            XCTAssertTrue(scheduler.delivered.isEmpty, "The previous shopper's delivered alert survived")
            XCTAssertEqual(try reopened.document(original).rules.first?.day, corrected)
        }
        try await db.close()
    }

    func testDisableAndWholeErasurePruneUnlistedDigestRequestsAndPreserveAnotherOrigin() async throws {
        try await verifyInterruptedDigestCleanup(corruptUnrelated: false)
    }

    func testCorruptUnrelatedDigestDoesNotBlockOptOutOrWholeOriginErasure() async throws {
        try await verifyInterruptedDigestCleanup(corruptUnrelated: true)
    }

    private func verifyInterruptedDigestCleanup(corruptUnrelated: Bool) async throws {
        let (dir, db) = try await database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pantry = model(db)
        await pantry.load()
        let lot = try await add(pantry)
        let owner = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        let original = PantryDigestScope(origin: db.workspaceID, identity: owner)
        let (otherDir, otherDB) = try await database()
        defer { try? FileManager.default.removeItem(at: otherDir) }
        let otherPantry = model(otherDB)
        await otherPantry.load()
        let otherLot = try await add(otherPantry, name: "Rice")
        let other = PantryDigestScope(origin: otherDB.workspaceID, identity: owner)
        let day = try MealDay(year: 2027, month: 6, day: 1, timeZoneIdentifier: "America/New_York")
        let corrected = try MealDay(year: 2027, month: 6, day: 2, timeZoneIdentifier: day.timeZoneIdentifier)
        for (erase, keepOther) in [(false, true), (true, true), (true, false)] {
            let folder = dir.appendingPathComponent(UUID().uuidString)
            let scheduler = DigestSchedulerSpy()
            scheduler.granted = true
            let store = PantryDigestStore(folder: folder, scheduler: scheduler, now: { self.now })
            var surviving: [PantryDigestDelivery] = []
            if keepOther {
                try await store.saveDay(other, lot: otherLot, day: day, authorized: { true })
                try await store.setAlerts(other, enabled: true, minute: 600, authorized: { true })
                surviving = [try XCTUnwrap(scheduler.deliveries.first)]
            }
            try await store.saveDay(original, lot: lot, day: day, authorized: { true })
            try await store.setAlerts(original, enabled: true, minute: 600, authorized: { true })
            let oldHandle = try XCTUnwrap(scheduler.deliveries.first?.handle)
            scheduler.interruptNextReplacement = true
            do {
                try await store.saveDay(original, lot: lot, day: corrected, authorized: { true })
                XCTFail("The interrupted replacement unexpectedly completed")
            } catch is CancellationError {}

            // Include an independent, still-valid registration in both OS inventories.
            scheduler.deliveries.append(contentsOf: surviving)
            let survivingHandles = Set(surviving.map(\.handle))
            scheduler.delivered = survivingHandles.union([oldHandle])
            let corruptURL = folder.appendingPathComponent(UUID().uuidString + "-" + original.owner + ".json")
            let unreadable = Data("incomplete private digest".utf8)
            if corruptUnrelated {
                try unreadable.write(to: corruptURL)
                let unknown = UUID()
                scheduler.deliveries.append(.init(handle: unknown, date: now, zone: .current))
                scheduler.delivered.insert(unknown)
            }
            let reopened = PantryDigestStore(folder: folder, scheduler: scheduler, now: { self.now })
            if erase {
                try await reopened.erase(origin: original.origin, whole: true, inventory: db)
                XCTAssertTrue(try reopened.document(original).rules.isEmpty)
            } else {
                try await reopened.setAlerts(original, enabled: false, minute: 600, authorized: { true })
                XCTAssertEqual(try reopened.document(original).rules.first?.day, corrected)
            }
            XCTAssertFalse(try reopened.document(original).enabled)
            XCTAssertEqual(scheduler.deliveries, surviving)
            XCTAssertEqual(scheduler.delivered, survivingHandles)
            XCTAssertEqual(try reopened.document(other).enabled, keepOther)
            if corruptUnrelated { XCTAssertEqual(try Data(contentsOf: corruptURL), unreadable) }
        }
        try await otherDB.close()
        try await db.close()
    }

    func testShelfAndMinimumReopenUnderOriginalOwnerAndEraseWithOrigin() async throws {
        let (directory, db) = try await database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = model(db)
        await model.load()
        let lot = try await add(model)
        let scope = PantryDigestScope(origin: db.workspaceID, identity: .init(actorID: UUID(), subject: nil,
                                                                             householdID: nil, memberID: nil, role: nil))
        var unlocked = true
        let access = PantryDigestAccess(scope: scope, authorized: { unlocked })
        let folder = directory.appendingPathComponent("checks")
        let first = PantryDigestStore(folder: folder, scheduler: DigestSchedulerSpy())
        let shelf = PantryShelfCount(id: UUID(), name: "Top shelf", location: lot.location,
                                    batches: [.init(id: lot.id, revision: lot.revision, answer: .present)])
        let target = PantryStapleMinimum(foodID: lot.foodID, anchorLotID: lot.id,
                                        target: Quantity(amount: .one, unit: .count, originalLiteral: "1"), afterHolds: true)
        let legacy = try JSONEncoder().encode(PantryDigestDocument(scope))
        XCTAssertNil(try JSONDecoder().decode(PantryDigestDocument.self, from: legacy).shelf)
        try first.updateShelf(nil, next: shelf, sighting: lot.id, access: access)
        try first.updateMinimum(nil, next: target, foodID: lot.foodID, access: access)
        let reopened = PantryDigestStore(folder: folder, scheduler: DigestSchedulerSpy())
        let doc = try reopened.document(scope)
        XCTAssertEqual(doc.shelf, shelf)
        XCTAssertEqual(doc.minimums, [target])
        XCTAssertEqual(doc.presence?.map(\.lotID), [lot.id])
        XCTAssertThrowsError(try reopened.updateShelf(nil, next: nil, access: access))
        unlocked = false
        XCTAssertThrowsError(try reopened.updateMinimum(target, next: nil, foodID: lot.foodID, access: access))
        let other = PantryDigestScope(origin: db.workspaceID, identity: .init(actorID: UUID(), subject: nil,
                                                                             householdID: nil, memberID: nil, role: nil))
        XCTAssertNil(try reopened.document(other).shelf)
        XCTAssertNil(try reopened.document(other).minimums)
        try await reopened.erase(origin: db.workspaceID, whole: true, inventory: db)
        XCTAssertNil(try reopened.document(scope).shelf)
        XCTAssertNil(try reopened.document(scope).minimums)
        XCTAssertNil(try reopened.document(scope).presence)
        try await db.close()
    }

    func testDigestErasureRemovesOnlyAffectedHandlesAndWholeOriginRevokesSavedConsent() async throws {
        let (dir, db) = try await database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = model(db); await model.load()
        let first = try await add(model), second = try await add(model, name: "Rice")
        let owner = CapturePrivateIdentity(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil)
        let scope = PantryDigestScope(origin: db.workspaceID, identity: owner)
        let spy = DigestSchedulerSpy(); spy.granted = true
        let digest = PantryDigestStore(folder: dir.appendingPathComponent("digest"), scheduler: spy, now: { self.now })
        let day = try MealDay(year: 2027, month: 5, day: 3, timeZoneIdentifier: "America/New_York")
        let next = try MealDay(year: 2027, month: 5, day: 4, timeZoneIdentifier: "America/New_York")
        try await digest.saveDay(scope, lot: first, day: day, authorized: { true })
        try await digest.saveDay(scope, lot: second, day: next, authorized: { true })
        try await digest.setAlerts(scope, enabled: true, minute: 600, authorized: { true })
        let handles = try digest.document(scope).rules.map(\.handle)
        await model.prepare(lotID: first.id, action: .move(.freezer))
        await model.confirmReview(acknowledgingReservations: true)
        try await digest.erase(origin: db.workspaceID, whole: false, inventory: db)
        XCTAssertEqual(spy.removed, [handles[0]])
        XCTAssertEqual(spy.deliveries.map(\.handle), [handles[1]])
        XCTAssertEqual(try digest.document(scope).rules.map(\.lotID), [second.id])
        try await digest.erase(origin: db.workspaceID, whole: true, inventory: db)
        XCTAssertEqual(spy.removed, Set(handles))
        XCTAssertFalse(try digest.document(scope).enabled)
        XCTAssertTrue(try digest.document(scope).rules.isEmpty)
        try await db.close()
    }
}
