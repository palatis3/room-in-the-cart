import XCTest
import HouseholdClient
@testable import RoomInTheCart

@MainActor final class SharedMessageSafetyTests: XCTestCase {
    private let id = "254fbd38-a310-490f-b396-634f33a41627"

    private func wire(_ action: SharedContentAction) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(action)) as? [String: Any])
    }
    private func receipt(_ status: String) throws -> SharedContentReceipt {
        try JSONDecoder().decode(SharedContentReceipt.self, from: JSONSerialization.data(withJSONObject: ["status":status,"receiptId":id]))
    }

    func testOptionalExcerptAndBlockSendOnlyTheSelectedReference() throws {
        let field = try XCTUnwrap(SharedMessageField(.instruction, id, 3, .action, "  Conservar el limón.  ", index: 2))
        let report = try wire(.report(source: field.source, reason: .unsafe, excerpt: nil))
        XCTAssertEqual(Set(report.keys), ["clientKey","action","source","reason"])
        let reference = try XCTUnwrap(report["source"] as? [String:Any])
        XCTAssertEqual(Set(reference.keys), ["kind","id","field","index","revision"])
        XCTAssertEqual(reference["index"] as? Int, 2)
        let reviewed = try wire(.report(source: field.source, reason: .unsafe, excerpt: field.wording))
        XCTAssertEqual(reviewed["text"] as? String, "  Conservar el limón.  ")
        let blocked = try wire(.block(source: field.source))
        XCTAssertEqual(Set(blocked.keys), ["clientKey","action","source"])
        XCTAssertNil(SharedMessageField(.clarification, id, 1, .question, "question", index: 0))
        XCTAssertNil(SharedMessageField(.request, id, 1, .correction, "other field"))
        XCTAssertNil(SharedMessageField(.suggestion, id, 0, .correction, "legacy suggestion"))
    }

    func testLostReportReplyRequiresTheSameActionAndKeyBeforeShowingReceipt() async throws {
        let field = try XCTUnwrap(SharedMessageField(.request, id, 1, .item, "Exact reviewed wording"))
        let report = SharedContentAction.report(source: field.source, reason: .other, excerpt: nil)
        let sessionReviews = SharedSafetyReviews()
        let review = sessionReviews.review(for: field.source)
        var sends: [SharedContentAction] = []
        let channel = SharedSafetyChannel(generation: UUID(), scoped: { true }, send: { action in
            sends.append(action)
            if sends.count == 1 { throw ClientError.transport }
            return try self.receipt("received")
        }, refreshAfterBlock: {})
        await review.submit(report, through: channel)
        XCTAssertEqual(review.status, .retry)
        XCTAssertEqual(review.pending, report)
        XCTAssertTrue(sessionReviews.review(for: field.source) === review)
        await review.submit(.block(source: field.source), through: channel)
        XCTAssertEqual(sends, [report])
        await review.submit(report, through: channel)
        XCTAssertEqual(sends, [report, report])
        XCTAssertEqual(review.status, .reported)
        XCTAssertNil(review.pending)
        sessionReviews.clear()
        XCTAssertEqual(sessionReviews.review(for: field.source).status, .ready)
    }

    func testWrongReceiptAndRevokedSessionCannotConfirmABlock() async throws {
        let source = try XCTUnwrap(SharedMessageField(.suggestion, id, 2, .correction, "Exact")).source
        let review = SharedSafetyReview()
        var live = true
        var attempts = 0
        let channel = SharedSafetyChannel(generation: UUID(), scoped: { live }, send: { _ in
            attempts += 1
            if attempts == 2 { live = false }
            return try self.receipt(attempts == 1 ? "received" : "blocked")
        }, refreshAfterBlock: {})
        let action = SharedContentAction.block(source: source)
        await review.submit(action, through: channel)
        XCTAssertEqual(review.status, .retry)
        await review.submit(action, through: channel)
        XCTAssertEqual(review.status, .unavailable)
        XCTAssertNil(review.pending)
    }

    func testChildCapabilityAllowsOnlyRequestAndOptionalSafetyAccess() throws {
        func bootstrap(_ capabilities: [String]) throws -> HouseholdBootstrap {
            try JSONDecoder().decode(HouseholdBootstrap.self, from: JSONSerialization.data(withJSONObject:
                ["household":["id":id,"label":"Fictional"],"memberId":id,"role":"contributor",
                 "enrolled":true,"queueConsent":false,"capabilities":capabilities]))
        }
        let legacy = try bootstrap(["own_requests"])
        XCTAssertTrue(legacy.hasOnlyChildRequestCapabilities)
        XCTAssertFalse(legacy.supportsSharedContentSafety)
        XCTAssertTrue(try bootstrap(["shared_content_safety", "own_requests"]).hasOnlyChildRequestCapabilities)
        XCTAssertFalse(try bootstrap(["own_requests", "household_admin"]).hasOnlyChildRequestCapabilities)
        XCTAssertFalse(try bootstrap(["shared_content_safety"]).hasOnlyChildRequestCapabilities)
    }
}
