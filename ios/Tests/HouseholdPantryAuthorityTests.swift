import XCTest
import HouseholdClient
@testable import RoomInTheCart

private func pantryFixture<T: Decodable>(_ object: Any) throws -> T {
    try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
}
private actor PantryTestService: HouseholdPantryServing {
    let session: HouseholdPantrySession
    var grantEpoch = 1
    var preparationError: ClientError?
    var dropsRequest = false
    var rejectsReceiptLayout = false
    var losesResponse = false
    var sent: [HouseholdPantryIntent] = []
    var accessDenied = false
    var failsRefreshAfterReceipt = false
    var paged = false
    let initialObservation = UUID()
    var countedLot: UUID?
    var latestCorrection: (id: UUID, count: HouseholdPantryCountCorrection)?
    var acquired: [UUID: HouseholdPantryReceipt] = [:]
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
    func failPreparation(with error: ClientError?) { preparationError = error }
    func dropRequest(_ drop: Bool) { dropsRequest = drop }
    func rejectReceiptLayout() { rejectsReceiptLayout = true }
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
        if let preparationError { throw preparationError }
        let kind: String
        switch body {
        case .addition: kind = "pantry.addLot"
        case .receipt: kind = "pantry.acquireReceipt"
        case .correction: kind = "pantry.correctCount"
        }
        return try pantryFixture(["session": JSONSerialization.jsonObject(with: JSONEncoder().encode(session)),
            "expiresAt": "2099-12-31T00:00:00Z", "command": ["v": 1, "kind": kind, "clientKey": UUID().uuidString,
            "replayWindow": UUID().uuidString, "grantEpoch": page.grantEpoch, "pantryRevision": page.pantryRevision,
            "body": JSONSerialization.jsonObject(with: JSONEncoder().encode(body))]])
    }
    func submitHouseholdPantryChange(_ intent: HouseholdPantryIntent, session: HouseholdPantrySession) throws -> HouseholdPantryReceipt {
        sent.append(intent)
        if dropsRequest { throw ClientError.transport }
        if case .receipt(let value) = intent.change {
            if rejectsReceiptLayout { throw ClientError.service(status: 409, code: "receipt_layout_review", correlationID: nil, retryAfter: nil) }
            if let previous = acquired[intent.id] { return previous }
            let rows = value.lines.map { ["ordinal": $0.ordinal, "lotId": UUID().uuidString] as [String: Any] }
            let result: HouseholdPantryReceipt = try pantryFixture(["v": 1, "kind": "pantry.acquireReceipt",
                "householdId": session.householdID.uuidString, "grantEpoch": grantEpoch, "operationId": UUID().uuidString,
                "receiptId": value.receiptId.uuidString, "receiptLines": rows, "savedCount": rows.count, "pantryRevision": 1])
            acquired[intent.id] = result
            if losesResponse { throw ClientError.transport }
            return result
        }
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
    func householdStaples(for session: HouseholdPantrySession, zone: String) throws -> HouseholdStaplePage { throw ClientError.configuration }
    func changeHouseholdStaples(_ action: HouseholdStapleAction, reviewed: HouseholdStaplePage, session: HouseholdPantrySession) throws -> HouseholdStaplePage { throw ClientError.configuration }
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
                           shop: UUID? = nil, managesGrants: Bool = false, isCurrent: @escaping () -> Bool = { true }, recheck: @escaping () async -> Void = {}) throws -> HouseholdPantryModel {
        let session = service.session
        let runtime = HouseholdPantryRuntime(generation: UUID(), enrollmentRevision: UUID(), subject: subject,
            householdID: session.householdID.uuidString, memberID: session.memberID.uuidString, managesGrants: managesGrants)
        var data: [String:Any] = ["household": ["id": runtime.householdID, "label": "Home"], "memberId": runtime.memberID,
            "role": "contributor", "enrolled": true, "queueConsent": false, "capabilities": ["household_pantry"]]
        if let shop { data["shopId"] = shop.uuidString }
        let projection: HouseholdBootstrap = try pantryFixture(data)
        return .init(scope: runtime, service: service, store: store, projection: { isCurrent() ? projection : nil }, recheckAccess: recheck)
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

    func testSelectedSharedReceiptSurvivesLostReplyAndRestoresOnlyTheAuthorizedScope() async throws {
        let service = try PantryTestService(), url = temporaryURL()
        let store = HouseholdPantryPendingStore(url: url)
        let first = try makeModel(service: service, store: store)
        await first.load()
        let page = try XCTUnwrap(first.page)
        let doc = try await ReceiptDocumentReader().extract(.init(data: Data("BEANS\nFEE\nPERAS".utf8), kind: .text))
        let target = CaptureTarget(workspaceID: page.householdId, containerID: UUID(), objectID: UUID(), revision: 0, kind: .receiptEvidence)
        let source = try doc.source(target: target, merchant: "Mercado", stage: .receipt,
            selection: Set((1...3).map { .init(page: 1, line: $0) }), at: Date())
        var draft = try ReceiptImportDraft(source: source, locale: Locale(identifier: "en_US"))
        XCTAssertThrowsError(try draft.householdReceipt(for: page, deliveries: []))
        draft.dateConfirmed = true
        for index in [0, 2] {
            draft.lines[index].treatment = .add; draft.lines[index].received = "2"; draft.lines[index].usable = index == 0 ? "1" : "0"
        }
        draft.lines[0].paid = "4.10"
        draft.selectedPurchaseDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: draft.purchaseDate))
        XCTAssertFalse(draft.dateConfirmed)
        XCTAssertThrowsError(try draft.householdReceipt(for: page, deliveries: []))
        draft.dateConfirmed = true
        let reviewed = try draft.householdReceipt(for: page, deliveries: [])
        var pesoReceipt = draft
        pesoReceipt.changeCurrency(.mxn)
        XCTAssertEqual(pesoReceipt.currency, .usd)
        pesoReceipt.lines[0].paid = ""
        pesoReceipt.changeCurrency(.mxn)
        XCTAssertEqual(pesoReceipt.currency, .mxn)
        pesoReceipt.lines[0].paid = "4.10"
        let reviewedPesoReceipt = try pesoReceipt.householdReceipt(for: page, deliveries: [])
        XCTAssertEqual(reviewedPesoReceipt.currency, "MXN")
        XCTAssertEqual(reviewedPesoReceipt.lines.map(\.paidMinor), [410, nil])
        pesoReceipt.lines[0].paid = ""
        let quantitiesOnly = try pesoReceipt.householdReceipt(for: page, deliveries: [])
        XCTAssertTrue(quantitiesOnly.lines.allSatisfy { $0.paidMinor == nil })
        XCTAssertEqual(quantitiesOnly.lines.map(\.received), reviewed.lines.map(\.received))
        var identified = draft
        identified.reference = "Transaction 123"
        let withReference = try identified.householdReceipt(for: page, deliveries: [])
        XCTAssertNotEqual(reviewed.receiptId, withReference.receiptId)
        XCTAssertNotNil(reviewed.layoutId)
        XCTAssertEqual(reviewed.layoutId, withReference.layoutId)
        XCTAssertEqual(reviewed.lines.map(\.ordinal), [0, 2])
        XCTAssertEqual(reviewed.currency, "USD")
        XCTAssertEqual(reviewed.lines.map(\.paidMinor), [410, nil])
        XCTAssertEqual(reviewed.lines.map(\.original), ["BEANS", "PERAS"])
        await service.failPreparation(with: .transport)
        let offline = await first.confirmChange(.receipt(reviewed), reviewed: page)
        XCTAssertEqual(offline, .retryPreparation)
        XCTAssertTrue(first.permitsReceiptReview(page))
        let beforeSave = try await store.read(), beforeSend = await service.sent
        XCTAssertTrue(beforeSave.isEmpty)
        XCTAssertTrue(beforeSend.isEmpty)

        await service.failPreparation(with: nil)
        await service.setLoss(true)
        let ambiguous = await first.confirmChange(.receipt(reviewed), reviewed: page)
        XCTAssertEqual(ambiguous, .savedForSubmission)
        first.dismiss()
        let unrelated = try makeModel(service: service, store: .init(url: url), subject: "Other profile")
        await unrelated.load()
        XCTAssertNil(unrelated.pending)
        let resumed = try makeModel(service: service, store: .init(url: url))
        await resumed.load()
        let intent = try XCTUnwrap(resumed.pending?.intent)
        XCTAssertEqual(intent.change, .receipt(reviewed))
        await service.setLoss(false)
        await resumed.retry()
        let sent = await service.sent, acquired = await service.acquired
        XCTAssertEqual(sent, [intent, intent]); XCTAssertEqual(acquired.count, 1)
        XCTAssertNil(resumed.pending)
    }

    func testSegmentedReceiptNeedsPrintedIdentityEvenWhenSelectingOnlyItsFirstLine() async throws {
        let service = try PantryTestService(), store = HouseholdPantryPendingStore(url: temporaryURL())
        let model = try makeModel(service: service, store: store)
        await model.load()
        let page = try XCTUnwrap(model.page)
        let target = CaptureTarget(workspaceID: page.householdId, containerID: UUID(), objectID: UUID(), revision: 0, kind: .receiptEvidence)
        func photo(_ byte: UInt8) -> ExtractedReceiptDocument {
            .init(digest: Data(repeating: byte, count: 32), pages: [.init(id: 1, method: .imageOCR, lines: [.init(id: 1, text: "YOGUR")])])
        }
        var sections = ReceiptSectionDraft()
        func make(_ reference: String?) throws -> HouseholdReceiptAcquisition {
            let source = try sections.review().document.source(target: target, merchant: "Mercado Café", stage: .receipt,
                selection: [.init(page: 1, line: 1)], at: Date())
            var draft = try ReceiptImportDraft(source: source)
            draft.reference = reference ?? ""; draft.dateConfirmed = true
            draft.lines[0].treatment = .add; draft.lines[0].received = "1"; draft.lines[0].usable = "1"
            return try draft.householdReceipt(for: page, deliveries: [])
        }
        try sections.put(photo(1), bytes: 100, preview: nil, at: 0)
        let single = try make(nil)
        XCTAssertNil(single.segmentedPhotos)
        try sections.put(photo(2), bytes: 100, preview: nil, at: 1)
        sections.resolve(at: 1, omitting: 0)
        XCTAssertThrowsError(try make(nil))
        let pair = try make("Receipt 724")
        XCTAssertEqual(pair.receiptId.uuidString.lowercased(), "05e32c0b-b8cf-87cb-bda7-d6a70f780aa7")
        XCTAssertEqual(pair.segmentedPhotos, true)
        XCTAssertEqual(pair.imageId, single.imageId)
        XCTAssertNotEqual(pair.layoutId, single.layoutId)
        for (position, photoID) in [(2, UInt8(3)), (1, 4), (0, 5)] {
            try sections.put(photo(photoID), bytes: 100, preview: nil, at: position)
            sections.resolve(at: 1, omitting: 0); sections.resolve(at: 2, omitting: 0)
            XCTAssertThrowsError(try make(" "))
            let revised = try make("Receipt 724")
            XCTAssertEqual(revised.receiptId, pair.receiptId)
            XCTAssertNotEqual(revised.layoutId, pair.layoutId)
            XCTAssertNotEqual(try make("Receipt 725").receiptId, pair.receiptId)
        }
    }

    func testReceiptLayoutUsesOnlyScopedIdentityAndRejectedCopyClearsOnlyItsPendingSubmission() async throws {
        let service = try PantryTestService(), store = HouseholdPantryPendingStore(url: temporaryURL())
        let model = try makeModel(service: service, store: store)
        await model.load()
        let page = try XCTUnwrap(model.page)
        func typed(_ words: [String], reference: String) throws -> HouseholdReceiptAcquisition {
            let target = CaptureTarget(workspaceID: page.householdId, containerID: UUID(), objectID: UUID(),
                                       revision: 0, kind: .receiptEvidence)
            let source = SourceMediaRecord(id: UUID(), target: target, originalText: words.joined(separator: "\n"),
                reviewedLabel: "Market", imageJPEG: nil, barcode: nil,
                receiptLines: words.map { ScanReceiptLine(originalText: $0) }, capturedAt: Date())
            var draft = try ReceiptImportDraft(source: source)
            draft.reference = reference
            draft.dateConfirmed = true
            let index = try XCTUnwrap(words.firstIndex(of: "OATS"))
            draft.lines[index].treatment = .add
            draft.lines[index].received = "2"
            draft.lines[index].usable = "2"
            return try draft.householdReceipt(for: page, deliveries: [])
        }
        let strings = ["OATS", "Skipped private wording"]
        let first = try typed(strings, reference: "123")
        XCTAssertNotNil(first.layoutId)
        XCTAssertEqual(first.layoutId, try typed(strings, reference: "123").layoutId)
        XCTAssertNotEqual(first.layoutId, try typed(strings.reversed(), reference: "123").layoutId)
        XCTAssertNotEqual(first.layoutId, try typed(strings, reference: "456").layoutId)
        XCTAssertNotEqual(try typed(strings, reference: "").layoutId, try typed(strings, reference: "").layoutId)
        let body = try JSONEncoder().encode(first)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("Skipped private wording"))
        await service.rejectReceiptLayout()
        let result = await model.confirmChange(.receipt(first), reviewed: page)
        XCTAssertEqual(result, .receiptNeedsReview)
        XCTAssertEqual(model.rejectedReceipt, first)
        let duplicate = await model.confirmChange(.receipt(first), reviewed: page)
        XCTAssertEqual(duplicate, .receiptNeedsReview)
        XCTAssertEqual(model.page, page)
        XCTAssertNil(model.pending)
        let remaining = try await store.read()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(model.notice?.contains("original file") == true)
        await model.retry()
        let sent = await service.sent
        XCTAssertEqual(sent.count, 1)

        // A rejected retry restored after interruption keeps every reviewed field until the
        // adult explicitly clears it. No new command can send a read-only record.
        model.dismiss()
        let uncertain = try makeModel(service: service, store: store)
        await uncertain.load()
        let current = try XCTUnwrap(uncertain.page)
        await service.dropRequest(true)
        let interrupted = await uncertain.confirmChange(.receipt(first), reviewed: current)
        XCTAssertEqual(interrupted, .savedForSubmission)
        uncertain.dismiss()
        await service.dropRequest(false)
        let restored = try makeModel(service: service, store: store)
        await restored.load()
        await restored.retry()
        XCTAssertEqual(restored.pending?.reviewOnly, true)
        XCTAssertEqual(restored.pending?.intent.change, .receipt(first))
        restored.dismiss()
        let other = try makeModel(service: service, store: store, subject: "Another adult")
        await other.load()
        XCTAssertNil(other.pending)
        let readOnly = try makeModel(service: service, store: store)
        await readOnly.load()
        XCTAssertEqual(readOnly.pending?.reviewOnly, true)
        await readOnly.retry()
        let allSends = await service.sent
        XCTAssertEqual(allSends.count, 3)
        await readOnly.clearReviewedRetry()
        let cleared = try await store.read()
        XCTAssertTrue(cleared.isEmpty)
    }

    func testPreparationRetryEndsWithTheHouseholdScopeOrAccess() async throws {
        let service = try PantryTestService(), store = HouseholdPantryPendingStore(url: temporaryURL())
        var isCurrent = true, rechecked = false
        let model = try makeModel(service: service, store: store, isCurrent: { isCurrent }, recheck: { rechecked = true })
        await model.load()
        let page = try XCTUnwrap(model.page)
        var draft = HouseholdPantryDraft()
        draft.name = "Beans"
        let change = HouseholdPantryChange.addition(try draft.review())
        await service.failPreparation(with: .service(status: 503, code: "service_unavailable", correlationID: nil, retryAfter: nil))
        let unavailable = await model.confirmChange(change, reviewed: page)
        XCTAssertEqual(unavailable, .retryPreparation)

        isCurrent = false
        XCTAssertFalse(model.permitsReceiptReview(page))
        let switched = await model.confirmChange(change, reviewed: page)
        XCTAssertEqual(switched, .unavailable)
        isCurrent = true
        await service.failPreparation(with: .accessEnded)
        let denied = await model.confirmChange(change, reviewed: page)
        XCTAssertEqual(denied, .unavailable)
        XCTAssertTrue(rechecked)
        XCTAssertNil(model.page)
        XCTAssertFalse(model.permitsReceiptReview(page))
        let entries = try await store.read(), sent = await service.sent
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(sent.isEmpty)
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
