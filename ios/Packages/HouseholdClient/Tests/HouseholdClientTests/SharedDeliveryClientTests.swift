import Foundation
import os
import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    func testDeliveryPaginationKeepsSealedLinesAndRejectsStaleOrDuplicatedSources() async throws {
        let actor = try auth(), id = UUID().uuidString.lowercased(), line = UUID().uuidString
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!),
                                       auth: actor, deviceVault: MemoryVault(), transport: transport())
        let ids = (0..<51).map { _ in UUID().uuidString.lowercased() }.sorted()
        enum PageScenario: Sendable { case valid, changedCapability, changedRevision, duplicate, orphanedMatch }
        let scenario = OSAllocatedUnfairLock(initialState: PageScenario.valid)
        MockURLProtocol.handler = { request in
            if let reply = self.authResponse(request) { return reply }
            let url = try XCTUnwrap(request.url)
            func response(_ body: [String: Any]) throws -> (Int, Data) {
                (200, try JSONSerialization.data(withJSONObject: body))
            }
            if url.path.hasSuffix("/devices") { return try response(["deviceId":"dev","deviceToken":"token"]) }
            if url.path.hasSuffix("/bootstrap") {
                return try response(["household":["id":self.household,"label":"Household"],"memberId":self.member,"role":"shopper",
                    "shopId":id,"enrolled":true,"queueConsent":false,"capabilities":["shopper_inbox","request_preview","shopper_commands","delivery_evidence"]])
            }
            XCTAssertTrue(url.path.hasSuffix("/delivery-evidence"))
            let cursor = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
            if let cursor { XCTAssertEqual(cursor, ids[49]) }
            let pageScenario = scenario.withLock { $0 }
            let slice = cursor == nil ? Array(ids.prefix(50)) : [pageScenario == .duplicate ? ids[0] : ids[50]]
            let rows: [[String:Any]] = slice.map { ["sourceId":$0,"foodId":$0,"lineId":line,"segmentKey":$0,"foodName":"Beans",
                "exclusionTags":[],"matches":pageScenario == .orphanedMatch ? [["occurrenceId":line,"mealRevision":1,"ingredientId":line]] : [],"arrival":NSNull(),"usable":NSNull(),"confirmed":NSNull()] }
            var page: [String: Any] = ["shopId":id,"shopRevision":4,"placedRevision":3,"authorityEpoch":1,
                "supplyRevision":cursor != nil && pageScenario == .changedRevision ? 52 : 51,"sources":rows,
                "lines":cursor == nil ? [["lineId":line,"name":"Sealed beans"]] : [],
                "nextCursor":cursor == nil ? ids[49] as Any : NSNull() as Any]
            if pageScenario == .changedCapability && cursor != nil { page["reservationsAvailable"] = true }
            return try response(page)
        }
        _ = try await actor.verifyEmailCode(email:"adult@example.test",code:"123456")
        _ = try await service.enroll(householdID: household)
        let record = try await service.deliveryEvidence(shopID: id)
        XCTAssertEqual(record.sources.map { $0.id.uuidString.lowercased() }, ids)
        XCTAssertEqual(record.lines.first?.name, "Sealed beans")
        XCTAssertNil(record.nextCursor)
        scenario.withLock { $0 = .changedCapability }
        do { _ = try await service.deliveryEvidence(shopID: id); XCTFail("Accepted a changed reservation capability across pages") }
        catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        scenario.withLock { $0 = .changedRevision }
        do { _ = try await service.deliveryEvidence(shopID: id); XCTFail("Accepted different supply revisions") }
        catch { XCTAssertEqual(error as? ClientError, .service(status:409, code:"stale_supply", correlationID:nil, retryAfter:nil)) }
        scenario.withLock { $0 = .duplicate }
        do { _ = try await service.deliveryEvidence(shopID: id); XCTFail("Counted one source twice") }
        catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        scenario.withLock { $0 = .orphanedMatch }
        do { _ = try await service.deliveryEvidence(shopID: id); XCTFail("Accepted a match to an absent meal revision") }
        catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
    }
}

extension HouseholdClientTests {
    func testCoverageRequiresAllSealedRowsAndCurrentReviewedPhysicalSources() throws {
        let shop = UUID().uuidString, occurrence = UUID().uuidString, ingredient = UUID().uuidString
        let source = UUID().uuidString, line = UUID().uuidString, arrival = UUID().uuidString, usable = UUID().uuidString
        let quantity: [String:Any] = ["amount":["numerator":2,"denominator":1],"unit":"count","originalLiteral":"2"]
        let target: [String:Any] = ["occurrenceId":occurrence,"mealRevision":1,"ingredientId":ingredient]
        let plan: [String:Any] = ["groups":[],"ingredients":[["id":ingredient,"name":"Wraps","quantity":quantity,"exclusions":[],"groupIds":[]]]]
        let meal: [String:Any] = ["title":"Wraps","day":"2026-11-07","kind":"dinner","portions":2,"protected":false,"planning":plan]
        let physical: [String:Any] = ["sourceId":source,"foodId":source,"lineId":line,"segmentKey":source,"foodName":"Wraps",
            "exclusionTags":[],"matches":[target],"arrival":["observationId":arrival,"sourceId":source,"received":quantity],
            "usable":["observationId":usable,"sourceId":source,"arrivalObservationId":arrival,"confirmedAt":"2026-11-07T12:00:00Z","usable":quantity],
            "confirmed":["sourceId":source,"foodId":source,"quantity":quantity,"arrivalId":arrival,"usableId":usable]]
        let revisions: [String:Any] = ["shopId":shop,"shopRevision":2,"placedRevision":1,"authorityEpoch":1,"supplyRevision":7]
        var pageJSON = revisions
        pageJSON["meals"] = [["occurrenceId":occurrence,"revision":1,"meal":meal]]
        pageJSON["sources"] = [physical]; pageJSON["lines"] = [["lineId":line,"name":"Wraps"]]
        let page = try JSONDecoder().decode(SharedDeliveryPage.self, from: JSONSerialization.data(withJSONObject: pageJSON))
        let two = ["numerator":"2","denominator":"1"]
        var row = target
        row["groupIds"] = []; row["protected"] = false; row["required"] = quantity
        row["covered"] = two; row["missing"] = ["numerator":"0","denominator":"1"]; row["issues"] = []
        row["allocations"] = [["sourceId":source,"amount":two]]
        func validate(_ rows: [[String:Any]], revision: Int = 7) throws {
            var payload = revisions
            payload["asOf"] = "2026-11-07T12:00:00Z"; payload["unplannedOccurrenceIds"] = []
            payload["needs"] = rows; payload["supplyRevision"] = revision
            try JSONDecoder().decode(SharedDeliveryCoverage.self, from: JSONSerialization.data(withJSONObject: payload)).validate(reviewed: page)
        }
        try validate([row])
        XCTAssertThrowsError(try validate([]))
        XCTAssertThrowsError(try validate([row,row]))
        XCTAssertThrowsError(try validate([row], revision: 6))
        var malformed = row
        malformed["covered"] = ["numerator":"2","denominator":"0"]
        XCTAssertThrowsError(try validate([malformed]))
        malformed = row
        malformed["allocations"] = [["sourceId":UUID().uuidString,"amount":two]]
        XCTAssertThrowsError(try validate([malformed]))
    }
}
