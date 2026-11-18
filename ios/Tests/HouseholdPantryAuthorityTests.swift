import XCTest
import HouseholdClient
@testable import RoomInTheCart

private func pantryFixture<T: Decodable>(_ object: Any) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}
private actor PantryTestService: HouseholdPantryServing {
    let session: HouseholdPantrySession
    var grantEpoch = 1
    var losesResponse = false
    var sent: [HouseholdPantryIntent] = []
    var accessDenied = false
    var failsRefreshAfterReceipt = false
    var paged = false
    let initialObservation = UUID()
    var countedLot: UUID?
    var latestCorrection: (id: UUID, count: HouseholdPantryCountCorrection)?
    var correctionReceipts: [UUID: HouseholdPantryReceipt] = [:]
    func enableCorrections() { countedLot = UUID() }
    func lotID(_ n: Int) -> String { String(format: "30000000-0000-4000-8000-%012d", n) }
    let adultID = UUID()
    var adultEnabled = false
    var adultEpoch = 0
    var grantReadCount = 0
    init() throws {
        session = try pantryFixture(["householdID": UUID().uuidString, "memberID": UUID().uuidString, "deviceID": UUID().uuidString])
    }
    func setLoss(_ loss: Bool) { losesResponse = loss }
    func revokeAndRegrant() { grantEpoch += 2 }
    func enablePagination() { paged = true }
    func failRefreshAfterReceipt() { failsRefreshAfterReceipt = true }
    func deny() { accessDenied = true }

    func householdPantrySession(for bootstrap: HouseholdBootstrap) throws -> HouseholdPantrySession { session }
    func householdPantryPage(for session: HouseholdPantrySession, after previous: HouseholdPantryPage?) throws -> HouseholdPantryPage {
        guard !accessDenied else { throw ClientError.service(status: 404, code: "unavailable", correlationID: nil, retryAfter: nil) }
        if failsRefreshAfterReceipt && !sent.isEmpty { throw ClientError.transport }
        let range = previous == nil ? 1...50 : 51...51
        var lots: [[String: Any]] = paged ? range.map { n in
            ["lotId": lotID(n), "origin": "manual", "foodName": "Food \(n)", "location": "fridge", "storedAt": NSNull(),
             "useFirstAt": NSNull(), "exclusionTags": [], "observation": NSNull()]
        } : []
        if let countedLot {
            let amount: Any
            if let latestCorrection {
                amount = try JSONSerialization.jsonObject(with: JSONEncoder().encode(latestCorrection.count.quantity), options: .fragmentsAllowed)
            } else {
                amount = ["amount": ["numerator": 2, "denominator": 1], "unit": "count", "originalLiteral": "2"]
            }
            lots = [["lotId": countedLot.uuidString, "origin": "manual", "foodName": "Limes", "location": "fridge",
                     "exclusionTags": [], "observation": ["observationId": (latestCorrection?.id ?? initialObservation).uuidString,
                     "confirmedAt": "2026-11-17T10:00:00Z", "quantity": amount]]]
        }
        return try pantryFixture(["v": 1, "householdId": session.householdID.uuidString, "grantEpoch": grantEpoch,
            "pantryRevision": sent.isEmpty ? 0 : 1, "asOf": "2026-11-17T10:00:00Z", "lots": lots,
            "nextCursor": paged && previous == nil ? lotID(50) as Any : NSNull()])
    }
    func prepareHouseholdPantryChange(_ body: HouseholdPantryChange, reviewed page: HouseholdPantryPage,
                                        session: HouseholdPantrySession) throws -> HouseholdPantryIntent {
        let kind: String
        switch body {
        case .addition: kind = "pantry.addLot"
        case .correction: kind = "pantry.correctCount"
        }
        return try pantryFixture(["session": JSONSerialization.jsonObject(with: JSONEncoder().encode(session)),
            "expiresAt": "2099-12-31T00:00:00Z", "command": ["v": 1, "kind": kind, "clientKey": UUID().uuidString,
            "replayWindow": UUID().uuidString, "grantEpoch": page.grantEpoch, "pantryRevision": page.pantryRevision,
            "body": JSONSerialization.jsonObject(with: JSONEncoder().encode(body))]])
    }
    func submitHouseholdPantryChange(_ intent: HouseholdPantryIntent, session: HouseholdPantrySession) throws -> HouseholdPantryReceipt {
        sent.append(intent)
        if case .correction(let correction) = intent.change {
            if let receipt = correctionReceipts[intent.id] { return receipt }
            let operation = UUID()
            let receipt: HouseholdPantryReceipt = try pantryFixture(["v": 1, "kind": "pantry.correctCount",
                "householdId": session.householdID.uuidString, "grantEpoch": grantEpoch, "operationId": operation.uuidString,
                "lotId": correction.lotId.uuidString, "pantryRevision": 1])
            latestCorrection = (operation, correction)
            correctionReceipts[intent.id] = receipt
            if losesResponse { throw ClientError.transport }
            return receipt
        }
        if losesResponse { throw ClientError.transport }
        let id = UUID().uuidString
        return try pantryFixture(["v": 1, "kind": "pantry.addLot", "householdId": session.householdID.uuidString,
            "grantEpoch": grantEpoch, "operationId": id, "lotId": id, "pantryRevision": 1])
    }
    func householdPantryGrants(for session: HouseholdPantrySession) throws -> HouseholdPantryGrants {
        grantReadCount += 1
        return try pantryFixture(["v": 1, "adults": [["memberId": adultID.uuidString, "label": "Other adult", "enabled": adultEnabled, "grantEpoch": adultEpoch]]])
    }
    func changeHouseholdPantryGrant(_ adult: HouseholdPantryGrants.Adult, enabled: Bool,
                                   session: HouseholdPantrySession) throws -> HouseholdPantryGrants {
        adultEnabled = enabled
        adultEpoch += 1
        return try householdPantryGrants(for: session)
    }
}

@MainActor final class HouseholdPantryAuthorityTests: XCTestCase {
    private func makeModel(service: PantryTestService, store: HouseholdPantryPendingStore, subject: String = "adult",
                           shop: UUID? = nil, managesGrants: Bool = false, recheck: @escaping () async -> Void = {}) throws -> HouseholdPantryModel {
        let session = service.session
        let runtime = HouseholdPantryRuntime(generation: UUID(), enrollmentRevision: UUID(), subject: subject,
            householdID: session.householdID.uuidString, memberID: session.memberID.uuidString, managesGrants: managesGrants)
        var data: [String:Any] = ["household": ["id": runtime.householdID, "label": "Home"], "memberId": runtime.memberID,
            "role": "contributor", "enrolled": true, "queueConsent": false, "capabilities": ["household_pantry"]]
        if let shop { data["shopId"] = shop.uuidString }
        let projection: HouseholdBootstrap = try pantryFixture(data)
        return .init(scope: runtime, service: service, store: store, projection: { projection }, recheckAccess: recheck)
    }
    private func temporaryURL() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("pantry.json")
    }
    private func loseReply(service: PantryTestService, store: HouseholdPantryPendingStore) async throws -> HouseholdPantryIntent {
        let model = try makeModel(service: service, store: store)
        await service.setLoss(true)
        await model.load()
        let page = try XCTUnwrap(model.page)
        var draft = HouseholdPantryDraft()
        draft.name = "Beans"
        draft.location = .fridge
        let addition = try draft.review()
        let before = await service.sent
        XCTAssertTrue(before.isEmpty)
        await model.confirm(addition, reviewed: page)
        model.dismiss()
        let records = try await store.read()
        return try XCTUnwrap(records.first?.intent)
    }
    func testLostReplyRestoresExactAdditionAcrossRelaunchAndShopChange() async throws {
        let service = try PantryTestService(), url = temporaryURL()
        let intent = try await loseReply(service: service, store: .init(url: url))
        let recoveredStore = HouseholdPantryPendingStore(url: url)
        let restored = try makeModel(service: service, store: recoveredStore, shop: UUID())
        await restored.load()
        XCTAssertEqual(restored.pending?.intent, intent)
        let beforeRetry = await service.sent
        XCTAssertEqual(beforeRetry, [intent])
        await service.setLoss(false)
        await restored.retry()
        let sent = await service.sent, remaining = try await recoveredStore.read()
        XCTAssertEqual(sent, [intent, intent])
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertNil(restored.pending)
    }
    func testChangedSubjectAndChangedGrantCannotRevealOrRetryPendingAddition() async throws {
        let service = try PantryTestService(), store = HouseholdPantryPendingStore(url: temporaryURL())
        let intent = try await loseReply(service: service, store: store)
        let wrongSubject = try makeModel(service: service, store: store, subject: "other")
        await wrongSubject.load()
        XCTAssertNil(wrongSubject.pending)
        await wrongSubject.retry()
        let stillSaved = try await store.read()
        XCTAssertEqual(stillSaved.first?.intent, intent)
        await service.revokeAndRegrant()
        let regranted = try makeModel(service: service, store: store)
        await regranted.load()
        await regranted.retry()
        XCTAssertNil(regranted.pending)
        let remaining = try await store.read(), sent = await service.sent
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(sent, [intent])
    }
    func testPurgedRetryCannotSendAndDeniedReadHidesAllFacts() async throws {
        let service = try PantryTestService(), store = HouseholdPantryPendingStore(url: temporaryURL())
        let intent = try await loseReply(service: service, store: store)
        var rechecked = false
        let model = try makeModel(service: service, store: store, recheck: { rechecked = true })
        await model.load()
        XCTAssertNotNil(model.pending)
        try await store.purge()
        await model.retry()
        let sent = await service.sent
        XCTAssertEqual(sent, [intent])
        await service.deny()
        await model.load()
        XCTAssertTrue(rechecked)
        XCTAssertNil(model.page)
        XCTAssertNil(model.pending)
        XCTAssertTrue(model.lots.isEmpty)
    }
    func testReceivedAdditionSurvivesRefreshFailureWithoutASecondCommand() async throws {
        let service = try PantryTestService(), store = HouseholdPantryPendingStore(url: temporaryURL())
        let model = try makeModel(service: service, store: store)
        await model.load()
        await service.failRefreshAfterReceipt()
        let reviewed = try XCTUnwrap(model.page)
        var draft = HouseholdPantryDraft()
        draft.name = "Corn"
        await model.confirm(try draft.review(), reviewed: reviewed)
        XCTAssertEqual(model.notice, householdPantryText("Food added. Reload to see the updated stock."))
        XCTAssertNil(model.pending)
        XCTAssertNil(model.page)
        await model.retry()
        let saved = try await store.read(), sent = await service.sent
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(sent.count, 1)
    }

    func testAccessDenialPurgesRecoveredCommandWhileTransientLossPreservesIt() async throws {
        let service = try PantryTestService(), store = HouseholdPantryPendingStore(url: temporaryURL())
        _ = try await loseReply(service: service, store: store)
        await service.deny()
        let reopened = try makeModel(service: service, store: store)
        await reopened.load()
        let records = try await store.read()
        XCTAssertTrue(records.isEmpty)
        XCTAssertNil(reopened.pending)
        XCTAssertNil(reopened.page)
    }

    func testFirstAndNextPageAndOrganizerGrantManagementWithoutShop() async throws {
        let service = try PantryTestService(), store = HouseholdPantryPendingStore(url: temporaryURL())
        await service.enablePagination()
        let editor = try makeModel(service: service, store: store)
        await editor.load()
        XCTAssertEqual(editor.lots.count, 50)
        XCTAssertEqual(editor.lots.last?.foodName, "Food 50")
        await editor.loadMore()
        XCTAssertEqual(editor.lots.map(\.foodName), (1...51).map { "Food \($0)" })
        XCTAssertNil(editor.page?.nextCursor)
        await editor.loadGrants()
        let unauthorizedReads = await service.grantReadCount
        XCTAssertEqual(unauthorizedReads, 0)

        let organizer = try makeModel(service: service, store: store, managesGrants: true)
        await organizer.load()
        await organizer.loadGrants()
        let before = try XCTUnwrap(organizer.grants?.adults.first)
        XCTAssertFalse(before.enabled)
        await organizer.changeGrant(before)
        let granted = try XCTUnwrap(organizer.grants?.adults.first)
        XCTAssertTrue(granted.enabled)
        await organizer.changeGrant(granted)
        XCTAssertEqual(organizer.grants?.adults.first?.enabled, false)
    }

    func testReopenCorrectedCountAndRecoverLostReceiptWithOneStoredIntent() async throws {
        let service = try PantryTestService(), url = temporaryURL()
        await service.enableCorrections()
        let first = try makeModel(service: service, store: .init(url: url))
        await first.load()
        let page = try XCTUnwrap(first.page), lot = try XCTUnwrap(first.lots.first)
        XCTAssertEqual(lot.observation?.quantity?.amount.numerator, 2)
        let zero = SharedMealQuantity(amount: .init(numerator: 0, denominator: 1), unit: "count", originalLiteral: "0")
        let correction = try HouseholdPantryCountCorrection(lot: lot, confirmedAt: "2026-11-17T11:00:00Z", quantity: zero)
        await service.setLoss(true)
        await first.confirmChange(.correction(correction), reviewed: page)
        first.dismiss()
        let recovered = try makeModel(service: service, store: .init(url: url))
        await recovered.load()
        XCTAssertEqual(recovered.lots.map(\.id), [lot.id])
        XCTAssertEqual(recovered.lots.first?.observation?.quantity, zero)
        let pending = try XCTUnwrap(recovered.pending?.intent)
        XCTAssertEqual(pending.change, .correction(correction))
        await service.setLoss(false)
        await recovered.retry()
        XCTAssertNil(recovered.pending)
        XCTAssertEqual(recovered.lots.first?.observation?.quantity, zero)
        let receipts = await service.correctionReceipts, sent = await service.sent
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(sent, [pending, pending])
    }

    func testExplicitZeroUnknownAndFractionReview() throws {
        var draft = HouseholdPantryDraft()
        draft.name = " Arroz "
        draft.location = .fridge
        XCTAssertNil(try draft.review().quantity)
        draft.literal = "0"
        XCTAssertEqual(try draft.review().quantity?.amount.numerator, 0)
        draft.literal = "1,5"
        draft.unit = .kilogram
        let value = try draft.review()
        XCTAssertEqual(value.foodName, "Arroz")
        XCTAssertEqual(value.location, .fridge)
        XCTAssertEqual(value.quantity, .init(amount: .init(numerator: 3, denominator: 2), unit: "kilogram", originalLiteral: "1,5"))
        draft.literal = "-1"
        XCTAssertThrowsError(try draft.review())
    }
}
