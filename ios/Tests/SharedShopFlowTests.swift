import XCTest
import HouseholdClient
@testable import RoomInTheCart

@MainActor final class SharedShopFlowTests: XCTestCase {
    private func model(_ actor: String, fixture: SharedFlowService, queue: URL? = nil) async throws -> HouseholdModel {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SharedFlowURLProtocol.self]
        let transport = HTTPTransport(session: URLSession(configuration: config))
        let auth = AdultAuth(configuration: try .init(projectURL: URL(string: "https://identity.test")!, publishableKey: "sb_publishable_test"), vault: SharedFlowVault(), transport: transport)
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://household.test")!), auth: auth, deviceVault: SharedFlowVault(), transport: transport)
        SharedFlowURLProtocol.handler = fixture.respond
        let model = HouseholdModel(auth: auth, service: service, outboxURL: queue ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("outbox.json"))
        model.email = actor + "@example.test"; model.code = "123456"; await model.verifyCode()
        XCTAssertNotNil(model.identity); return model
    }
    private func createdHousehold(_ fixture: SharedFlowService, queue: URL? = nil) async throws -> HouseholdModel {
        let model = try await model("mia", fixture: fixture, queue: queue)
        let lifecycle = try XCTUnwrap(model.lifecycle)
        lifecycle.householdLabel = "Our home"; lifecycle.alias = "Mia"; lifecycle.adultAttestation = true; lifecycle.keepLocalPrivate = true
        await lifecycle.createHousehold()
        XCTAssertEqual(model.projection?.role, "organizer"); XCTAssertNil(model.projection?.shopId)
        XCTAssertEqual(fixture.householdCreates, 1); return model
    }
    private func enterShop(_ model: HouseholdShopModel) {
        model.beginEditing()
        model.draft.lines = [.init(item: "Original basket", price: "37.20")]
        model.draft.complete = true; model.draft.cap = "38.00"
        model.draft.fee = "0"; model.draft.tax = "0"; model.draft.deposits = "0"; model.draft.discounts = "0"
        model.reviewDraft(); model.acknowledged = true
    }
    func testFreshHouseholdNativeFlowCreatesInvitesReceivesApprovesFreezesAndReopens() async throws {
        let fixture = SharedFlowService(); let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop); XCTAssertTrue(shared.canCreate)
        enterShop(shared); await shared.applyReviewed()
        XCTAssertEqual(mia.projection?.role, "shopper"); XCTAssertEqual(shared.shop?.lines.count, 1)
        XCTAssertFalse(shared.canCreate); XCTAssertNotNil(mia.shopperInbox)
        let people = try XCTUnwrap(mia.lifecycle); await people.createAdultInvitation()
        let invitation = try XCTUnwrap(people.issued)
        let sam = try await model("sam", fixture: fixture); let join = try XCTUnwrap(sam.lifecycle)
        join.alias = "Sam"; join.invitationCode = invitation.token; join.adultAttestation = true; join.keepLocalPrivate = true
        await join.redeemInvitation()
        XCTAssertEqual(sam.projection?.role, "contributor"); XCTAssertNil(sam.sharedShop); XCTAssertNil(sam.shopperInbox)
        sam.item = "Cereal"; sam.quantity = "one box"; await sam.sendRequest()
        let inbox = try XCTUnwrap(mia.shopperInbox); await inbox.load()
        XCTAssertEqual(inbox.requests.first?.authorAlias, "Sam")
        inbox.select(try XCTUnwrap(inbox.requests.first)); inbox.choice = .add; inbox.price = "3.49"; await inbox.review()
        XCTAssertEqual(inbox.preview?.after.totalMinor, 4069); XCTAssertEqual(inbox.preview?.after.overCapMinor, 269)
        XCTAssertFalse(inbox.canApply); inbox.acceptOverage = true; await inbox.apply()
        XCTAssertEqual(inbox.shop?.lines.count, 2)
        await shared.load(); shared.reviewPhaseChange("shop.freeze"); shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertEqual(shared.shop?.phase, "frozen")
        sam.item = "Milk"; sam.quantity = "one carton"; await sam.sendRequest()
        XCTAssertEqual(sam.requests.first { $0.originalItem == "Milk" }?.route, "next")
        shared.reviewPhaseChange("shop.reopen"); shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertEqual(shared.shop?.phase, "draft"); XCTAssertEqual(shared.shop?.lines.count, 2)
        await inbox.load(); let late = try XCTUnwrap(inbox.requests.first { $0.originalItem == "Milk" })
        XCTAssertEqual(late.route, "next")
        inbox.select(late); inbox.choice = .add; inbox.price = "2.00"; inbox.promote = true
        await inbox.review(); inbox.acceptOverage = true; await inbox.apply()
        XCTAssertEqual(inbox.shop?.lines.count, 3)
        XCTAssertEqual(fixture.sharedShopCreates, 1)
        XCTAssertEqual(fixture.kinds.filter { $0 == "shop.freeze" }.count, 1)
        XCTAssertEqual(fixture.kinds.filter { $0 == "shop.reopen" }.count, 1)
        XCTAssertEqual(fixture.privateReads, 0)
    }
    func testNewSharedShopStartsWithoutThePreviousStoresReviewOrPrices() async throws {
        let fixture = SharedFlowService()
        let adult = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(adult.sharedShop)
        enterShop(shared)
        await shared.applyReviewed()
        let previousID = try XCTUnwrap(shared.shop?.shopId)

        fixture.canSelectShop = true
        fixture.storeBasisRevision = 7
        await shared.load()
        shared.beginEditing()
        shared.reviewDraft()
        XCTAssertEqual(shared.review?.candidate?.reviewedStoreBasisRevision, 7)
        shared.cancelEditing()

        shared.beginAnotherShop()
        XCTAssertTrue(shared.draft.lines.isEmpty)
        XCTAssertTrue(shared.draft.cap.isEmpty)
        shared.draft.lines = [.init(item: "Coffee at the market", price: "3.10")]
        shared.reviewDraft()
        let review = try XCTUnwrap(shared.review)
        XCTAssertEqual(review.kind, "shop.create")
        XCTAssertNotEqual(review.shopID, previousID)
        let candidate = try XCTUnwrap(review.candidate)
        XCTAssertNil(try candidate.commandBody()["reviewedStoreBasisRevision"])
        XCTAssertEqual(candidate.lines.map(\.unitPriceMinor), [310])
        shared.acknowledged = true
        await shared.applyReviewed()
        XCTAssertEqual(fixture.sharedShopCreates, 2)
        XCTAssertEqual(shared.shop?.shopId, review.shopID)
    }
    func testFallbackLibrarySurvivesBillingOutageAndClosesOnShopperTransferDuringSeatCheck() async throws {
        let fixture = SharedFlowService()
        let adult = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(adult.sharedShop)
        enterShop(shared)
        await shared.applyReviewed()
        let id = try XCTUnwrap(fixture.shopID.flatMap(UUID.init(uuidString:)))
        let service = try XCTUnwrap(adult.service)
        let library = SharedFallbackModel(shopID: id, service: service, store: adult.fallbackPendingStore, authorized: { true })
        fixture.fallbackBillingUnavailable = true
        await library.load()
        XCTAssertEqual(library.library?.shopId, id)
        XCTAssertFalse(library.canSuggest)
        XCTAssertEqual(library.notice, fallbackText("Couldn’t check membership. Refresh to try again."))
        fixture.transferAfterLibraryRead = true
        await library.load()
        XCTAssertNil(library.library)
        XCTAssertNil(library.pending)
        XCTAssertFalse(library.canSuggest)
    }
    func testShopDraftRequiresExplicitReviewAndEditsInvalidateIt() async throws {
        let fixture = SharedFlowService(); let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop)
        shared.beginEditing(); XCTAssertTrue(shared.draft.lines.isEmpty); XCTAssertFalse(shared.draft.complete)
        XCTAssertEqual(shared.draft.tax, ""); XCTAssertEqual(shared.draft.fee, "")
        await shared.applyReviewed(); XCTAssertEqual(fixture.sharedShopCreates, 0)
        enterShop(shared); shared.acknowledged = false; await shared.applyReviewed(); XCTAssertEqual(fixture.sharedShopCreates, 0)
        shared.acknowledged = true; shared.draft.lines[0].price = "39.20"
        XCTAssertNil(shared.review); XCTAssertFalse(shared.acknowledged)
        await shared.applyReviewed(); XCTAssertEqual(fixture.sharedShopCreates, 0)
        shared.reviewDraft(); shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertEqual(shared.shop?.lines.first?.unitPriceMinor, 3920)
        shared.beginEditing(); shared.draft.tax = "1.25"; shared.reviewDraft(); shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertEqual(shared.shop?.quote.taxesMinor, 125); XCTAssertEqual(shared.shop?.shopRevision, 2)
    }
    func testSharedMealReviewBindsPacksDateAndRevisionAndRejectsAStaleEditor() async throws {
        let fixture = SharedFlowService()
        let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop)
        enterShop(shared); await shared.applyReviewed()
        let occurrenceID = UUID()
        let meal = SharedMeal(title: "Chickpea dinner", day: "2026-11-05", kind: "dinner", portions: 3, protected: false)
        shared.beginEditing()
        shared.draft.mealEdit = SharedMealEdit(occurrenceID: occurrenceID, meal: meal)
        shared.draft.lines[0].packs = 2
        shared.reviewDraft()
        XCTAssertEqual(shared.review?.mealEdit?.meal, meal)
        XCTAssertTrue(fixture.meals.isEmpty)
        shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertEqual(shared.shop?.shopRevision, 2)
        XCTAssertEqual(shared.shop?.meals?.first?.meal, meal)
        XCTAssertEqual(shared.shop?.lines.first?.packs, 2)
        shared.beginEditing()
        shared.draft.mealEdit = SharedMealEdit(occurrenceID: occurrenceID, meal: nil)
        shared.reviewDraft()
        fixture.revision += 1
        await shared.load()
        XCTAssertNil(shared.review); XCTAssertFalse(shared.editing)
        shared.reviewDraft(); shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertEqual(fixture.meals.count, 1)
        shared.beginEditing()
        shared.draft.mealEdit = SharedMealEdit(occurrenceID: occurrenceID, meal: nil)
        shared.reviewDraft(); shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertEqual(shared.shop?.meals?.count, 0)
        XCTAssertEqual(shared.shop?.lines.first?.packs, 2)
    }
    func testLostCreateResponseCanRecoverOriginalOperationWithoutSecondShop() async throws {
        let fixture = SharedFlowService(); let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop); enterShop(shared); fixture.loseCreateResponse = true
        await shared.applyReviewed()
        let operation = try XCTUnwrap(shared.pending); XCTAssertEqual(shared.delivery, .waiting)
        fixture.loseCreateResponse = false
        let scope = try XCTUnwrap(mia.projection)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SharedFlowURLProtocol.self]
        let transport = HTTPTransport(session: URLSession(configuration: config))
        let auth = AdultAuth(configuration: try .init(projectURL: URL(string: "https://identity.test")!, publishableKey: "sb_publishable_test"), vault: SharedFlowVault(), transport: transport)
        _ = try await auth.verifyEmailCode(email: "mia@example.test", code: "123456")
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://household.test")!), auth: auth, deviceVault: SharedFlowVault(), transport: transport)
        let fresh = try await service.enroll(householdID: scope.household.id)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("retry.json")
        let outbox = OperationOutbox(url: url); try await outbox.append(operation)
        let restored = HouseholdShopModel(scope: fresh, service: service, outbox: outbox, onConfirmed: {}, onAccessEnded: {})
        await restored.load(); await restored.retry()
        XCTAssertNil(restored.pending); XCTAssertEqual(restored.shop?.lines.count, 1)
        XCTAssertEqual(fixture.sharedShopCreates, 1)
        let creates = fixture.commandBodies.filter { $0.kind == "shop.create" }.map(\.bytes)
        XCTAssertEqual(creates, [operation.bytes, operation.bytes])
    }
    func testConfirmedCreationSurvivesReadFailureAndCannotCreateAnotherShop() async throws {
        for status in [503, 403] {
            let fixture = SharedFlowService(); let mia = try await createdHousehold(fixture)
            let shared = try XCTUnwrap(mia.sharedShop); enterShop(shared); fixture.readFailureAfterCreate = status
            await shared.applyReviewed()
            XCTAssertNil(shared.pending); XCTAssertFalse(shared.canCreate); XCTAssertFalse(shared.canManage)
            if status == 403 { XCTAssertNil(mia.sharedShop); XCTAssertNil(shared.shop); XCTAssertTrue(mia.locked) }
            else {
                if case .confirmed = shared.delivery {} else { XCTFail("Confirmed receipt was lost") }
                fixture.readFailureAfterCreate = nil; await shared.load()
                XCTAssertEqual(shared.shop?.lines.count, 1); XCTAssertFalse(shared.canCreate); XCTAssertTrue(shared.canManage)
            }
        }
    }
    func testFinancialEvidenceStaysWithTheAssignedShopperAndClearsOnTransfer() async throws {
        let fixture = SharedFlowService()
        let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop)
        enterShop(shared)
        await shared.applyReviewed()
        await shared.load()
        XCTAssertNotNil(shared.lastShopSync)
        await shared.loadFinancialEntries()
        let entries = try XCTUnwrap(shared.financialEntries)
        XCTAssertEqual(entries.map(\.kind), [.paymentHold])
        XCTAssertEqual(entries.first?.amountMinor, 3200)
        XCTAssertEqual(entries.first?.sourceText, "Hold on the entered receipt")
        fixture.shopperTransferred = true
        await mia.refresh()
        XCTAssertNil(shared.financialEntries)
        XCTAssertNil(shared.lastShopSync)
        XCTAssertFalse(shared.canManage)
    }

    func testChangedShopperAuthorityClearsPrivateViewsBeforeRequestListFailure() async throws {
        let fixture = SharedFlowService()
        let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop)
        enterShop(shared)
        await shared.applyReviewed()
        XCTAssertTrue(shared.canManage)
        mia.item = "Old shop draft"
        shared.beginEditing()
        XCTAssertFalse(shared.draft.lines.isEmpty)
        fixture.shopperTransferred = true
        fixture.ownRequestsUnavailable = true
        await mia.refresh()
        XCTAssertEqual(mia.projection?.role, "organizer")
        XCTAssertNil(mia.shopperInbox)
        XCTAssertFalse(shared.canManage)
        XCTAssertNil(shared.shop)
        XCTAssertTrue(mia.item.isEmpty)
        XCTAssertTrue(shared.draft.lines.isEmpty)
    }

    func testOrganizerReviewsTransferAndLosesShopperBudgetAfterConfirmation() async throws {
        let fixture = SharedFlowService()
        let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop)
        enterShop(shared); await shared.applyReviewed()
        let id = try XCTUnwrap(fixture.shopID.flatMap(UUID.init(uuidString:)))
        let service = try XCTUnwrap(mia.service)
        let authority = try await service.shopperAssignment(shopID: id)
        let next = try XCTUnwrap(authority.adults.first(where: { $0.id != authority.shopperId }))
        shared.reviewTransfer(authority, to: next.id)
        XCTAssertEqual(shared.review?.transfer?.toLabel, "Alex")
        await shared.applyReviewed(); XCTAssertFalse(fixture.shopperTransferred)
        shared.acknowledged = true; await shared.applyReviewed()
        XCTAssertTrue(fixture.shopperTransferred); XCTAssertFalse(shared.canManage)
        XCTAssertNil(shared.shop); XCTAssertNil(mia.shopperInbox)
        XCTAssertEqual(fixture.kinds.filter { $0 == "shop.transferAuthority" }.count, 1)
    }
    func testLockClearsSharedBudgetAndPreventsRetainedModelFromPublishing() async throws {
        let fixture = SharedFlowService(); let mia = try await createdHousehold(fixture)
        let shared = try XCTUnwrap(mia.sharedShop); enterShop(shared); await shared.applyReviewed()
        shared.beginEditing(); shared.reviewDraft(); shared.acknowledged = true
        mia.lock()
        XCTAssertNil(mia.sharedShop); XCTAssertNil(shared.shop); XCTAssertNil(shared.review); XCTAssertTrue(shared.draft.lines.isEmpty)
        await shared.applyReviewed(); XCTAssertEqual(fixture.kinds.filter { $0 == "shop.patch" }.count, 0)
    }
}

/// HTTP contract fixture: starts with no household or shop. PostgreSQL acceptance is run separately by the service owner.
private final class SharedFlowService {
    let household = UUID().uuidString.lowercased(), miaID = UUID().uuidString.lowercased(), samID = UUID().uuidString.lowercased()
    var householdCreates = 0, sharedShopCreates = 0, privateReads = 0
    var meals: [[String: Any]] = []
    var joined = Set<String>(), shopID: String?, revision = 0, phase = "draft"
    var quote: [String: Any] = [:], lines: [[String: Any]] = [], requests: [[String: Any]] = []
    var kinds: [String] = [], commandBodies: [(kind: String, bytes: Data)] = []
    var receipts: [String: [String: Any]] = [:], previews: [String: [String: Any]] = [:]
    var loseCreateResponse = false
    var shopperTransferred = false
    var fallbackBillingUnavailable = false
    var canSelectShop = false
    var storeBasisRevision: Int?
    var transferAfterLibraryRead = false
    var ownRequestsUnavailable = false
    var readFailureAfterCreate: Int?
    func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data("{}".utf8) }
        stream.open(); defer { stream.close() }; var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let size = stream.read(&buffer, maxLength: buffer.count); if size <= 0 { break }; bytes.append(buffer, count: size) }
        return bytes
    }
    func respond(_ request: URLRequest) throws -> (Int, Data) {
        let path = request.url!.path, actor = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? "mia"
        let input = try body(request); let json = (try? JSONSerialization.jsonObject(with: input) as? [String: Any]) ?? [:]
        func ok(_ value: Any, _ status: Int = 200) throws -> (Int, Data) { (status, try data(value)) }
        if path == "/auth/v1/verify" {
            let name = (json["email"] as! String).components(separatedBy: "@")[0]
            return try ok(["access_token":name,"refresh_token":name+"-refresh","expires_in":3600,"user":["id":name,"email_confirmed_at":"date"]])
        }
        if path == "/auth/v1/user" { return try ok(["id":actor,"email_confirmed_at":"date"]) }
        if path == "/v1/households" { householdCreates += 1; joined.insert(actor); return try ok(["householdId":household,"memberId":miaID,"role":"organizer"],201) }
        if path == "/v1/me/workspaces" { return try ok(["workspaces":joined.contains(actor) ? [["householdId":household,"label":"Our home","role":actor == "mia" ? "organizer" : "contributor"]] : []]) }
        if path == "/v1/invites/redeem" { joined.insert(actor); return try ok(["householdId":household,"memberId":samID,"role":"contributor"]) }
        if path.hasSuffix("/devices") { return try ok(["deviceId":actor+"-device","deviceToken":actor+"-device-token"],201) }
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), actor+"-device-token")
        if path.hasSuffix("/bootstrap") {
            if shopID != nil, let status = readFailureAfterCreate { return try ok(["error":["code":"access_ended","correlationId":"test"]],status) }
            let shopper = actor == "mia" && shopID != nil && !shopperTransferred
            return try ok(["household":["id":household,"label":"Our home"],"memberId":actor == "mia" ? miaID : samID,
                "role":shopper ? "shopper" : actor == "mia" ? "organizer" : "contributor", "canSelectShop":canSelectShop, "shopId":shopID as Any? ?? NSNull(),"enrolled":true,"queueConsent":false,
                "capabilities":["own_requests"] + (actor == "mia" ? ["household_admin"] : []) + (shopper ? ["shopper_inbox","request_preview","shopper_commands","accepted_fallbacks"] : [])])
        }
        if path.hasSuffix("/accepted-fallbacks"), let shopID {
            if transferAfterLibraryRead { shopperTransferred = true }
            return try ok(["shopId":shopID, "shopRevision":revision, "authorityEpoch":1, "registryRevision":0, "candidates":[], "nextCursor":NSNull()])
        }
        if path.hasSuffix("/entitlements"), fallbackBillingUnavailable { return try ok(["error":["code":"service_unavailable"]],503) }
        if path.hasSuffix("/replay-windows") { return try ok(["id":UUID().uuidString.lowercased(),"expiresAt":"2099-01-01T00:00:00Z"]) }
        if path.hasSuffix("/invites") { return try ok(["inviteId":UUID().uuidString.lowercased(),"token":household+"."+String(repeating:"a",count:43),"expiresAt":"2099-01-01T00:00:00Z"]) }
        if path.hasSuffix("/requests/mine"), ownRequestsUnavailable { return try ok(["error":["code":"unavailable"]],503) }
        if path.hasSuffix("/requests/mine") { return try ok(["requests":actor == "sam" ? requests : [],"nextCursor":NSNull()]) }
        if path.hasSuffix("/shopper-assignment"), let shopID {
            return try ok(["shopId":shopID,"shopRevision":revision,"authorityEpoch":1,"phase":phase,"shopperId":miaID,
                "adults":[["id":miaID,"label":"Mia"],["id":samID,"label":"Alex"]]])
        }
        if path.hasSuffix("/financial-evidence"), let shopID {
            return try ok(["shopId": shopID, "sourceVersion": ["shopRevision": revision, "authorityEpoch": 1, "financialRevision": 1],
                "evidenceSource": "shopper_reported", "entries": [["id": UUID().uuidString, "kind": "paymentHold", "amountMinor": 3200,
                "currency": "USD", "occurredAt": "2026-01-01T12:00:00.000Z", "sourceText": "Hold on the entered receipt"]], "nextCursor": NSNull()])
        }
        if path.hasSuffix("/inbox") { return try ok(["requests":requests.map { $0.merging(["authorAlias":"Sam"]) { _, new in new } },"nextCursor":NSNull()]) }
        if path.contains("/shops/"), request.httpMethod == "GET" { return try ok(["shopId":shopID!,"shopRevision":revision,"authorityEpoch":1,"phase":phase,"quote":quote,"lines":lines,"meals":meals,"storeBasisRevision":storeBasisRevision as Any? ?? NSNull(),"frozenRevision":phase == "frozen" ? revision : NSNull(),"placedRevision":NSNull()]) }
        if path.hasSuffix("/previews") {
            let id = UUID().uuidString.lowercased(); previews[id] = json
            let total = lines.reduce(0) { $0 + ($1["packs"] as! Int) * ($1["unitPriceMinor"] as? Int ?? 0) }
            let decision = json["decision"] as! [String: Any], line = decision["line"] as! [String: Any]
            let after = total + (line["unitPriceMinor"] as? Int ?? 0) * (line["packs"] as! Int)
            func budget(_ amount: Int) -> [String: Any] { ["currency":"USD","totalMinor":amount,"overCapMinor":max(0,amount-3800),"headroomMinor":3800-amount,"status":amount>3800 ? "overCap":"withinCap","scope":"wholeCheckout","missing":[],"lowerBoundMinor":amount,"upperBoundMinor":amount,"wholeCheckoutWithinCap":amount<=3800] }
            let base = json["base"] as! [String: Any]
            return try ok(["previewId":id,"expiresAt":"2099-01-01T00:00:00Z","shopRevision":revision,"authorityEpoch":1,"requestRevision":base["requestRevision"]!,"choice":"add","before":budget(total),"after":budget(after),"changeMinor":after-total,"requiresOverageAcceptance":after>3800,"requiresUnknownAcceptance":false])
        }
        if path.hasSuffix("/commands") {
            let kind = json["kind"] as! String, key = json["clientKey"] as! String, body = json["body"] as! [String: Any]
            commandBodies.append((kind,input))
            if let prior = receipts[key] { return try ok(prior) }
            kinds.append(kind)
            if kind == "shop.create" { sharedShopCreates += 1; shopID = json["shopId"] as? String; revision = 1; quote = body["quote"] as! [String:Any]; lines = body["lines"] as! [[String:Any]] }
            if kind == "shop.patch" { quote = body["quote"] as! [String:Any]; lines = body["lines"] as! [[String:Any]]; revision += 1 }
            if kind == "shop.patch", let edit = body["mealEdit"] as? [String:Any], let id = edit["occurrenceId"] as? String {
                meals.removeAll { $0["occurrenceId"] as? String == id }
                if let meal = edit["meal"] as? [String:Any] { meals.append(["occurrenceId": id,"revision":revision,"meal":meal]) }
            }
            if kind == "shop.transferAuthority" {
                guard body["newShopperId"] as? String == samID else { throw URLError(.badServerResponse) }
                shopperTransferred = true
            }
            if kind == "shop.freeze" { phase = "frozen"; revision += 1 }
            if kind == "shop.reopen" { phase = "draft"; revision += 1 }
            if kind == "request.send" {
                let value: [String:Any] = ["requestId":UUID().uuidString.lowercased(),"shopId":shopID!,"revision":1,"originalItem":body["originalItem"]!,"ownQuantity":body["ownQuantity"]!,"authoredAt":body["authoredAt"]!,"receivedAt":"2026-11-03T00:00:00Z","route":phase == "draft" ? (body["route"] ?? "current") : "next","status":"pending","ownActionAllowed":true,"clarification":NSNull(),"followupTo":NSNull()]
                requests.append(value); let receipt: [String:Any] = ["operationId":UUID().uuidString,"kind":kind,"request":value]; receipts[key] = receipt; return try ok(receipt)
            }
            if kind == "request.apply" {
                let preview = previews[body["previewId"] as! String]!, decision = preview["decision"] as! [String:Any]
                lines.append(decision["line"] as! [String:Any]); revision += 1
                if let index = requests.firstIndex(where: { $0["requestId"] as? String == body["requestId"] as? String }) { requests[index]["status"] = "added"; requests[index]["ownActionAllowed"] = false; requests[index]["revision"] = 2 }
            }
            let receipt: [String:Any] = ["operationId":UUID().uuidString,"kind":kind,"shopId":shopID!,"shopRevision":revision,"authorityEpoch":1,"disposition":"confirmed"]
            receipts[key] = receipt
            if kind == "shop.create", loseCreateResponse { throw URLError(.networkConnectionLost) }
            return try ok(receipt)
        }
        privateReads += 1; throw URLError(.unsupportedURL)
    }
}
private final class SharedFlowVault: RefreshTokenVault, @unchecked Sendable {
    var value: String?
    func read() throws -> String? { value }
    func write(_ value: String) throws { self.value = value }
    func clear() throws { value = nil }
}
private final class SharedFlowURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int,Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { let (code,data) = try Self.handler(request); client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self) }
        catch { client?.urlProtocol(self,didFailWithError:error) }
    }
    override func stopLoading() {}
}

@MainActor final class HouseholdHelperReviewFlowTests: XCTestCase {
    private func fixture(store: HelperReviewMemoryStore = .init()) async -> (HouseholdHelperReviewModel, HelperReviewFakeService, HelperReviewMemoryStore, HelperReviewScopeBox) {
        let box = HelperReviewScopeBox(), service = HelperReviewFakeService(store: store)
        let model = HouseholdHelperReviewModel(grantID: HelperReviewData.grant, service: service, store: store,
            runtime: { box.value }, accessEnded: { box.value = nil })
        await model.load(); return (model, service, store, box)
    }
    func testExplicitReviewAndApprovalPersistBeforeSending() async throws {
        let (model, service, store, _) = await fixture()
        await model.apply(); XCTAssertTrue(service.sent.isEmpty)
        model.review(decision: .replace, projection: service.current.projection)
        await model.apply(); XCTAssertTrue(service.sent.isEmpty)
        model.approved = true; await model.apply()
        XCTAssertEqual(service.sent.count, 1); XCTAssertTrue(service.wasPersistedBeforeSend)
        XCTAssertNotNil(model.receipt); XCTAssertNil(model.pending)
        let saved = try await store.read(); XCTAssertTrue(saved.reviewActions?.isEmpty ?? true)
    }
    func testUncertainResultRestoresAndReplaysOriginalBytesAfterRevisionChanges() async throws {
        let (model, service, store, box) = await fixture()
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        service.failDelivery = true; await model.apply()
        let original = try XCTUnwrap(model.pending); XCTAssertNil(model.receipt)
        service.current = HelperReviewData.current(revision: 2); service.failDelivery = false
        let restored = HouseholdHelperReviewModel(grantID: HelperReviewData.grant, service: service, store: store,
            runtime: { box.value }, accessEnded: {})
        await restored.load(); XCTAssertEqual(restored.pending, original); XCTAssertFalse(restored.canReview)
        XCTAssertEqual(service.sent.count, 1) // Loading never sends.
        await restored.retryAndReconcile()
        XCTAssertEqual(service.sent, [original, original]); XCTAssertEqual(service.preparations, 1)
        XCTAssertNotNil(restored.receipt); XCTAssertNil(restored.pending)
    }
    func testPersistenceFailureNeverSends() async throws {
        let store = HelperReviewMemoryStore(failSave: true)
        let (model, service, _, _) = await fixture(store: store)
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        await model.apply(); XCTAssertTrue(service.sent.isEmpty); XCTAssertNil(model.receipt)
    }
    func testConfirmedReceiptCleanupRetryDoesNotSendAgain() async throws {
        let store = HelperReviewMemoryStore(failRemove: true)
        let (model, service, _, _) = await fixture(store: store)
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        await model.apply(); XCTAssertNotNil(model.receipt); XCTAssertNotNil(model.pending)
        await store.allowRemoval(); await model.retryAndReconcile()
        XCTAssertEqual(service.sent.count, 1); XCTAssertNil(model.pending)
    }
    func testScopeChangeDuringPreparationCannotPersistOrSendAndClearsVisibleData() async throws {
        let (model, service, store, box) = await fixture()
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        service.beforePrepare = { box.value = nil }
        await model.apply(); model.enforceRuntime()
        XCTAssertTrue(service.sent.isEmpty); XCTAssertNil(model.current); XCTAssertNil(model.reviewed)
        let saved = try await store.read(); XCTAssertNil(saved.reviewActions)
    }
    func testPurgeAfterReviewRejectsLatePrivateSave() async throws {
        let (model, service, store, _) = await fixture()
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        service.beforePrepare = { await store.purge() }
        await model.apply(); XCTAssertTrue(service.sent.isEmpty)
        let saved = try await store.read(); XCTAssertNil(saved.reviewActions)
    }
    func testChangedDraftOrStaleServerSnapshotCannotApplyOldApproval() async throws {
        let (model, service, _, _) = await fixture()
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        model.cancelReview(); await model.apply(); XCTAssertTrue(service.sent.isEmpty)
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        service.current = HelperReviewData.current(revision: 2)
        await model.apply(); XCTAssertTrue(service.sent.isEmpty); XCTAssertNil(model.reviewed); XCTAssertFalse(model.approved)
    }
    func testClearingUncertainRetryNeedsFreshAuthorizedStatus() async throws {
        let (model, service, store, _) = await fixture()
        model.review(decision: .replace, projection: service.current.projection); model.approved = true
        service.failDelivery = true; await model.apply(); XCTAssertNotNil(model.pending)
        service.failRead = true; await model.clearRetryAfterStatusReview()
        let saved = try await store.read(); XCTAssertEqual(saved.reviewActions?.count, 1)
        XCTAssertEqual(service.sent.count, 1)
    }
}

@MainActor private final class HelperReviewScopeBox {
    var value: HouseholdHelperReviewScope? = .init(generation: UUID(), subject: "reviewer", householdID: HelperReviewData.household,
        memberID: HelperReviewData.member, shopID: HelperReviewData.shop)
}
private actor HelperReviewMemoryStore: HelperReviewPersisting {
    var state = LifecyclePendingState(); var epoch = UUID()
    let failSave: Bool; var failRemove: Bool
    init(failSave: Bool = false, failRemove: Bool = false) { self.failSave = failSave; self.failRemove = failRemove }
    func read() throws -> LifecyclePendingState { state }
    func reviewEpoch() -> UUID { epoch }
    func saveReviewAction(_ intent: HelperReviewIntent, expectedEpoch: UUID) throws {
        guard expectedEpoch == epoch else { throw ClientError.cancelled }
        if failSave { throw ClientError.transport }; state.reviewActions = [intent]
    }
    func removeReviewAction(id: String) throws {
        if failRemove { throw ClientError.transport }; state.reviewActions?.removeAll { $0.id == id }
    }
    func allowRemoval() { failRemove = false }
    func purge() { epoch = UUID(); state = .init() }
}
@MainActor private final class HelperReviewFakeService: HelperReviewServing {
    var current = HelperReviewData.current()
    let store: HelperReviewMemoryStore
    var beforePrepare: (() async -> Void)?
    var failDelivery = false; var failRead = false
    var sent: [HelperReviewIntent] = []; var preparations = 0; var wasPersistedBeforeSend = false
    init(store: HelperReviewMemoryStore) { self.store = store }
    func managedHelperProjection(grantID: String, shopID: String) async throws -> ManagedHelperProjection {
        if failRead { throw ClientError.transport }; return current
    }
    func managedHelperProposal(grantID: String, proposalID: String, shopID: String) async throws -> HelperProposal { throw ClientError.configuration }
    func prepareHelperReview(current: ManagedHelperProjection, proposal: HelperProposal?, decision: HelperReviewDecision, projection: HelperProjection?) async throws -> HelperReviewIntent {
        preparations += 1
        guard current == self.current else { throw ClientError.service(status: 409, code: "stale_base", correlationID: nil, retryAfter: nil) }
        await beforePrepare?()
        return try HelperReviewData.intent(current: current, projection: XCTUnwrap(projection))
    }
    func reconcileHelperReview(_ intent: HelperReviewIntent) async throws -> HelperReviewReceipt {
        let saved = try await store.read(); wasPersistedBeforeSend = saved.reviewActions?.contains(intent) == true
        sent.append(intent)
        if failDelivery { throw ClientError.transport }
        return HelperReviewData.decode(["mutationId": UUID().uuidString, "grantId": intent.grantID, "baseRevision": intent.baseRevision,
            "revision": intent.baseRevision + 1, "status": "replaced", "asOf": "2026-11-03T00:00:00Z"])
    }
}
private enum HelperReviewData {
    static let household = "00000000-0000-4000-8000-000000000001", member = "00000000-0000-4000-8000-000000000002"
    static let grant = "00000000-0000-4000-8000-000000000003", shop = "00000000-0000-4000-8000-000000000004"
    static func decode<T: Decodable>(_ value: [String: Any]) -> T { try! JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) }
    static func current(revision: Int = 1) -> ManagedHelperProjection {
        decode(["grantId": grant, "shopId": shop, "revision": revision, "asOf": "2026-11-03T00:00:00Z", "expiresAt": "2099-01-01T00:00:00Z", "mode": "edit",
            "projection": ["shopLabel": "Cook", "language": "en", "items": [["label": "Rice", "amount": NSNull(), "unit": NSNull(), "action": "Warm rice"]]]])
    }
    static func intent(current: ManagedHelperProjection, projection: HelperProjection) throws -> HelperReviewIntent {
        let id = UUID().uuidString.lowercased(), value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(projection))
        let bytes = try JSONSerialization.data(withJSONObject: ["clientKey": id, "baseRevision": current.revision, "projection": value], options: [.sortedKeys])
        return decode(["id": id, "subject": "reviewer", "householdID": household, "memberID": member, "deviceID": "test-device", "grantID": grant, "shopID": shop,
            "baseRevision": current.revision, "decision": "replace", "projection": value, "bytes": bytes.base64EncodedString()])
    }
}
