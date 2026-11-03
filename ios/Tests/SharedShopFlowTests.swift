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
        await shared.loadFinancialEntries()
        let entries = try XCTUnwrap(shared.financialEntries)
        XCTAssertEqual(entries.map(\.kind), [.paymentHold])
        XCTAssertEqual(entries.first?.amountMinor, 3200)
        XCTAssertEqual(entries.first?.sourceText, "Hold on the entered receipt")
        fixture.shopperTransferred = true
        await mia.refresh()
        XCTAssertNil(shared.financialEntries)
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
    var joined = Set<String>(), shopID: String?, revision = 0, phase = "draft"
    var quote: [String: Any] = [:], lines: [[String: Any]] = [], requests: [[String: Any]] = []
    var kinds: [String] = [], commandBodies: [(kind: String, bytes: Data)] = []
    var receipts: [String: [String: Any]] = [:], previews: [String: [String: Any]] = [:]
    var loseCreateResponse = false
    var shopperTransferred = false
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
                "role":shopper ? "shopper" : actor == "mia" ? "organizer" : "contributor", "shopId":shopID as Any? ?? NSNull(),"enrolled":true,"queueConsent":false,
                "capabilities":["own_requests"] + (actor == "mia" ? ["household_admin"] : []) + (shopper ? ["shopper_inbox","request_preview","shopper_commands"] : [])])
        }
        if path.hasSuffix("/replay-windows") { return try ok(["id":UUID().uuidString.lowercased(),"expiresAt":"2099-01-01T00:00:00Z"]) }
        if path.hasSuffix("/invites") { return try ok(["inviteId":UUID().uuidString.lowercased(),"token":household+"."+String(repeating:"a",count:43),"expiresAt":"2099-01-01T00:00:00Z"]) }
        if path.hasSuffix("/requests/mine"), ownRequestsUnavailable { return try ok(["error":["code":"unavailable"]],503) }
        if path.hasSuffix("/requests/mine") { return try ok(["requests":actor == "sam" ? requests : [],"nextCursor":NSNull()]) }
        if path.hasSuffix("/financial-evidence"), let shopID {
            return try ok(["shopId": shopID, "sourceVersion": ["shopRevision": revision, "authorityEpoch": 1, "financialRevision": 1],
                "evidenceSource": "shopper_reported", "entries": [["id": UUID().uuidString, "kind": "paymentHold", "amountMinor": 3200,
                "currency": "USD", "occurredAt": "2026-01-01T12:00:00.000Z", "sourceText": "Hold on the entered receipt"]], "nextCursor": NSNull()])
        }
        if path.hasSuffix("/inbox") { return try ok(["requests":requests.map { $0.merging(["authorAlias":"Sam"]) { _, new in new } },"nextCursor":NSNull()]) }
        if path.contains("/shops/"), request.httpMethod == "GET" { return try ok(["shopId":shopID!,"shopRevision":revision,"authorityEpoch":1,"phase":phase,"quote":quote,"lines":lines,"frozenRevision":phase == "frozen" ? revision : NSNull(),"placedRevision":NSNull()]) }
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
