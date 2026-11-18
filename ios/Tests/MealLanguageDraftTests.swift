import CoreDomain
import Foundation
import HouseholdClient
import XCTest
@testable import RoomInTheCart

@MainActor final class MealLanguageDraftTests: XCTestCase {
    private let account = ReceiptAssistanceScope(subject: "fixture-adult", householdID: S24FixtureServer.household,
        memberID: S24FixtureServer.member, shopID: S24FixtureServer.shop)

    private func basis(actor: UUID, workspace: UUID, selected: UUID, revision: UUID?, source: MealFeedbackSource? = nil) -> MealLanguageBasis {
        .init(account: account, destination: .personal(.init(actorID: actor, subject: account.subject,
            householdID: account.householdID, memberID: account.memberID, role: "shopper"),
            workspace: workspace, shop: selected, shopRevision: nil, source: source), revision: revision)
    }

    func testPrivateEnglishSpanishNotesUseScopedWireAndOnlyModifyReviewedDrafts() async throws {
        let server = S24FixtureServer()
        defer { server.close() }
        let transport = HTTPTransport(session: server.makeSession())
        let auth = AdultAuth(configuration: try .init(projectURL: server.baseURL, publishableKey: "sb_publishable_fixture_only"),
                             vault: S24FixtureVault(), transport: transport)
        let client = HouseholdService(configuration: try .init(baseURL: server.baseURL), auth: auth,
            deviceVault: S24FixtureVault(), transport: transport)
        _ = try await auth.verifyEmailCode(email: "person@example.invalid", code: "123456")
        _ = try await client.enroll(householdID: S24FixtureServer.household)
        let marks = basis(actor: UUID(), workspace: UUID(), selected: UUID(), revision: nil)
        var settings = MealPreferenceSettings()
        settings.exclusions = ["peanut"]; settings.timeLimit = .init(maximumMinutes: 20, strict: true)
        let cases: [(String, String, String, MealLanguageChoice, MealLanguageDraft)] = [
            ("en", "I dislike peas", "peas", .dislike, .preferences(settings)),
            ("es", "Sobró demasiado", "Sobró demasiado", .tooManyLeftovers, .feedback([.makeAgain]))]
        for (locale, note, quote, choice, base) in cases {
            let input = try LanguageAssistanceRequest(consentingTo: [.init(id: UUID(), text: note)], locale: locale)
            server.intercept = { call in
                guard call.request.url?.path.hasSuffix("/language-assistance/" + base.purpose) == true else { return false }
                do {
                    var response: [String: Any] = ["version": 1, "available": true]
                    if call.request.httpMethod == "POST" {
                        XCTAssertEqual(call.request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
                        var bytes = call.request.httpBody ?? Data()
                        if bytes.isEmpty, let stream = call.request.httpBodyStream {
                            stream.open(); defer { stream.close() }
                            var buffer = [UInt8](repeating: 0, count: 1024)
                            while stream.hasBytesAvailable {
                                let read = stream.read(&buffer, maxLength: buffer.count)
                                guard read > 0 else { break }
                                bytes.append(buffer, count: read)
                            }
                        }
                        let actual = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? NSDictionary)
                        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? NSDictionary)
                        XCTAssertEqual(actual, expected)
                        XCTAssertEqual(Set(actual.allKeys.compactMap { $0 as? String }), ["version","requestID","issuedAt","consent","locale","sourceLines"])
                        response = ["version":1, "requestID":input.requestID.uuidString, "suggestions":[
                            ["sourceLineID":input.sourceLines[0].id.uuidString, "kind":choice.rawValue, "quote":quote]]]
                    }
                    let http = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(call.request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
                    call.client?.urlProtocol(call, didReceive: http, cacheStoragePolicy: .notAllowed)
                    call.client?.urlProtocol(call, didLoad: try JSONSerialization.data(withJSONObject: response))
                    call.client?.urlProtocolDidFinishLoading(call)
                } catch { call.client?.urlProtocol(call, didFailWithError: error) }
                return true
            }
            let offered = try await client.languageAssistanceAvailable(purpose: base.purpose, scope: account)
            XCTAssertTrue(offered)
            let reply: MealLanguageReply = try await client.languageSuggestion(purpose: base.purpose, body: JSONEncoder().encode(input), scope: account)
            let reviewed = try XCTUnwrap(reply.review(for: input, basis: marks, draft: base))
            XCTAssertEqual(reviewed.sourceText, note); XCTAssertEqual(reviewed.quote, quote)
            let edited = try reviewed.applying(current: marks, draft: base, text: note)
            switch edited {
            case .preferences(let result):
                var expected = settings; expected.dislikes = ["peas"]
                XCTAssertEqual(result, expected)
            case .feedback(let result): XCTAssertEqual(result, [.makeAgain, .tooManyLeftovers])
            }
        }
        let en = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        let es = try XCTUnwrap(Bundle.main.path(forResource: "es", ofType: "lproj").flatMap(Bundle.init(path:)))
        for key in ["Soft preference · disliked ingredient", "Meal feedback · too many leftovers", "Review the proposed addition"] {
            XCTAssertEqual(en.localizedString(forKey: key, value: "missing", table: "Dinners"), key)
            let spanish = es.localizedString(forKey: key, value: "missing", table: "Dinners")
            XCTAssertNotEqual(spanish, key); XCTAssertNotEqual(spanish, "missing")
        }
    }

    func testHouseholdPreferenceWordingRequiresSameOrganizerDeviceGrantAndReviewedRevision() throws {
        let house = UUID(), member = UUID(), device = UUID(), profileRevision = UUID(), enrollment = UUID(), generation = UUID()
        func scope(admin: Bool = true, enrolled: UUID? = nil) -> HouseholdPreferenceScope {
            .init(generation: generation, enrollment: enrolled ?? enrollment, subject: "adult",
                  householdID: house.uuidString, memberID: member.uuidString, administer: admin)
        }
        func session(_ deviceID: UUID, householdID: UUID? = nil) throws -> HouseholdDeviceSession {
            try JSONDecoder().decode(HouseholdDeviceSession.self, from: JSONEncoder().encode(
                ["householdID": householdID ?? house, "memberID": member, "deviceID": deviceID]))
        }
        func page(epoch: Int = 4, write: Bool = true, revision: UUID? = nil) throws -> HouseholdPreferencePage<MealPreferenceSettings> {
            let values: [String: Any] = ["v": 1, "householdId": house.uuidString, "grantEpoch": epoch, "canWrite": write,
                                         "revision": (revision ?? profileRevision).uuidString, "supportsTimeLimit": true]
            return try JSONDecoder().decode(HouseholdPreferencePage<MealPreferenceSettings>.self, from: JSONSerialization.data(withJSONObject: values))
        }
        let deviceSession = try session(device), original = try page()
        func marks(_ page: HouseholdPreferencePage<MealPreferenceSettings>, _ session: HouseholdDeviceSession,
                   _ scope: HouseholdPreferenceScope) -> MealLanguageBasis? {
            .householdPreferences(scope: scope, session: session, page: page, revision: profileRevision, selectedShop: nil)
        }
        let base = try XCTUnwrap(marks(original, deviceSession, scope()))
        XCTAssertNil(marks(original, deviceSession, scope(admin: false)))
        XCTAssertNil(try marks(page(write: false), deviceSession, scope()))
        XCTAssertNil(try marks(page(revision: UUID()), deviceSession, scope()))
        XCTAssertNil(try marks(original, session(device, householdID: UUID()), scope()))

        var settings = MealPreferenceSettings()
        settings.exclusions = ["peanut"]
        let draft = MealLanguageDraft.preferences(settings)
        let input = try LanguageAssistanceRequest(consentingTo: [.init(id: UUID(), text: "Prefiero marca Nube")], locale: "es")
        let reply = MealLanguageReply(version: 1, requestID: input.requestID, suggestions: [
            .init(sourceLineID: input.sourceLines[0].id, kind: .preferredBrand, quote: "Nube")])
        let review = try XCTUnwrap(reply.review(for: input, basis: base, draft: draft))
        for changed in [try marks(page(epoch: 5), deviceSession, scope()), try marks(original, session(UUID()), scope()),
                        marks(original, deviceSession, scope(enrolled: UUID())), nil] {
            XCTAssertThrowsError(try review.applying(current: changed, draft: draft, text: input.sourceLines[0].text))
        }
        settings.preferredBrands = ["Nube"]
        XCTAssertEqual(try review.applying(current: base, draft: draft, text: input.sourceLines[0].text), .preferences(settings))
    }

    func testHardSettingsStaleAdultSelectionRevisionAndEditedWordsRefuseDraftAdoption() throws {
        let actor = UUID(), workspace = UUID(), selected = UUID(), revision = UUID()
        let current = basis(actor: actor, workspace: workspace, selected: selected, revision: revision)
        let input = try LanguageAssistanceRequest(consentingTo: [.init(id: UUID(), text: "Prefer Acme")], locale: "en")
        let reply = MealLanguageReply(version: 1, requestID: input.requestID, suggestions: [
            .init(sourceLineID: input.sourceLines[0].id, kind: .preferredBrand, quote: "Acme")])
        var strict = MealPreferenceSettings()
        strict.preferredBrands = ["Existing brand"]; strict.strictBrands = true
        XCTAssertThrowsError(try reply.review(for: input, basis: current, draft: .preferences(strict)))
        let base = MealLanguageDraft.preferences(.init())
        let review = try XCTUnwrap(reply.review(for: input, basis: current, draft: base))
        let changed = [basis(actor: UUID(), workspace: workspace, selected: selected, revision: revision),
            basis(actor: actor, workspace: workspace, selected: UUID(), revision: revision),
            basis(actor: actor, workspace: workspace, selected: selected, revision: UUID()),
            basis(actor: actor, workspace: workspace, selected: selected, revision: revision, source: .recipe(id: UUID(), revision: 1))]
        for other in changed { XCTAssertThrowsError(try review.applying(current: other, draft: base, text: "Prefer Acme")) }
        XCTAssertThrowsError(try review.applying(current: nil, draft: base, text: "Prefer Acme"))
        XCTAssertThrowsError(try review.applying(current: current, draft: .preferences(strict), text: "Prefer Acme"))
        XCTAssertThrowsError(try review.applying(current: current, draft: base, text: "Prefer Acme now"))
        XCTAssertThrowsError(try reply.review(for: input, basis: current, draft: .feedback([])))
        let fabricated = MealLanguageReply(version: 1, requestID: input.requestID, suggestions: [
            .init(sourceLineID: input.sourceLines[0].id, kind: .dislike, quote: "peanut")])
        XCTAssertThrowsError(try fabricated.review(for: input, basis: current, draft: base))
    }
}
