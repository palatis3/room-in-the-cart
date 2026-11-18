import XCTest
import CoreDomain
import LocalStore
import SQLite3
import UIKit
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
