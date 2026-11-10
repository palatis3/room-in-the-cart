import XCTest
import HouseholdClient
@testable import RoomInTheCart

final class RequestDuplicateComparisonTests: XCTestCase {
    private func request(_ id: String, item: String = "Cereal", quantity: String? = "1 box", author: String = "Sam", status: String = "pending", route: String = "current", revision: Int = 1, shopID: String = "shop") throws -> OwnRequest {
        var row: [String: Any] = ["requestId":id, "shopId":shopID, "revision":revision, "originalItem":item,
            "authorAlias":author, "status":status, "route":route, "ownActionAllowed":status == "pending",
            "authoredAt":"2026-11-03T15:00:00Z", "receivedAt":"2026-11-03T15:01:00Z"]
        row["ownQuantity"] = quantity as Any? ?? NSNull()
        return try JSONDecoder().decode(OwnRequest.self,from:JSONSerialization.data(withJSONObject:row))
    }
    func testNonAdjacentNamesBecomeAdjacentWithoutLosingAuthorsUsesOrCompletedOutcomes() throws {
        let sam = try request("sam",quantity:"1 box for breakfasts")
        let wraps = try request("wraps",item:"Wraps",quantity:"8 for lunch")
        let lee = try request("lee",item:"CEREAL",quantity:"2 boxes for the school snack drive",author:"Lee",route:"next",revision:4)
        let pat = try request("pat",quantity:"1 for the weekend",author:"Pat",status:"handled")
        let original = [sam,wraps,lee,pat]
        let groups = RequestDuplicateGrouping.groups(requests:original,shopID:"shop",authorized:true)
        XCTAssertEqual(groups.count,2)
        XCTAssertEqual(groups[0].requests,[sam,lee,pat])
        XCTAssertEqual(groups[1].requests,[wraps])
        XCTAssertTrue(groups[0].hasPossibleDuplicates)
        XCTAssertFalse(groups[1].hasPossibleDuplicates)
        XCTAssertEqual(groups[0].requests.map(\.ownQuantity),["1 box for breakfasts","2 boxes for the school snack drive","1 for the weekend"])
        XCTAssertEqual(groups[0].requests.map(\.status),["pending","pending","handled"])
        XCTAssertEqual(groups.flatMap(\.requests).count,original.count)
        XCTAssertEqual(original,[sam,wraps,lee,pat])
    }
    func testMatchingChangesOnlyCaseWhitespaceAndCanonicalUnicodeNotMeaningfulWords() throws {
        let rows = try [request("a",item:"  CORN\nflakes "),request("b",item:"corn flakes"),
            request("c",item:"Corn flakes without nuts"),request("d",item:"Corn flakes for breakfast"),
            request("e",item:"Piñata"),request("f",item:"Pinata"),request("g",item:"Pinin\u{0303}ata")]
        let groups = RequestDuplicateGrouping.groups(requests:rows,shopID:"shop",authorized:true)
        XCTAssertEqual(groups[0].requests.map(\.id),["a","b"])
        XCTAssertEqual(groups.count,6)
        XCTAssertEqual(groups[0].requests[0].originalItem,"  CORN\nflakes ")
        let equivalent = try [request("nfc",item:"Piñata"),request("nfd",item:"Pin\u{0303}ata")]
        XCTAssertEqual(RequestDuplicateGrouping.groups(requests:equivalent,shopID:"shop",authorized:true).count,1)
    }
    func testAuthorizationShopIdentityAndEmptyNamesCannotCreatePrivateOrFalseGroups() throws {
        let rows = try [request("own"),request("other",shopID:"other-shop"),request("empty-a",item:" "),request("empty-b",item:"\n")]
        XCTAssertTrue(RequestDuplicateGrouping.groups(requests:rows,shopID:"shop",authorized:false).isEmpty)
        XCTAssertTrue(RequestDuplicateGrouping.groups(requests:rows,shopID:"",authorized:true).isEmpty)
        let groups = RequestDuplicateGrouping.groups(requests:rows,shopID:"shop",authorized:true)
        XCTAssertEqual(groups.flatMap(\.requests).map(\.id),["own","empty-a","empty-b"])
        XCTAssertTrue(groups.allSatisfy { !$0.hasPossibleDuplicates })
    }
    func testCursorOverlapUsesOneLatestRevisionPerRequestAndGroupIdentityStaysStable() throws {
        let old = try request("sam",revision:1)
        let latest = try request("sam",quantity:"3 boxes for guests",revision:2)
        let lee = try request("lee",author:"Lee")
        let before = RequestDuplicateGrouping.groups(requests:[old,lee],shopID:"shop",authorized:true)
        let after = RequestDuplicateGrouping.groups(requests:[old,latest,lee,old],shopID:"shop",authorized:true)
        XCTAssertEqual(after[0].requests,[latest,lee])
        XCTAssertEqual(before[0].id,after[0].id)
        XCTAssertEqual(after[0].requests.map(\.revision),[2,1])
    }
    #if DEBUG
    func testFixtureInterceptsUnexpectedNetworkDestinations() throws {
        let unexpected = URLRequest(url:URL(string:"https://example.com/inbox")!)
        XCTAssertTrue(S23DuplicateFixtureProtocol.canInit(with:unexpected))
        XCTAssertThrowsError(try S23DuplicateFixtureServer().respond(unexpected))
        let server = S23DuplicateFixtureServer()
        var tracking = URLRequest(url: URL(string: "https://s23-household.invalid/v1/households/" + S23DuplicateFixtureServer.householdID + "/shops/" + S23DuplicateFixtureServer.shopID + "/demand/tracking")!)
        tracking.httpMethod = "GET"
        let (status, bytes) = try server.respond(tracking)
        XCTAssertEqual(status, 200)
        let page = try SharedTrackingWire.page(from: bytes)
        XCTAssertEqual(page.status, .legacy); XCTAssertEqual(page.state?.graph.revision, 0)
        XCTAssertEqual(page.state?.legacyLineIds.map(\.string), [S23DuplicateFixtureServer.lineID])
        XCTAssertEqual(page.state?.basket.first?.name, "Cereal already in the basket")
        XCTAssertEqual(page.checkout.totalMinor, 349); XCTAssertEqual(server.commandCount, 0)

    }
    @MainActor func testDuplicateAcrossPageBoundaryCanBeReadWithoutChangingSelectedRequestOrWriting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let outboxURL = directory.appendingPathComponent("outbox.json")
        let server = S23DuplicateFixtureServer(pageBoundary:true)
        let model = try await s23DuplicateFixtureModel(server:server,outboxURL:outboxURL)
        let sam = try XCTUnwrap(model.requests.first { $0.id == S23DuplicateFixtureServer.samID })
        model.select(sam)
        XCTAssertNotNil(model.nextCursor)
        XCTAssertEqual(model.duplicateRequestGroup(containing:sam.id)?.requests.count,1)
        model.choice = .link; model.linkedLineID = S23DuplicateFixtureServer.lineID
        await model.load(more:true)
        XCTAssertNil(model.nextCursor)
        XCTAssertEqual(model.selected?.id,sam.id)
        XCTAssertEqual(model.choice,.link)
        XCTAssertEqual(model.linkedLineID,S23DuplicateFixtureServer.lineID)
        XCTAssertEqual(model.duplicateRequestGroup(containing:sam.id)?.requests.map(\.id),[sam.id,S23DuplicateFixtureServer.leeID,S23DuplicateFixtureServer.patID])
        XCTAssertEqual(server.previewCount,0); XCTAssertEqual(server.commandCount,0)
        let pending = try await OperationOutbox(url:outboxURL).operations()
        XCTAssertTrue(pending.isEmpty)
        model.cancelReview(); XCTAssertNil(model.selected)
        XCTAssertEqual(server.commandCount,0)
        model.clear()
        XCTAssertTrue(model.duplicateRequestGroups.isEmpty)
        XCTAssertNil(model.duplicateRequestGroup(containing:sam.id))
    }
    @MainActor func testExplicitDecisionsKeepSeparateOutcomesAndLinkNeverAddsOrSumsPacks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let server = S23DuplicateFixtureServer()
        let model = try await s23DuplicateFixtureModel(server:server,outboxURL:directory.appendingPathComponent("outbox.json"))
        let sam = try XCTUnwrap(model.requests.first { $0.id == S23DuplicateFixtureServer.samID })
        let lee = try XCTUnwrap(model.requests.first { $0.id == S23DuplicateFixtureServer.leeID })
        model.select(sam)
        _ = model.duplicateRequestGroups
        XCTAssertEqual(server.commandCount,0)
        model.choice = .link; model.linkedLineID = S23DuplicateFixtureServer.lineID
        await model.review()
        XCTAssertEqual(server.commandCount,0)
        XCTAssertEqual(model.preview?.changeMinor,0)
        XCTAssertTrue(model.canApply)
        await model.apply()
        XCTAssertEqual(server.appliedRequestIDs,[sam.id])
        XCTAssertEqual(model.requests.first { $0.id == sam.id }?.status,"added")
        XCTAssertEqual(model.requests.first { $0.id == lee.id },lee)
        XCTAssertEqual(model.shop?.lines.count,1)
        XCTAssertEqual(model.shop?.lines.first?.packs,1)
        XCTAssertEqual(model.duplicateRequestGroup(containing:sam.id)?.requests.count,3)
        model.select(try XCTUnwrap(model.requests.first { $0.id == lee.id }))
        model.choice = .deferRequest
        await model.review(); await model.apply()
        XCTAssertEqual(server.appliedRequestIDs,[sam.id,lee.id])
        XCTAssertEqual(model.requests.first { $0.id == sam.id }?.status,"added")
        XCTAssertEqual(model.requests.first { $0.id == lee.id }?.status,"deferred")
        XCTAssertEqual(model.requests.first { $0.id == S23DuplicateFixtureServer.patID }?.status,"handled")
        XCTAssertEqual(model.shop?.lines.first?.packs,1)
        await model.apply(); XCTAssertEqual(server.commandCount,2)
    }
    @MainActor func testClarificationUsesOnlySelectedRequestThenReviewedLinkKeepsOtherAuthorUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let server = S23DuplicateFixtureServer()
        let model = try await s23DuplicateFixtureModel(server:server,outboxURL:directory.appendingPathComponent("outbox.json"))
        let sam = try XCTUnwrap(model.requests.first { $0.id == S23DuplicateFixtureServer.samID })
        let lee = try XCTUnwrap(model.requests.first { $0.id == S23DuplicateFixtureServer.leeID })
        model.select(sam)
        model.clarification = "Will one box cover the breakfasts you requested?"
        XCTAssertEqual(server.commandCount,0)
        await model.sendClarification()
        let clarified = try XCTUnwrap(model.requests.first { $0.id == sam.id })
        XCTAssertEqual(clarified.status,"clarified")
        XCTAssertEqual(clarified.clarification,"Will one box cover the breakfasts you requested?")
        XCTAssertEqual(clarified.originalItem,sam.originalItem)
        XCTAssertEqual(clarified.ownQuantity,sam.ownQuantity)
        XCTAssertEqual(model.requests.first { $0.id == lee.id },lee)
        model.select(clarified)
        model.choice = .link; model.linkedLineID = S23DuplicateFixtureServer.lineID
        await model.review()
        XCTAssertEqual(server.commandCount,1)
        await model.apply()
        XCTAssertEqual(server.appliedRequestIDs,[sam.id,sam.id])
        XCTAssertEqual(model.requests.first { $0.id == sam.id }?.status,"added")
        XCTAssertEqual(model.requests.first { $0.id == lee.id },lee)
        XCTAssertEqual(model.shop?.lines.first?.packs,1)
    }
    #endif
}
