import XCTest
@testable import HouseholdClient

private func demandObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(value)) as? [String: Any])
}
private func demandData(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
private func demandBody(_ request: URLRequest) -> Data {
    if let data = request.httpBody { return data }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
    return data
}

extension HouseholdClientTests {
    func testSharedDemandRequiredNullsAreDistinctFromMissingAndRationalsStayDecimalStrings() throws {
        let q = SharedDemandQuantity(amount: try .init(numerator: Int64.max), unit: .count, originalLiteral: "Original 9223372036854775807 units")
        let encodedQuantity = try demandObject(q)
        XCTAssertTrue(encodedQuantity["confirmedConversion"] is NSNull)
        XCTAssertEqual((encodedQuantity["amount"] as? [String: Any])?["numerator"] as? String, String(Int64.max))
        XCTAssertEqual(try JSONDecoder().decode(SharedDemandQuantity.self, from: demandData(encodedQuantity)), q)
        var missing = encodedQuantity; missing.removeValue(forKey: "confirmedConversion")
        XCTAssertThrowsError(try JSONDecoder().decode(SharedDemandQuantity.self, from: demandData(missing)))
        let c = SharedDemandContribution(lineId: .init(), source: .manual, productKey: nil, productName: "Wraps", originalText: "Amount still unknown", quantity: nil)
        let object = try demandObject(c)
        for key in ["quantity", "productKey", "removedAt"] {
            XCTAssertTrue(object[key] is NSNull); var absent = object; absent.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(SharedDemandContribution.self, from: demandData(absent)), key)
        }
        XCTAssertEqual(try JSONDecoder().decode(SharedDemandContribution.self, from: demandData(object)).originalText, c.originalText)
        let source = SharedDemandSource.reservation(reservationId: .init(), purpose: "Lunch", originOccurrenceId: .init(), ingredientId: .init(), groupId: .init(), bindingId: nil)
        var sourceObject = try demandObject(source); XCTAssertTrue(sourceObject["bindingId"] is NSNull)
        sourceObject.removeValue(forKey: "bindingId"); XCTAssertThrowsError(try JSONDecoder().decode(SharedDemandSource.self, from: demandData(sourceObject)))
    }
    func testSharedDemandRejectsNoncanonicalIDsFractionsAndUnknownSourceKinds() throws {
        let uuid = try XCTUnwrap(UUID(uuidString:"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")), id = SharedDemandID(uuid)
        XCTAssertEqual(String(decoding: try encoded(id), as: UTF8.self), "\"" + uuid.uuidString.lowercased() + "\"")
        XCTAssertThrowsError(try JSONDecoder().decode(SharedDemandID.self, from: demandData(["id": uuid.uuidString])))
        XCTAssertThrowsError(try JSONDecoder().decode(SharedDemandID.self, from: Data(("\"" + uuid.uuidString + "\"").utf8)))
        for n in (["01", "0", "-1", "1.0", "9223372036854775808", 1, 1.5] as [Any]) {
            XCTAssertThrowsError(try JSONDecoder().decode(SharedDemandAmount.self, from: demandData(["numerator": n, "denominator": "1"])))
        }
        XCTAssertThrowsError(try SharedDemandAmount(numerator: 2, denominator: 4))
        for source in ([["kind":"future"], ["kind":"manual", "requestId":uuid.uuidString.lowercased()]] as [[String: Any]]) {
            XCTAssertThrowsError(try JSONDecoder().decode(SharedDemandSource.self, from: demandData(source)))
        }
    }
    func testSharedDemandConstructorValidationMatchesUUIDUTF16AndConversionContracts() throws {
        for raw in ["00000000-0000-0000-0000-000000000000", "aaaaaaaa-aaaa-9aaa-8aaa-aaaaaaaaaaaa", "aaaaaaaa-aaaa-4aaa-7aaa-aaaaaaaaaaaa"] {
            let id = SharedDemandID(try XCTUnwrap(UUID(uuidString:raw)))
            XCTAssertThrowsError(try encoded(id))
            let change = SharedDemandChange(removeSourceIds:[id])
            XCTAssertThrowsError(try change.validate())
            let request = SharedDemandPreviewRequest(mode:.adopt,base:.init(shopRevision:1,authorityEpoch:1,graphRevision:0),change:.init(),action:.request(.init(requestId:id,previewId:.init(),acceptOverage:false,acceptUnknown:false)),packs:[])
            XCTAssertThrowsError(try request.validate())
        }
        var quantity = SharedDemandQuantity(amount:try .init(numerator:1),unit:.count,originalLiteral:String(repeating:"🥙",count:1024))
        try quantity.validate()
        quantity.originalLiteral += "🥙"; XCTAssertThrowsError(try quantity.validate())
        quantity.originalLiteral = "One explicitly reviewed unit"
        quantity.confirmedConversion = .init(sourceUnit:.ounce,targetUnit:.gram,targetAmountPerSourceUnit:try .init(numerator:1),sourceNote:"Same dimension is already defined",confirmedAt:"2026-11-09T00:00:00Z")
        XCTAssertThrowsError(try quantity.validate())
        quantity.confirmedConversion = .init(sourceUnit:.count,targetUnit:.gram,targetAmountPerSourceUnit:try .init(numerator:20),sourceNote:"One verified wrap weighs 20 grams",confirmedAt:"2026-11-09T00:00:00Z")
        try quantity.validate()
    }
    func testSharedDemandGoldenConservationGraphAndUnknownRestrictionRoundtrip() throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("shared/fixtures/shared-demand/conservation-v1.json"))) as? [String: Any])
        var graph = try JSONDecoder().decode(SharedDemandGraph.self, from: demandData(try XCTUnwrap(fixture["graph"])))
        try graph.validate(); XCTAssertEqual(graph.contributions.count, 4); XCTAssertEqual(graph.edges.count, 3)
        XCTAssertEqual(try JSONDecoder().decode(SharedDemandGraph.self, from: encoded(graph)), graph)
        let old = graph.contributions[1]
        graph.edges.removeAll { $0.demandId == old.id }; graph.contributions[1].quantity = nil
        graph.contributions[1].sourceExclusions = [.init(occurrenceId: try XCTUnwrap(old.source.origin.0), ingredientId: old.source.origin.1, label: "Original restriction", resolution: .unresolved)]
        try graph.validate(); XCTAssertNil(try JSONDecoder().decode(SharedDemandGraph.self, from: encoded(graph)).contributions[1].quantity)
        graph.schemaVersion = 2; XCTAssertThrowsError(try graph.validate()); graph.schemaVersion = 1
        graph.contributions[1].lineId = .init(); XCTAssertThrowsError(try graph.validate())
    }
    func testSharedDemandRequestGenerationsRetainHistoryWithoutDuplicatingActiveOrHistoricalSources() throws {
        let line = SharedDemandLine(name: "Wraps", unit: .count, originalOrder: 0), request = SharedDemandID()
        let old = SharedDemandContribution(lineId: line.id, source: .request(requestId: request, appliedRequestRevision: 4), productKey: "wraps", productName: "Wraps", originalText: "Original request wording", quantity: nil, removedAt: "2026-11-09T13:00:00Z")
        let current = SharedDemandContribution(lineId: line.id, source: .request(requestId: request, appliedRequestRevision: 7), productKey: "wraps", productName: "Wraps", originalText: "Later author wording", quantity: nil)
        let graph = SharedDemandGraph(householdId: .init(), shopId: .init(), revision: 3, lines: [line], contributions: [old, current], edges: [], usedIds: [line.id, old.id, current.id])
        try graph.validate()
        XCTAssertEqual(try JSONDecoder().decode(SharedDemandGraph.self, from: encoded(graph)), graph)
        XCTAssertEqual(graph.contributions[0], old)
        var bothActive = graph; bothActive.contributions[0].removedAt = nil
        XCTAssertThrowsError(try bothActive.validate())
        for removedAt in [nil, old.removedAt] {
            var sameGeneration = graph; sameGeneration.contributions[1].source = old.source; sameGeneration.contributions[1].removedAt = removedAt
            XCTAssertThrowsError(try sameGeneration.validate())
        }
        var missingID = graph; missingID.usedIds.removeLast(); XCTAssertThrowsError(try missingID.validate())
        var reusedID = graph; reusedID.contributions[1].id = old.id; XCTAssertThrowsError(try reusedID.validate())
        let otherSources: [SharedDemandSource] = [.imported(batchId: .init(), entryId: .init()), .meal(occurrenceId: .init(), ingredientId: .init(), groupId: nil, bindingId: nil), .reservation(reservationId: .init(), purpose: "Protected lunch", originOccurrenceId: nil, ingredientId: .init(), groupId: nil, bindingId: nil)]
        for source in otherSources {
            var duplicate = graph; duplicate.contributions[0].source = source; duplicate.contributions[1].source = source
            XCTAssertThrowsError(try duplicate.validate())
        }
        // Current source catalogs still key request identity without revision.
        XCTAssertEqual(old.source.identityKey, current.source.identityKey)
    }
    func testSharedDemandCanonicalTotalsBindExactActiveRowsAndRequiredUnknownNull() throws {
        let household = SharedDemandID(), shop = SharedDemandID(), line = SharedDemandLine(name:"Unknown wraps",unit:.count,originalOrder:0)
        let source = SharedDemandContribution(lineId:line.id,source:.manual,productKey:nil,productName:"Unknown wraps",originalText:"Original unquantified wraps",quantity:nil)
        let graph = SharedDemandGraph(householdId:household,shopId:shop,revision:1,lines:[line],contributions:[source],edges:[],usedIds:[line.id,source.id])
        var row:[String:Any] = ["lineId":line.id.string,"unit":"count","quantity":NSNull(),"activeContributionIds":[source.id.string]]
        var object:[String:Any] = ["schemaVersion":1,"shopId":shop.string,"shopRevision":2,"authorityEpoch":1,"status":"enabled","graph":try demandObject(graph),"totals":[row]]
        let page = try JSONDecoder().decode(SharedDemandPage.self,from:demandData(object)); try page.validate(householdID:household.string,shopID:shop.uuid); XCTAssertNil(page.totals[0].quantity)
        row.removeValue(forKey:"quantity"); object["totals"] = [row]; XCTAssertThrowsError(try JSONDecoder().decode(SharedDemandPage.self,from:demandData(object)))
        row["quantity"] = NSNull(); row["activeContributionIds"] = [SharedDemandID().string]; object["totals"] = [row]
        XCTAssertThrowsError(try JSONDecoder().decode(SharedDemandPage.self,from:demandData(object)).validate(householdID:household.string,shopID:shop.uuid))
        row["activeContributionIds"] = [source.id.string]; row["unit"] = "gram"; object["totals"] = [row]
        XCTAssertThrowsError(try JSONDecoder().decode(SharedDemandPage.self,from:demandData(object)).validate(householdID:household.string,shopID:shop.uuid))
    }
    func testSharedDemandHTTPPreviewCancelDurableLostReplyRetryAndExactReceiptBinding() async throws {
        let auth = try auth(), vault = MemoryVault(), shop = UUID(), line = SharedDemandID(), source = SharedDemandID(), operationID = SharedDemandID(), previewID = SharedDemandID()
        let config = try ServiceConfiguration(baseURL: URL(string: "https://service.test")!)
        var service = HouseholdService(configuration: config, auth: auth, deviceVault: vault, transport: transport())
        let quantity = SharedDemandQuantity(amount: try .init(numerator: 12), unit: .count, originalLiteral: "Manual twelve wraps")
        let contribution = SharedDemandContribution(id: source, lineId: line, source: .manual, productKey: "wraps", productName: "Wraps", originalText: "Manual twelve wraps", quantity: quantity)
        let graphLine = SharedDemandLine(id: line, name: "Wraps", unit: .count, originalOrder: 0)
        let before = SharedDemandGraph(householdId: .init(try XCTUnwrap(UUID(uuidString: household))), shopId: .init(shop), revision: 0, lines: [], contributions: [], edges: [], usedIds: [])
        var after = before; after.revision = 1; after.lines = [graphLine]; after.contributions = [contribution]; after.usedIds = [line, source]
        let quote = try ShopperQuote(scope: "wholeCheckout", complete: true, capMinor: 2000, capScope: "wholeCheckout", fee: .fixed(0), taxesMinor: 0, depositsMinor: 0, discountsMinor: 0, observedAt: Date(), expiresAt: Date().addingTimeInterval(3600))
        let basket = ShopperBasketLine(lineId: line.uuid, originalItem: "Wraps", packs: 2, unitPriceMinor: 100, feeEligible: true)
        let packs = [SharedDemandPackReview(lineId: line, usablePerPack: .init(amount: try .init(numerator: 6), unit: .count, originalLiteral: "6 usable wraps per pack"), acceptUnresolved: false)]
        let input = SharedDemandPreviewRequest(mode: .adopt, base: .init(shopRevision: 1, authorityEpoch: 1, graphRevision: 0), change: .init(lines: [graphLine], contributions: [contribution]), action: .patch(.init(quote: quote, lines: [basket])), packs: packs)
        let total: [String:Any] = ["lineId":line.string,"unit":"count","quantity":["numerator":"12","denominator":"1"],"activeContributionIds":[source.string]]
        let receipt: [String:Any] = ["schemaVersion":1,"operationId":operationID.string,"householdId":household,"shopId":shop.uuidString.lowercased(),"baseRevision":0,"resultRevision":1,
            "lines":[["id":line.string,"before":NSNull(),"after":try demandObject(graphLine)]],"contributions":[["id":source.string,"before":NSNull(),"after":try demandObject(contribution)]],"edges":[]]
        var commands = [Data](), deny = false, wrongReceipt = false
        MockURLProtocol.handler = { request in
            if let value = self.authResponse(request) { return value }
            let path = try XCTUnwrap(request.url?.path)
            if path.hasSuffix("/devices") { return (201, try demandData(["deviceId":"device","deviceToken":"test"])) }
            if path.hasSuffix("/bootstrap") { return (200, try demandData(["household":["id":self.household,"label":"Home"],"memberId":self.member,"role":deny ? "contributor":"shopper","shopId":shop.uuidString.lowercased(),"enrolled":true,"queueConsent":false,"capabilities":deny ? ["own_requests"]:["shopper_inbox","request_preview","shopper_commands"]])) }
            if path.hasSuffix("/replay-windows") { return (200, try demandData(["id":UUID().uuidString.lowercased(),"expiresAt":"2099-01-01T00:00:00Z"])) }
            if path.hasSuffix("/demand/previews") {
                XCTAssertEqual(try JSONDecoder().decode(SharedDemandPreviewRequest.self, from: demandBody(request)), input)
                return (200, try demandData(["previewId":previewID.string,"previewDigest":String(repeating:"a",count:64),"expiresAt":"2099-01-01T00:00:00Z","before":try demandObject(before),"after":try demandObject(after),"receipt":receipt,"packs":try JSONSerialization.jsonObject(with:encoded(packs)),"shopRevision":1,"authorityEpoch":1,"beforeTotals":[],"afterTotals":[total]]))
            }
            if path.hasSuffix("/demand") { return (200, try demandData(["schemaVersion":1,"shopId":shop.uuidString.lowercased(),"shopRevision":commands.isEmpty ? 1:2,"authorityEpoch":1,"status":commands.isEmpty ? "legacy":"enabled","graph":commands.isEmpty ? NSNull() as Any:try demandObject(after),"totals":commands.isEmpty ? []:[total]])) }
            XCTAssertTrue(path.hasSuffix("/commands")); commands.append(demandBody(request))
            if commands.count == 1 { throw URLError(.networkConnectionLost) }
            return (200, try demandData(["operationId":wrongReceipt ? UUID().uuidString.lowercased():operationID.string,"kind":"shop.patch","shopId":shop.uuidString.lowercased(),"shopRevision":2,"authorityEpoch":1,"disposition":"patched"]))
        }
        _ = try await auth.verifyEmailCode(email:"adult@example.test",code:"123456"); _ = try await service.enroll(householdID:household)
        let legacy = try await service.sharedDemand(shopID:shop); XCTAssertEqual(legacy.status, .legacy)
        let review = try await service.previewSharedDemand(shopID:shop,request:input)
        XCTAssertTrue(commands.isEmpty, "Cancel means no queued or sent Apply")
        let operation = try await service.prepareSharedDemandApply(review)
        XCTAssertEqual(operation.sharedDemandBinding?.shopID.uuid,shop)
        let legacyEnvelope = CommandEnvelope(replayWindow:UUID().uuidString.lowercased(),shopId:shop.uuidString.lowercased(),kind:"shop.freeze",base:.init(shopRevision:1,authorityEpoch:1),body:[:])
        let legacyOperation = try PendingOperation(envelope:legacyEnvelope,householdID:household,memberID:member,deviceID:"device")
        var oldObject = try demandObject(legacyOperation); oldObject.removeValue(forKey:"sharedDemandBinding")
        XCTAssertEqual(try JSONDecoder().decode(PendingOperation.self,from:demandData(oldObject)),legacyOperation)
        var corrupted = try demandObject(operation)
        var wrongEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with:operation.bytes) as? [String:Any])
        var wrongBase = try XCTUnwrap(wrongEnvelope["base"] as? [String:Any]); wrongBase["authorityEpoch"] = 2; wrongEnvelope["base"] = wrongBase
        corrupted["bytes"] = try demandData(wrongEnvelope).base64EncodedString()
        let changedOperation = try JSONDecoder().decode(PendingOperation.self,from:demandData(corrupted))
        do { _ = try await service.executeSharedDemand(changedOperation); XCTFail("Changed persisted base reached network") } catch { XCTAssertEqual(error as? ClientError,.invalidResponse) }
        XCTAssertTrue(commands.isEmpty)
        wrongEnvelope = try XCTUnwrap(JSONSerialization.jsonObject(with:operation.bytes) as? [String:Any]); wrongEnvelope["shopId"] = UUID().uuidString.lowercased()
        corrupted["bytes"] = try demandData(wrongEnvelope).base64EncodedString()
        let wrongShop = try JSONDecoder().decode(PendingOperation.self,from:demandData(corrupted))
        XCTAssertThrowsError(try operation.sharedDemandBinding?.validate(wrongShop))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:directory) }
        let outbox = OperationOutbox(url:directory.appendingPathComponent("outbox.json")); try await outbox.append(operation)
        do { _ = try await service.executeSharedDemand(operation); XCTFail("lost response must remain pending") } catch {}
        service = HouseholdService(configuration:config,auth:auth,deviceVault:vault,transport:transport()); _ = try await service.enroll(householdID:household)
        let restored = try await OperationOutbox(url:directory.appendingPathComponent("outbox.json")).operations()
        XCTAssertEqual(restored,[operation]); let acknowledged = try await service.executeSharedDemand(try XCTUnwrap(restored.first))
        XCTAssertEqual(acknowledged.operationId,operationID.string); XCTAssertEqual(commands,[operation.bytes,operation.bytes])
        let page = try await service.sharedDemand(shopID:shop); XCTAssertEqual(page.graph,after); XCTAssertEqual(page.totals.first?.quantity,try SharedDemandAmount(numerator:12))
        wrongReceipt = true
        do { _ = try await service.executeSharedDemand(operation); XCTFail("wrong reserved operation acknowledged") } catch { XCTAssertEqual(error as? ClientError,.invalidResponse) }
        deny = true; let count = commands.count
        do { _ = try await service.executeSharedDemand(operation); XCTFail("revoked shopper sent command") } catch {}
        XCTAssertEqual(commands.count,count)
    }
}
