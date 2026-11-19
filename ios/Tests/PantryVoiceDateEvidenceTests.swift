import CoreDomain
import Foundation
import LocalStore
import XCTest
@testable import RoomInTheCart

@MainActor
final class PantryVoiceDateEvidenceTests: XCTestCase {
    private struct Fixture {
        let database: ComparisonStore
        let model: PantryModel
        let digest: PantryDigestStore
        let access: PantryDigestAccess
        let directory: URL
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let db = try ComparisonStore(url: directory.appendingPathComponent("voice.sqlite"), inventoryEnabled: true)
        let source = try await db.inventorySourceToken()
        let state = try await db.inventoryState()
        _ = try await db.commitInventory(.init(workspaceID: db.workspaceID, operationID: UUID(),
            expectedRevision: state.revision, request: Data("activate empty test pantry".utf8), mode: .activate, sourceToken: source), at: now)
        let model = PantryModel(repository: PantryRepository(store: db, authorize: { true }), clock: { self.now })
        await model.load()
        let scope = PantryDigestScope(origin: db.workspaceID, identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        let digest = PantryDigestStore(folder: directory.appendingPathComponent("dates"), scheduler: PantryDigestNotifications(isolated: true), now: { self.now })
        return Fixture(database: db, model: model, digest: digest, access: .init(scope: scope, authorized: { true }), directory: directory)
    }

    private func addBottle(_ model: PantryModel, name: String = "Milk") async throws -> InventoryLot {
        await model.prepareNewFood(name: name, location: .fridge, amount: "1", unit: .count)
        _ = try XCTUnwrap(model.review)
        await model.confirmReview(acknowledgingReservations: true)
        return try XCTUnwrap(model.snapshot?.lots.first { $0.id == model.savedLotID })
    }

    func testSelectedBottleKeepsLabelMeaningSeparateFromGuideAndManualReminder() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let first = try await addBottle(f.model), second = try await addBottle(f.model)
        XCTAssertNotEqual(first.id, second.id)
        let today = try MealDay(date: now, timeZoneIdentifier: "America/Los_Angeles")
        let reference = try FoodKeeperReference.bundled()
        let range = try XCTUnwrap(reference.reviewedRange(productID: 644, condition: .refrigeratedOpened, storage: .refrigerator,
            event: .opened, start: today, asOf: today, historyConfirmed: true))
        try await f.digest.saveRange(range, scope: f.access.scope, lot: first, authorized: { true })
        try await f.digest.saveDay(f.access.scope, lot: second, day: today, authorized: { true })
        let label = PrintedPackageDate(wording: "SELL BY 31 DEC 2027", meaning: .sellBy,
            day: try MealDay(year: 2027, month: 12, day: 31, timeZoneIdentifier: "Pacific/Kiritimati"), selectedPhotoText: nil, photoDigest: nil)
        try f.digest.packageDates.replace(nil, with: label, scope: f.access.scope, lot: first.id, authorized: { true })
        let evidence = try await PantryVoiceDateEvidence.read(lot: first, model: f.model, access: f.access, now: now, store: f.digest)
        XCTAssertEqual(evidence.printed, label)
        XCTAssertEqual(evidence.quality, range)
        XCTAssertTrue(evidence.isCurrent(lot: first, model: f.model, access: f.access, now: now))
        XCTAssertFalse(evidence.isCurrent(lot: second, model: f.model, access: f.access, now: now))
        XCTAssertFalse(evidence.isCurrent(lot: first, model: f.model, access: f.access, now: now.addingTimeInterval(86_400)))
        let otherBottle = try await PantryVoiceDateEvidence.read(lot: second, model: f.model, access: f.access, now: now, store: f.digest)
        XCTAssertNil(otherBottle.printed)
        XCTAssertNil(otherBottle.quality)
        let otherOwner = PantryDigestScope(origin: f.database.workspaceID, identity: .init(actorID: UUID(), subject: nil, householdID: nil, memberID: nil, role: nil))
        let otherAccess = PantryDigestAccess(scope: otherOwner, authorized: { true })
        XCTAssertFalse(evidence.isCurrent(lot: first, model: f.model, access: otherAccess, now: now))
        let privateAnswer = try await PantryVoiceDateEvidence.read(lot: first, model: f.model, access: otherAccess, now: now, store: f.digest)
        XCTAssertNil(privateAnswer.printed)
        XCTAssertNil(privateAnswer.quality)
        try await f.database.close()
    }

    func testUnclearPrintedWordingIsNotParsedAndChangedEvidenceOrAuthorityInvalidatesAnswer() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let lot = try await addBottle(f.model)
        let label = PrintedPackageDate(wording: "03/04 · LOT 05/06", meaning: .other, day: nil, selectedPhotoText: nil, photoDigest: nil)
        try f.digest.packageDates.replace(nil, with: label, scope: f.access.scope, lot: lot.id, authorized: { true })
        let answer = try await PantryVoiceDateEvidence.read(lot: lot, model: f.model, access: f.access, now: now, store: f.digest)
        XCTAssertEqual(answer.printed, label)
        XCTAssertNil(answer.printed?.day)
        XCTAssertNil(answer.quality)
        let denied = PantryDigestAccess(scope: f.access.scope, authorized: { false })
        XCTAssertFalse(answer.isCurrent(lot: lot, model: f.model, access: denied, now: now))
        do {
            _ = try await PantryVoiceDateEvidence.read(lot: lot, model: f.model, access: denied, now: now, store: f.digest)
            XCTFail("Denied access must discard the batch and its dates.")
        } catch PantryDigestFailure.changed {}
        try f.digest.packageDates.replace(label, with: nil, scope: f.access.scope, lot: lot.id, authorized: { true })
        XCTAssertFalse(answer.isCurrent(lot: lot, model: f.model, access: f.access, now: now))
        let secondModel = PantryModel(repository: PantryRepository(store: f.database, authorize: { true }), clock: { self.now })
        await secondModel.load()
        _ = try await addBottle(secondModel)
        do {
            _ = try await PantryVoiceDateEvidence.read(lot: lot, model: f.model, access: f.access, now: now, store: f.digest)
            XCTFail("Another matching bottle added after the query requires fresh batch selection.")
        } catch PantryDigestFailure.changed {}
        try await f.database.close()
    }

    func testEachReviewedPackageMeaningReturnsUnchangedWithNoInventedQualityRange() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let lot = try await addBottle(f.model)
        let day = try MealDay(year: 2027, month: 3, day: 14, timeZoneIdentifier: "America/New_York")
        var previous: PrintedPackageDate?
        for meaning in PrintedDateMeaning.allCases {
            let label = PrintedPackageDate(wording: "14 MAR 2027", meaning: meaning, day: day, selectedPhotoText: nil, photoDigest: nil)
            try f.digest.packageDates.replace(previous, with: label, scope: f.access.scope, lot: lot.id, authorized: { true })
            let answer = try await PantryVoiceDateEvidence.read(lot: lot, model: f.model, access: f.access, now: now, store: f.digest)
            XCTAssertEqual(answer.printed?.meaning, meaning)
            XCTAssertEqual(answer.printed?.day, day)
            XCTAssertNil(answer.quality)
            previous = label
        }
        try await f.database.close()
    }

    func testRecordedUseKeepsLabelAndRequiresExplicitFoodKeeperReviewOnChangedBatch() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let bottle = try await addBottle(f.model, name: "Kefir")
        let other = try await addBottle(f.model, name: "Kefir")
        let today = try MealDay(date: now, timeZoneIdentifier: "America/New_York")
        let label = PrintedPackageDate(wording: "BEST BEFORE 15 JAN 2027", meaning: .bestBefore,
                                      day: today, selectedPhotoText: nil, photoDigest: nil)
        try f.digest.packageDates.replace(nil, with: label, scope: f.access.scope, lot: bottle.id, authorized: { true })
        let reference = try FoodKeeperReference.bundled()
        let purchased = try XCTUnwrap(reference.reviewedRange(productID: 25, condition: .refrigeratedPurchased, storage: .refrigerator,
            event: .purchased, start: today, asOf: today, historyConfirmed: true))
        try await f.digest.saveRange(purchased, scope: f.access.scope, lot: bottle, authorized: { true })
        let original = try await PantryVoiceDateEvidence.read(lot: bottle, model: f.model, access: f.access, now: now, store: f.digest)
        XCTAssertEqual(original.guide, .current(purchased))

        let basis = try XCTUnwrap(f.model.snapshot?.state)
        let use = try await f.model.reviewConsumption([.init(lotID: bottle.id, use: .usedSome(remainingWording: nil))], basis: basis)
        try await f.model.saveConsumption(use)
        let lots = try XCTUnwrap(f.model.snapshot?.lots)
        let changed = try XCTUnwrap(lots.first { $0.id == bottle.id })
        XCTAssertGreaterThan(changed.revision, bottle.revision)
        try await f.digest.reconcile(f.access.scope, lots: lots)
        let stale = try await PantryVoiceDateEvidence.read(lot: changed, model: f.model, access: f.access, now: now, store: f.digest)
        XCTAssertEqual(stale.printed, label)
        XCTAssertEqual(stale.guide, .needsReview)
        XCTAssertNil(stale.quality)
        let untouched = try await PantryVoiceDateEvidence.read(lot: other, model: f.model, access: f.access, now: now, store: f.digest)
        XCTAssertEqual(untouched.guide, .unavailable)
        XCTAssertEqual(try f.digest.document(f.access.scope).selections.first?.revision, bottle.revision)

        let opened = try XCTUnwrap(reference.reviewedRange(productID: 25, condition: .refrigeratedOpened, storage: .refrigerator,
            event: .opened, start: today, asOf: today, historyConfirmed: true))
        try await f.digest.saveRange(opened, scope: f.access.scope, lot: changed, authorized: { true })
        let updated = try await PantryVoiceDateEvidence.read(lot: changed, model: f.model, access: f.access, now: now, store: f.digest)
        XCTAssertEqual(updated.guide, .current(opened))
        XCTAssertEqual(updated.printed, label)
        try await f.database.close()
    }

    func testGuideEditionStartingEventAndCivilDayAreRechecked() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.directory) }
        let lot = try await addBottle(f.model)
        let start = try MealDay(year: 2027, month: 1, day: 16, timeZoneIdentifier: "America/Los_Angeles")
        let beforeMidnight = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-16T07:59:59Z"))
        let afterMidnight = beforeMidnight.addingTimeInterval(1)
        let after = try MealDay(date: afterMidnight, timeZoneIdentifier: start.timeZoneIdentifier)
        let before = try MealDay(date: beforeMidnight, timeZoneIdentifier: start.timeZoneIdentifier)
        let reference = try FoodKeeperReference.bundled()
        let range = try XCTUnwrap(reference.reviewedRange(productID: 644, condition: .refrigeratedOpened, storage: .refrigerator,
            event: .opened, start: start, asOf: after, historyConfirmed: true))
        let selected = PantryFoodKeeperSelection(lotID: lot.id, revision: lot.revision, range: range)
        XCTAssertNil(PantryVoiceDateEvidence.currentRange(selected, for: lot, today: before, reference: reference))
        XCTAssertEqual(PantryVoiceDateEvidence.currentRange(selected, for: lot, today: after, reference: reference), range)
        let incompatibleOpening = InventoryLot(id: lot.id, foodID: lot.foodID, name: lot.name, source: lot.source, revision: lot.revision,
            location: lot.location, openedAt: beforeMidnight, unit: lot.unit, count: lot.count, observationID: lot.observationID,
            confirmedAt: lot.confirmedAt, updatedAt: lot.updatedAt)
        XCTAssertNil(PantryVoiceDateEvidence.currentRange(selected, for: incompatibleOpening, today: after, reference: reference))
        var archived = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(range)) as? [String: Any])
        archived["version"] = range.version + 1
        let older = try JSONDecoder().decode(FoodKeeperReviewedRange.self, from: JSONSerialization.data(withJSONObject: archived))
        let changedEdition = PantryFoodKeeperSelection(lotID: lot.id, revision: lot.revision, range: older)
        XCTAssertNil(PantryVoiceDateEvidence.currentRange(changedEdition, for: lot, today: after, reference: reference))
        let changedBatch = PantryFoodKeeperSelection(lotID: lot.id, revision: lot.revision + 1, range: range)
        XCTAssertNil(PantryVoiceDateEvidence.currentRange(changedBatch, for: lot, today: after, reference: reference))
        let printed = try MealDay(year: 2027, month: 1, day: 16, timeZoneIdentifier: "Pacific/Kiritimati")
        XCTAssertEqual(PantryVoiceDateEvidence.formatted(printed, locale: Locale(identifier: "en_US")), "January 16, 2027")
        XCTAssertTrue(PantryVoiceDateEvidence.formatted(printed, locale: Locale(identifier: "es_US")).contains("16"))
        try await f.database.close()
    }
}
