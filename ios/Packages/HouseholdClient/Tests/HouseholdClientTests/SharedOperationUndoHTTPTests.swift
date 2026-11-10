import XCTest
@testable import HouseholdClient

private func undoHTTPData(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
private func undoHTTPBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
    return data
}
extension HouseholdClientTests {
    func testOperationUndoHTTPServerActionCancelLostReplyRelaunchExactRetryAndRevocation() async throws {
        let f = try OperationUndoFixture.object(), page: SharedDemandPage = try OperationUndoFixture.decode(f["page"]!), shop: ShopperShop = try OperationUndoFixture.decode(f["shop"]!)
        let target: SharedOperationUndoHistoryItem = try OperationUndoFixture.decode(f["target"]!), packs: [SharedDemandPackReview] = try OperationUndoFixture.decode(f["packs"]!)
        let auth = try auth(), vault = MemoryVault(), config = try ServiceConfiguration(baseURL: URL(string: "https://service.test")!)
        var service = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport())
        var commands: [Data] = [], previews = 0, windows = 0, deny = false, committed = 0
        MockURLProtocol.handler = { request in
            if let value = self.authResponse(request) { return value }
            let path = try XCTUnwrap(request.url?.path)
            if path.hasSuffix("/devices") { return (201, try undoHTTPData(["deviceId": "device", "deviceToken": "test"])) }
            if path.hasSuffix("/bootstrap") { return (200, try undoHTTPData(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": deny ? "contributor" : "shopper", "shopId": shop.shopId, "enrolled": true, "queueConsent": false, "capabilities": deny ? ["own_requests"] : ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            if path.hasSuffix("/replay-windows") { windows += 1; return (200, try undoHTTPData(["id": UUID().uuidString.lowercased(), "expiresAt": "2099-01-01T00:00:00Z"])) }
            if path.hasSuffix("/demand/operations") { XCTAssertEqual(request.httpMethod, "GET"); return (200, try undoHTTPData(f["history"]!)) }
            if path.hasSuffix("/demand/operation-undo-candidates") {
                let object = try JSONSerialization.jsonObject(with: undoHTTPBody(request)) as! [String: Any]
                XCTAssertEqual(Set(object.keys), ["targetOperationId", "base"])
                XCTAssertEqual(object["targetOperationId"] as? String, target.operationId.string)
                return (200, try undoHTTPData(f["candidate"]!))
            }
            if path.hasSuffix("/demand/operation-undo-previews") {
                previews += 1
                let object = try JSONSerialization.jsonObject(with: undoHTTPBody(request)) as! [String: Any]
                XCTAssertEqual(Set(object.keys), ["targetOperationId", "effectDigest", "base", "packs"])
                XCTAssertEqual(try OperationUndoFixture.decode(object["packs"]!, as: [SharedDemandPackReview].self), packs)
                return (200, try undoHTTPData(f["response"]!))
            }
            guard path.hasSuffix("/commands") else { throw ClientError.configuration }
            let bytes = undoHTTPBody(request); commands.append(bytes)
            if commands.count == 1 { committed += 1; throw URLError(.networkConnectionLost) }
            XCTAssertEqual(bytes, commands[0])
            let response = f["response"] as! [String: Any], receipt = response["receipt"] as! [String: Any]
            return (200, try undoHTTPData(["operationId": receipt["operationId"]!, "kind": "shop.patch", "shopId": shop.shopId, "shopRevision": 8, "authorityEpoch": 2, "disposition": "patched"]))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let history = try await service.sharedOperationHistory(shopID: page.shopId.uuid, page: page)
        XCTAssertEqual(history.items, [target])
        let candidate = try await service.sharedOperationUndoCandidate(page: page, shop: shop, target: target)
        XCTAssertEqual(windows, 0); XCTAssertEqual(previews, 0); XCTAssertTrue(commands.isEmpty)
        // Dropping a candidate is a read-only Cancel; the server supplies no Apply token.
        do { _ = try await service.previewSharedOperationUndo(page: page, shop: shop, target: target, candidate: candidate, packs: []); XCTFail("Missing pack review reached HTTP") } catch {}
        XCTAssertEqual(previews, 0)
        let review = try await service.previewSharedOperationUndo(page: page, shop: shop, target: target, candidate: candidate, packs: packs)
        XCTAssertTrue(commands.isEmpty); XCTAssertEqual(windows, 0)
        let operation = try await service.prepareSharedOperationUndoApply(review)
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
        var expected = try review.response.action.commandAction.bodyValues()
        expected["demandReview"] = .object(["previewId": .string(review.response.preview.previewId.string), "previewDigest": .string(review.response.preview.previewDigest)])
        XCTAssertEqual(envelope.body, expected); XCTAssertEqual(envelope.kind, "shop.patch")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("outbox.json"), outbox = OperationOutbox(url: directory.appendingPathComponent("outbox.json"))
        try await outbox.append(operation)
        do { _ = try await service.executeSharedDemand(operation); XCTFail("Expected lost reply") } catch {}
        service = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport()); _ = try await service.enroll(householdID: household)
        let restored = try await OperationOutbox(url: url).operations()
        let receipt = try await service.executeSharedDemand(try XCTUnwrap(restored.first))
        XCTAssertEqual(commands, [operation.bytes, operation.bytes]); XCTAssertEqual(committed, 1)
        XCTAssertEqual(receipt.operationId, review.response.preview.receipt.operationId.string)
        XCTAssertEqual(previews, 1); XCTAssertEqual(windows, 1)
        var expiredFixture = f, expiredResponse = f["response"] as! [String: Any]
        expiredResponse["expiresAt"] = "2020-01-01T00:00:00Z"; expiredFixture["response"] = expiredResponse
        let expired = try SharedOperationUndoReview(context: review.context, page: page, shop: shop, target: target, candidate: candidate,
            request: review.request, response: OperationUndoFixture.decode(expiredFixture["response"]!))
        do { _ = try await service.prepareSharedOperationUndoApply(expired); XCTFail("Expired preview prepared an Apply") } catch {}
        XCTAssertEqual(windows, 1); XCTAssertEqual(commands.count, 2)
        deny = true
        do { _ = try await service.executeSharedDemand(operation); XCTFail("Revoked authority sent retry") } catch {}
        XCTAssertEqual(commands.count, 2)
        deny = false; _ = try await service.enroll(householdID: household)
        let held = HeldResponse(), arrived = expectation(description: "held read-only candidate")
        MockURLProtocol.intercept = { request in
            if request.request.url?.path.hasSuffix("/operation-undo-candidates") == true { held.set(request); arrived.fulfill(); return true }; return false
        }
        let active = service
        let task = Task { try await active.sharedOperationUndoCandidate(page: page, shop: shop, target: target) }
        await fulfillment(of: [arrived], timeout: 2)
        await active.clearScope(); held.finish(status: 200, data: try undoHTTPData(f["candidate"]!))
        do { _ = try await task.value; XCTFail("Held candidate survived revoked context") } catch {}
        XCTAssertEqual(commands.count, 2)
    }
}

// Explicit synthetic membership inverse: all authoritative quantities/source IDs
// remain fixed. This builds response fixtures, not a client inverse implementation.
private func undoMembershipExpiryFixture(restoring: Bool) throws -> [String: Any] {
    var f = try OperationUndoFixture.object()
    var page = f["page"] as! [String: Any], shop = f["shop"] as! [String: Any]
    var candidate = f["candidate"] as! [String: Any], response = f["response"] as! [String: Any]
    let activeGraph = page["graph"] as! [String: Any], activeTotals = page["totals"]!
    let activeBasket = shop["lines"] as! [[String: Any]], activeBudget = candidate["beforeCheckout"] as! [String: Any]
    var emptyBudget = activeBudget
    for key in ["totalMinor", "lowerBoundMinor", "upperBoundMinor"] { emptyBudget[key] = 0 }
    emptyBudget["headroomMinor"] = 1000
    var quote = shop["quote"] as! [String: Any]
    quote["observedAt"] = "2019-01-01T00:00:00Z"; quote["expiresAt"] = "2020-01-01T00:00:00Z"
    var before = activeGraph, after = activeGraph
    var line = (activeGraph["lines"] as! [[String: Any]])[0]
    var source = (activeGraph["contributions"] as! [[String: Any]])[0]
    line["trashedAt"] = "2026-11-09T12:00:00Z"; source["removedAt"] = "2026-11-09T12:00:00Z"
    if restoring { before["lines"] = [line]; before["contributions"] = [source] }
    else { after["lines"] = [line]; after["contributions"] = [source] }
    after["revision"] = 4
    page["graph"] = before; page["totals"] = restoring ? [] : activeTotals
    shop["quote"] = quote; shop["lines"] = restoring ? [] : activeBasket
    let action: [String: Any] = ["kind": "shop.patch", "body": ["quote": quote, "lines": restoring ? activeBasket : []]]
    var scope = candidate["scope"] as! [String: Any]
    scope["graphRows"] = 2; scope["quoteChanged"] = false
    scope["touchedLines"] = [["lineId": line["id"]!, "fields": ["membership"]]]
    let packs: Any = restoring ? f["packs"]! : []
    for key in ["before", "after"] { candidate[key] = key == "before" ? before : after; response[key] = candidate[key] }
    candidate["beforeTotals"] = restoring ? [] : activeTotals; candidate["afterTotals"] = restoring ? activeTotals : []
    candidate["beforeCheckout"] = restoring ? emptyBudget : activeBudget; candidate["afterCheckout"] = restoring ? activeBudget : emptyBudget
    candidate["action"] = action; candidate["scope"] = scope
    candidate["packReviewLineIds"] = restoring ? [line["id"]!] : []
    for key in ["beforeTotals", "afterTotals", "beforeCheckout", "afterCheckout", "action"] { response[key] = candidate[key] }
    response["packs"] = packs
    var metadata = response["operationUndo"] as! [String: Any]; metadata["scope"] = scope; response["operationUndo"] = metadata
    var receipt = response["receipt"] as! [String: Any]
    receipt["lines"] = [["id": line["id"]!, "before": (before["lines"] as! [[String: Any]])[0], "after": (after["lines"] as! [[String: Any]])[0]]]
    receipt["contributions"] = [["id": source["id"]!, "before": (before["contributions"] as! [[String: Any]])[0], "after": (after["contributions"] as! [[String: Any]])[0]]]
    response["receipt"] = receipt
    f["page"] = page; f["shop"] = shop; f["candidate"] = candidate; f["response"] = response; f["packs"] = packs
    return f
}
extension HouseholdClientTests {
    func testOperationUndoRemovingNewLineDoesNotRequireFreshUnchangedQuote() async throws {
        try await checkUndoMembershipExpiry(restoring: false)
    }
    func testOperationUndoRestoringHistoricalLineRejectsExpiredQuoteBeforeReplayWindow() async throws {
        try await checkUndoMembershipExpiry(restoring: true)
    }
    private func checkUndoMembershipExpiry(restoring: Bool) async throws {
        let fixture = try undoMembershipExpiryFixture(restoring: restoring), original = try OperationUndoFixture.review(fixture)
        let auth = try auth(), service = HouseholdService(configuration: try ServiceConfiguration(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        var windows = 0, commands = 0
        MockURLProtocol.handler = { request in
            if let value = self.authResponse(request) { return value }
            let path = try XCTUnwrap(request.url?.path)
            if path.hasSuffix("/devices") { return (201, try undoHTTPData(["deviceId": "device", "deviceToken": "test"])) }
            if path.hasSuffix("/bootstrap") { return (200, try undoHTTPData(["household": ["id": self.household, "label": "Home"], "memberId": self.member, "role": "shopper", "shopId": original.shop.shopId, "enrolled": true, "queueConsent": false, "capabilities": ["shopper_inbox", "request_preview", "shopper_commands"]])) }
            if path.hasSuffix("/replay-windows") { windows += 1; return (200, try undoHTTPData(["id": UUID().uuidString.lowercased(), "expiresAt": "2099-01-01T00:00:00Z"])) }
            if path.hasSuffix("/commands") { commands += 1 }
            throw ClientError.configuration
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let context = try await service.sharedDemandContext(shopID: original.page.shopId.uuid)
        let review = try SharedOperationUndoReview(context: context, page: original.page, shop: original.shop, target: original.target,
            candidate: original.candidate, request: original.request, response: original.response)
        if restoring {
            do { _ = try await service.prepareSharedOperationUndoApply(review); XCTFail("Expired historical price was restored") }
            catch let error as ClientError { XCTAssertEqual(error, .service(status: 409, code: "food_undo_expired_quote", correlationID: nil, retryAfter: nil)) }
            XCTAssertEqual(windows, 0)
        } else {
            let operation = try await service.prepareSharedOperationUndoApply(review)
            let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
            XCTAssertEqual(envelope.kind, "shop.patch"); XCTAssertEqual(envelope.body["lines"], .array([]))
            XCTAssertEqual(operation.sharedDemandBinding?.reservedOperationID, review.response.preview.receipt.operationId)
            XCTAssertEqual(windows, 1)
        }
        XCTAssertEqual(commands, 0, "Preparation is not Apply")
    }
}
