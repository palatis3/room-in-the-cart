import CoreDomain
import HouseholdClient
import XCTest
@testable import RoomInTheCart

@MainActor final class FoodKeeperMatchTests: XCTestCase {
    func testAdultSelectedWordingReturnsOnlyAnOfferedFoodThroughAuthenticatedTransport() async throws {
        let server = S24FixtureServer()
        defer { server.close() }
        let wire = HTTPTransport(session: server.makeSession())
        let auth = AdultAuth(configuration: try .init(projectURL: server.baseURL, publishableKey: "sb_publishable_fixture_only"),
                             vault: S24FixtureVault(), transport: wire)
        let client = HouseholdService(configuration: try .init(baseURL: server.baseURL), auth: auth, deviceVault: S24FixtureVault(), transport: wire)
        _ = try await auth.verifyEmailCode(email: "adult@example.invalid", code: "123456")
        _ = try await client.enroll(householdID: S24FixtureServer.household)
        let reference = try FoodKeeperReference.bundled()
        let food = try XCTUnwrap(reference.products.first { $0.id == 142 })
        let actor = CapturePrivateIdentity(actorID: UUID(), subject: "fixture-adult", householdID: S24FixtureServer.household,
                                          memberID: S24FixtureServer.member, role: "shopper")
        let scope = ReceiptAssistanceScope(subject: "fixture-adult", householdID: S24FixtureServer.household,
                                          memberID: S24FixtureServer.member, shopID: S24FixtureServer.shop)
        let origin = PantryDigestScope(origin: UUID(), identity: actor)
        func basis(revision: Int64, lotID: UUID, choices: [FoodKeeperMatchChoice]) -> FoodKeeperMatchBasis {
            .init(actor: actor, scope: scope, pantry: origin, lotID: lotID, lotRevision: revision,
                  catalogVersion: reference.version, locale: "es", candidates: choices)
        }
        let lotID = UUID()
        let choices = [FoodKeeperMatchChoice(id: food.id, label: food.name(.spanish))]
        let original = basis(revision: 3, lotID: lotID, choices: choices)
        let selected = "pollo enlatado"
        let consent = try FoodKeeperMatchConsent(basis: original, wording: selected)
        let lineID = try XCTUnwrap(consent.request.sourceLines.first?.id)
        server.intercept = { call in
            guard call.request.url?.path.hasSuffix("/language-assistance/foodkeeper-match") == true else { return false }
            do {
                let response: [String:Any]
                if call.request.httpMethod == "GET" {
                    response = ["version":1,"available":true]
                } else {
                    XCTAssertEqual(call.request.value(forHTTPHeaderField: "Authorization"),"Bearer fixture-access")
                    var bytes = call.request.httpBody ?? Data()
                    if bytes.isEmpty, let stream = call.request.httpBodyStream {
                        stream.open(); defer { stream.close() }
                        var b = [UInt8](repeating: 0, count: 1024)
                        while true { let n = stream.read(&b, maxLength: b.count); if n <= 0 { break }; bytes.append(contentsOf: b.prefix(n)) }
                    }
                    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String:Any])
                    XCTAssertEqual(Set(object.keys), ["version","requestID","issuedAt","consent","locale","sourceLines","catalogVersion","candidates"])
                    XCTAssertEqual((object["sourceLines"] as? [[String:String]])?.first?["text"], selected)
                    XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(lotID.uuidString))
                    response = ["version":1,"requestID":consent.request.requestID.uuidString,"catalogVersion":128,
                                "suggestions":[["sourceLineID":lineID.uuidString,"candidateID":142]]]
                }
                let headers = HTTPURLResponse(url: call.request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
                call.client?.urlProtocol(call, didReceive: headers, cacheStoragePolicy: .notAllowed)
                call.client?.urlProtocol(call, didLoad: try JSONSerialization.data(withJSONObject: response))
                call.client?.urlProtocolDidFinishLoading(call)
            } catch { call.client?.urlProtocol(call, didFailWithError: error) }
            return true
        }
        let available = try await client.languageAssistanceAvailable(purpose: "foodkeeper-match", scope: scope)
        XCTAssertTrue(available)
        let reply: FoodKeeperMatchReply = try await client.languageSuggestion(purpose: "foodkeeper-match", body: consent.wireData(), scope: scope)
        XCTAssertEqual(try reply.match(for: consent, current: original, wording: selected), food.id)
        for stale in [nil, basis(revision: 4, lotID: lotID, choices: choices), basis(revision: 3, lotID: UUID(), choices: choices),
                      basis(revision: 3, lotID: lotID, choices: [])] {
            XCTAssertThrowsError(try reply.match(for: consent, current: stale, wording: selected))
        }
        XCTAssertThrowsError(try reply.match(for: consent, current: original, wording: "texto cambiado"))
        XCTAssertThrowsError(try reply.match(for: consent, current: original, wording: selected, now: Date().addingTimeInterval(301)))
        let day = try MealDay(date: Date(), timeZoneIdentifier: "America/New_York")
        XCTAssertNil(reference.reviewedRange(productID: food.id, condition: .refrigeratedOpened, storage: .refrigerator,
                                            event: .opened, start: day, asOf: day, historyConfirmed: false))
        XCTAssertNotNil(reference.reviewedRange(productID: food.id, condition: .refrigeratedOpened, storage: .refrigerator,
                                               event: .opened, start: day, asOf: day, historyConfirmed: true))
        let envelope: [String:Any] = ["version":1,"requestID":consent.request.requestID.uuidString,"catalogVersion":128]
        func decode(_ changes: [String:Any]) throws -> FoodKeeperMatchReply {
            try JSONDecoder().decode(FoodKeeperMatchReply.self, from: JSONSerialization.data(withJSONObject: envelope.merging(changes) { _, new in new }))
        }
        XCTAssertNil(try decode(["suggestions":[]]).match(for: consent, current: original, wording: selected))
        for invalid: [String:Any] in [["candidateID":2,"sourceLineID":lineID.uuidString],["candidateID":142,"sourceLineID":UUID().uuidString],
                                      ["candidateID":142,"sourceLineID":lineID.uuidString,"safety":"safe"]] {
            XCTAssertThrowsError(try decode(["suggestions":[invalid]]).match(for: consent, current: original, wording: selected))
        }
        XCTAssertThrowsError(try decode(["suggestions":[],"catalogVersion":127]).match(for: consent, current: original, wording: selected))
        XCTAssertThrowsError(try decode(["suggestions":[],"requestID":UUID().uuidString]).match(for: consent, current: original, wording: selected))
        XCTAssertThrowsError(try decode(["suggestions":[],"date":"today"]))
        let wrong = ReceiptAssistanceScope(subject: "other", householdID: scope.householdID, memberID: scope.memberID, shopID: scope.shopID)
        do {
            let _: FoodKeeperMatchReply = try await client.languageSuggestion(purpose: "foodkeeper-match", body: consent.wireData(), scope: wrong)
            XCTFail("The request requires its original adult scope")
        } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
    }
}
