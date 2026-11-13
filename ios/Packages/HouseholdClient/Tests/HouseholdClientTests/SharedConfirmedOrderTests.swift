import Foundation
import XCTest
@testable import HouseholdClient

private let confirmedShop = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let confirmedLine = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let confirmedActor = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
private func confirmedOrderFixture() -> [String: Any] {
    let line: [String:Any] = ["lineId":confirmedLine.uuidString.lowercased(),"originalItem":"Wraps","packs":2,"unitPriceMinor":300,"feeEligible":true]
    let quote: [String:Any] = ["currency":"USD","scope":"wholeCheckout","complete":true,"capMinor":NSNull(),"capScope":"wholeCheckout",
        "fee":["kind":"fixed","amountMinor":0],"taxesMinor":0,"depositsMinor":0,"discountsMinor":0,
        "observedAt":"2026-01-01T08:00:00.000Z","expiresAt":"2026-01-01T12:00:00.000Z"]
    return ["shopId":confirmedShop.uuidString.lowercased(),"shopRevision":3,"authorityEpoch":1,"placedRevision":3,
        "asOf":"2026-01-03T12:00:00.000Z","original":["lines":[line],"quote":quote,"snapshotCreatedAt":"2026-01-01T10:00:00.000Z"],
        "current":["lines":[line],"amendmentId":NSNull()],"amendments":[]]
}
private func confirmedPage(_ raw: [String:Any]) throws -> SharedConfirmedOrder {
    try JSONDecoder().decode(SharedConfirmedOrder.self, from: JSONSerialization.data(withJSONObject: raw))
}

extension HouseholdClientTests {
    func testConfirmedOrderReviewKeepsOriginalAndRequiresChangedIndependentEvidence() throws {
        let page = try confirmedPage(confirmedOrderFixture())
        try page.validate(shopID: confirmedShop)
        let instant = try XCTUnwrap(SharedConfirmedOrder.date("2026-01-02T10:00:00.000Z"))
        let changed = ShopperBasketLine(lineId:confirmedLine,originalItem:"Wraps",packs:5,unitPriceMinor:nil,feeEligible:true)
        let body = try SharedOrderConfirmation(reference:"Retailer ABC-51",confirmedAt:instant,lines:[changed]).body(reviewed:page,now:instant)
        XCTAssertEqual(body["placedRevision"],.integer(3)); XCTAssertEqual(body["predecessorId"],.null)
        XCTAssertEqual(page.original.lines.first?.packs,2)
        XCTAssertEqual(page.original.lines.first?.unitPriceMinor,300)
        XCTAssertThrowsError(try SharedOrderConfirmation(reference:"Retailer",confirmedAt:instant,lines:page.current.lines).body(reviewed:page,now:instant))
        XCTAssertThrowsError(try SharedOrderConfirmation(reference:" ",confirmedAt:instant,lines:[]).body(reviewed:page,now:instant))
        XCTAssertThrowsError(try SharedOrderConfirmation(reference:"Reference\nControl",confirmedAt:instant,lines:[]).body(reviewed:page,now:instant))
        XCTAssertThrowsError(try SharedOrderConfirmation(reference:"Retailer",confirmedAt:instant.addingTimeInterval(1),lines:[]).body(reviewed:page,now:instant))
        XCTAssertThrowsError(try SharedOrderConfirmation(reference:"Retailer",confirmedAt:instant,lines:[.init(lineId:confirmedLine,originalItem:"Different food",packs:1,unitPriceMinor:nil,feeEligible:false)]).body(reviewed:page,now:instant))
        XCTAssertNoThrow(try SharedOrderConfirmation(reference:"All cancelled",confirmedAt:instant,lines:[]).body(reviewed:page,now:instant))
    }
    func testConfirmedOrderChainRejectsRetiredIdentitiesWrongHeadsAndChangedNames() throws {
        let id = UUID().uuidString.lowercased()
        var raw = confirmedOrderFixture()
        let event: [String:Any] = ["amendmentId":id,"predecessorId":NSNull(),"retailerReference":"Cancelled by store",
            "confirmedAt":"2026-01-02T10:00:00.000Z","recordedAt":"2026-01-02T10:01:00.000Z",
            "actorId":confirmedActor.uuidString,"lines":[]]
        raw["shopRevision"] = 4; raw["amendments"] = [event]; raw["current"] = ["lines":[],"amendmentId":id]
        let page = try confirmedPage(raw); try page.validate(shopID:confirmedShop)
        let instant = try XCTUnwrap(SharedConfirmedOrder.date("2026-01-03T11:00:00.000Z"))
        XCTAssertThrowsError(try SharedOrderConfirmation(reference:"Reuse",confirmedAt:instant,lines:page.original.lines).body(reviewed:page,now:instant))
        let fresh = ShopperBasketLine(originalItem:"Wraps",packs:2,unitPriceMinor:nil,feeEligible:false)
        XCTAssertNoThrow(try SharedOrderConfirmation(reference:"New order line",confirmedAt:instant,lines:[fresh]).body(reviewed:page,now:instant))
        raw["current"] = ["lines":[],"amendmentId":UUID().uuidString]
        XCTAssertThrowsError(try confirmedPage(raw).validate(shopID:confirmedShop))
        raw["current"] = ["lines":[],"amendmentId":id]
        var broken=event;broken["predecessorId"]=UUID().uuidString;raw["amendments"]=[broken]
        XCTAssertThrowsError(try confirmedPage(raw).validate(shopID:confirmedShop))
        broken=event;broken["recordedAt"]="2026-01-01T10:00:00.000Z";raw["amendments"]=[broken]
        XCTAssertThrowsError(try confirmedPage(raw).validate(shopID:confirmedShop))
    }
    func testAmendmentReceiptMustMatchExactOperationPlacementEpochAndRevision() throws {
        let operation = UUID(), window = UUID().uuidString.lowercased()
        let envelope = CommandEnvelope(replayWindow:window,shopId:confirmedShop.uuidString.lowercased(),kind:"amendment.recordResponse",
            base:.init(shopRevision:3,authorityEpoch:1),body:["placedRevision":.integer(3)])
        var raw:[String:Any] = ["operationId":operation.uuidString,"amendmentId":operation.uuidString,"kind":envelope.kind,
            "shopId":envelope.shopId,"shopRevision":4,"authorityEpoch":1,"placedRevision":3,"disposition":"recorded"]
        func receipt() throws -> ShopperReceipt { try JSONDecoder().decode(ShopperReceipt.self,from:JSONSerialization.data(withJSONObject:raw)) }
        XCTAssertNoThrow(try receipt().validateAmendment(envelope))
        for key in ["placedRevision","authorityEpoch","shopRevision"] {
            let old=raw[key];raw[key]=99;XCTAssertThrowsError(try receipt().validateAmendment(envelope));raw[key]=old
        }
        raw["amendmentId"]=UUID().uuidString
        XCTAssertThrowsError(try receipt().validateAmendment(envelope))
    }
    func testConfirmedOrderReadRechecksShopperCapabilityAndResponseScope() async throws {
        let actor = try auth()
        let service = HouseholdService(configuration:try .init(baseURL:URL(string:"https://service.test")!),auth:actor,deviceVault:MemoryVault(),transport:transport())
        var allowed=true, wrongShop=false, reads=0
        MockURLProtocol.handler = { request in
            if let reply=self.authResponse(request) { return reply }
            let url=try XCTUnwrap(request.url)
            func response(_ body:[String:Any]) throws -> (Int,Data) { (200,try JSONSerialization.data(withJSONObject:body)) }
            if url.path.hasSuffix("/devices") { return try response(["deviceId":"device","deviceToken":"token"]) }
            if url.path.hasSuffix("/bootstrap") {
                return try response(["household":["id":self.household,"label":"Home"],"memberId":self.member,"role":"shopper",
                    "shopId":confirmedShop.uuidString.lowercased(),"enrolled":true,"queueConsent":false,
                    "capabilities":["shopper_inbox","request_preview","shopper_commands"] + (allowed ? ["confirmed_order"] : [])])
            }
            XCTAssertTrue(url.path.hasSuffix("/confirmed-order"));reads += 1
            var raw=confirmedOrderFixture();if wrongShop { raw["shopId"]=UUID().uuidString }
            return try response(raw)
        }
        _ = try await actor.verifyEmailCode(email:"adult@example.test",code:"123456")
        _ = try await service.enroll(householdID:household)
        let page=try await service.confirmedOrder(shopID:confirmedShop)
        XCTAssertEqual(page.current.lines.first?.packs,2);XCTAssertEqual(reads,1)
        allowed=false
        do { _ = try await service.confirmedOrder(shopID:confirmedShop);XCTFail("Capability was revoked") }
        catch { XCTAssertEqual(error as? ClientError,.accessEnded) }
        XCTAssertEqual(reads,1)
        allowed=true;wrongShop=true
        do { _ = try await service.confirmedOrder(shopID:confirmedShop);XCTFail("Wrong shop response") }
        catch { XCTAssertEqual(error as? ClientError,.invalidResponse) }
    }
}
