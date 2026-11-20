import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    func connectAdultPickup(shop: UUID, capabilities: [String], role: String = "contributor", handle: @escaping MockURLProtocol.Handler) async throws -> (HouseholdService, AdultShopRequestSession) {
        let auth = try auth()
        let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!),
                                       auth: auth, deviceVault: MemoryVault(), transport: transport())
        let device = UUID()
        MockURLProtocol.handler = { request in
            if let response = self.authResponse(request) { return response }
            let path = try XCTUnwrap(request.url?.path)
            if path.hasSuffix("/devices") {
                return (201, try JSONSerialization.data(withJSONObject: ["deviceId": device.uuidString, "deviceToken": "token"]))
            }
            if path.hasSuffix("/bootstrap") {
                return (200, try JSONSerialization.data(withJSONObject: [
                    "household": ["id": self.household, "label": "Home"], "memberId": self.member, "enrolled": true,
                    "shopId": request.value(forHTTPHeaderField: "X-Shop-ID") ?? shop.uuidString,
                    "role": role, "capabilities": capabilities, "queueConsent": false
                ]))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Token"), "token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Shop-ID"), shop.uuidString.lowercased())
            XCTAssertNil(request.value(forHTTPHeaderField: "X-View-Grant-ID"))
            return try handle(request)
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456")
        let projection = try await service.enroll(householdID: household)
        return (service, try await service.adultShopRequestSession(projection, shopID: shop))
    }

    func testAdultPickupLastCallUsesReviewedCutoffAndRejectsChangedEnrollment() async throws {
        let shop = UUID(), cutoff = Date(timeIntervalSince1970: 2_000_000_000)
        let iso = ISO8601DateFormatter().string(from: cutoff)
        func result(_ managed: Bool, _ revision: Int, responded: Bool = false, muted: Bool = false) throws -> (Int, Data) {
            (200, try JSONSerialization.data(withJSONObject: ["managed": managed, "revision": revision, "responded": responded,
                                                                "muted": muted, "nextShopOnly": false, "cutoffAt": iso]))
        }
        let lock = NSLock()
        var manager = true
        let (service, session) = try await connectAdultPickup(shop: shop, capabilities: ["adult_last_call"]) { req in
            if req.url!.path.hasSuffix("/response") {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: mockRequestBody(req)) as? [String: Any])
                XCTAssertEqual(Set(body.keys), ["revision", "action"])
                XCTAssertEqual(body["revision"] as? Int, 3)
                let action = try XCTUnwrap(body["action"] as? String)
                return try result(false, 3, responded: action == "pass", muted: action == "mute")
            }
            XCTAssertTrue(req.url!.path.hasSuffix("/shops/" + shop.uuidString.lowercased() + "/last-call"))
            if req.httpMethod == "GET" { return try result(lock.withLock { manager }, 3) }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: mockRequestBody(req)) as? [String: Any])
            XCTAssertEqual(Set(body.keys), ["expectedRevision", "cutoffAt", "authorityEpoch"])
            XCTAssertEqual(body["authorityEpoch"] as? Int, 4)
            XCTAssertEqual(body["expectedRevision"] as? Int, 3)
            XCTAssertEqual(body["cutoffAt"] as? String, iso)
            return try result(true, 4)
        }
        let current = try await service.lastCall(in: session)
        let updated = try await service.publishLastCall(in: session, reviewed: current, authorityEpoch: 4, cutoffAt: cutoff)
        XCTAssertEqual(updated.revision, 4)
        XCTAssertEqual(updated.cutoff, cutoff)
        lock.withLock { manager = false }
        let invitation = try await service.lastCall(in: session)
        for action in [LastCallResponse.pass, .mute, .unmute] {
            let response = try await service.respondToLastCall(action, in: session, reviewed: invitation)
            XCTAssertEqual(response.responded, action == .pass)
            XCTAssertEqual(response.muted, action == .mute)
        }
        _ = try await service.selectShop(UUID())
        do { _ = try await service.lastCall(in: session); XCTFail("An earlier shop selection survived") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
    }

    func testAdultProductReferenceSharesOnlyReviewedRecipientAndCrop() async throws {
        let shop = UUID(), request = UUID(), recipient = UUID(), key = UUID()
        let crop = try ProductReferenceCrop(width: 8, height: 8, pixels: Data(repeating: 101, count: 192))
        let reference = try AdultProductReference(brand: " Verde ", size: "12 oz", barcode: "001234567890",
                                                  description: "Green cap", crop: crop)
        let (service, session) = try await connectAdultPickup(shop: shop, capabilities: ["adult_product_reference", "adult_product_reference_media"]) { req in
            var page: [String: Any] = ["requestRevision": 7, "authorityEpoch": 2, "recipientId": recipient.uuidString,
                                      "recipientLabel": "Robin", "revision": 0, "own": true]
            if req.url!.path.hasSuffix("/remove") {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: mockRequestBody(req)) as? [String: Any])
                XCTAssertEqual(Set(body.keys), ["expectedRevision", "clientKey"])
                XCTAssertEqual(body["expectedRevision"] as? Int, 1)
                page["revision"] = 2
            } else {
                XCTAssertTrue(req.url!.path.hasSuffix("/requests/" + request.uuidString.lowercased() + "/product-reference"))
                if req.httpMethod == "POST" {
                    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: mockRequestBody(req)) as? [String: Any])
                    XCTAssertEqual(Set(body.keys), ["expectedRevision","requestRevision","authorityEpoch","recipientId","clientKey","consent","reference"])
                    XCTAssertEqual(body["recipientId"] as? String, recipient.uuidString)
                    XCTAssertEqual(body["requestRevision"] as? Int, 7)
                    XCTAssertEqual(body["expectedRevision"] as? Int, 0)
                    XCTAssertEqual(body["authorityEpoch"] as? Int, 2)
                    XCTAssertEqual(body["clientKey"] as? String, key.uuidString)
                    XCTAssertEqual(body["consent"] as? Bool, true)
                    var facts = try XCTUnwrap(body["reference"] as? [String: Any])
                    XCTAssertEqual(Set(facts.keys), ["brand","size","barcode","description","crop"])
                    XCTAssertEqual(facts["brand"] as? String, "Verde")
                    XCTAssertEqual(facts["barcode"] as? String, "001234567890")
                    let raw = try XCTUnwrap(facts["crop"] as? [String: Any])
                    XCTAssertEqual(Set(raw.keys), ["width","height","pixels"])
                    XCTAssertEqual(raw["pixels"] as? String, crop.pixels.base64EncodedString())
                    facts["mediaStatus"] = "pending"
                    page["expiresAt"] = "2099-10-10T18:00:00Z"; page["revision"] = 1; page["reference"] = facts
                }
            }
            return (200, try JSONSerialization.data(withJSONObject: page))
        }
        let original = try await service.productReference(request, in: session)
        let result = try await service.saveProductReference(reference, request: request, in: session, reviewed: original, clientKey: key)
        XCTAssertEqual(result.reference?.mediaStatus, "pending")
        XCTAssertEqual(result.reference?.crop, crop)
        let removed = try await service.removeProductReference(request, in: session, reviewed: result, clientKey: UUID())
        XCTAssertNil(removed.reference)
    }

    func testAdultProductReferenceRejectsUnapprovedPixelsAndWrongRecipient() async throws {
        let shop = UUID(), request = UUID(), pixels = Data(repeating: 5, count: 192).base64EncodedString()
        let lock = NSLock()
        var status = "pending", recipient = member
        let (service, session) = try await connectAdultPickup(shop: shop, capabilities: ["adult_product_reference", "adult_product_reference_media"]) { req in
            if req.url!.path.hasSuffix("/moderation") {
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: mockRequestBody(req)) as? [String: Any])
                let reporting = body["action"] as? String == "report"
                XCTAssertEqual(Set(body.keys), reporting ? ["expectedRevision", "clientKey", "action", "reason"] : ["expectedRevision", "clientKey", "action"])
                XCTAssertEqual(body["expectedRevision"] as? Int, 4)
                if reporting { XCTAssertEqual(body["reason"] as? String, "unsafe") }
                return (200, try JSONSerialization.data(withJSONObject: ["status": reporting ? "received" : "blocked"]))
            }
            let (media, target) = lock.withLock { (status, recipient) }
            return (200, try JSONSerialization.data(withJSONObject: [
                "requestRevision": 8, "authorityEpoch": 3, "recipientId": target, "recipientLabel": "Shopper",
                "revision": 4, "own": false, "expiresAt": "2099-10-10T18:00:00Z",
                "reference": ["description": "White cap", "mediaStatus": media, "crop": ["width": 8, "height": 8, "pixels": pixels]]
            ]))
        }
        do { _ = try await service.productReference(request, in: session); XCTFail("Pending pixels reached the shopper") }
        catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        lock.withLock { status = "approved"; recipient = UUID().uuidString }
        do { _ = try await service.productReference(request, in: session); XCTFail("Another shopper's reference was accepted") }
        catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        lock.withLock { recipient = member }
        let page = try await service.productReference(request, in: session)
        XCTAssertEqual(page.reference?.crop?.pixels.base64EncodedString(), pixels)
        try await service.moderateProductReference(request, in: session, reviewed: page, block: false, reason: .unsafe, clientKey: UUID())
        try await service.moderateProductReference(request, in: session, reviewed: page, block: true, reason: nil, clientKey: UUID())
    }

    func testAdultProductReferenceValidatesTextEquivalentAndRaster() throws {
        XCTAssertThrowsError(try ProductReferenceCrop(width: Int.max, height: 8, pixels: Data()))
        XCTAssertThrowsError(try ProductReferenceCrop(width: 9, height: 9, pixels: Data(repeating: 4, count: 246)))
        XCTAssertThrowsError(try AdultProductReference(description: "  \n "))
        XCTAssertThrowsError(try AdultProductReference(barcode: "１２３４５６７８", description: "White cap"))
        XCTAssertThrowsError(try AdultProductReference(description: String(repeating: "🍲", count: 121)))
        let text = try AdultProductReference(brand: " ", description: "  Tapa verde  ")
        XCTAssertEqual(text.description, "Tapa verde")
        XCTAssertNil(text.brand); XCTAssertNil(text.crop)
    }
}
