import Foundation
import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    func testDeliveryPaginationKeepsSealedLinesAndRejectsStaleOrDuplicatedSources() async throws {
        let actor = try auth(), id = UUID().uuidString.lowercased(), line = UUID().uuidString
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!),
                                       auth: actor, deviceVault: MemoryVault(), transport: transport())
        let ids = (0..<51).map { _ in UUID().uuidString.lowercased() }.sorted()
        var changed = false, duplicate = false
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
            let slice = cursor == nil ? Array(ids.prefix(50)) : [duplicate ? ids[0] : ids[50]]
            let rows: [[String:Any]] = slice.map { ["sourceId":$0,"foodId":$0,"lineId":line,"segmentKey":$0,"foodName":"Beans",
                "exclusionTags":[],"arrival":NSNull(),"usable":NSNull(),"confirmed":NSNull()] }
            return try response(["shopId":id,"shopRevision":4,"placedRevision":3,"authorityEpoch":1,
                "supplyRevision":cursor != nil && changed ? 52 : 51,"sources":rows,
                "lines":cursor == nil ? [["lineId":line,"name":"Sealed beans"]] : [],
                "nextCursor":cursor == nil ? ids[49] as Any : NSNull() as Any])
        }
        _ = try await actor.verifyEmailCode(email:"adult@example.test",code:"123456")
        _ = try await service.enroll(householdID: household)
        let record = try await service.deliveryEvidence(shopID: id)
        XCTAssertEqual(record.sources.map { $0.id.uuidString.lowercased() }, ids)
        XCTAssertEqual(record.lines.first?.name, "Sealed beans")
        XCTAssertNil(record.nextCursor)
        changed = true
        do { _ = try await service.deliveryEvidence(shopID: id); XCTFail("Accepted different supply revisions") }
        catch { XCTAssertEqual(error as? ClientError, .service(status:409, code:"stale_supply", correlationID:nil, retryAfter:nil)) }
        changed = false; duplicate = true
        do { _ = try await service.deliveryEvidence(shopID: id); XCTFail("Counted one source twice") }
        catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
    }
}
