import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    func testTripChoicesStayUndecidedUntilAuthorExplicitlySharesAndShopperCannotWrite() async throws {
        let id = UUID(), shop = UUID(), key = UUID(), lock = NSLock()
        var posted = 0
        let (service, session) = try await connectAdultPickup(shop: shop, capabilities: ["trip_substitutions"]) { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/requests/" + id.uuidString.lowercased() + "/substitution"))
            var page: [String: Any] = ["requestId": id.uuidString, "requestRevision": 3, "authorityEpoch": 2,
                "originalItem": "Green tea 20 bags", "choice": "undecided", "revision": 0, "own": true]
            if request.httpMethod == "POST" {
                lock.withLock { posted += 1 }
                let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: mockRequestBody(request)) as? [String: Any])
                XCTAssertEqual(body["clientKey"] as? String, key.uuidString)
                XCTAssertEqual(body["expectedRevision"] as? Int, 0)
                XCTAssertEqual(body["requestRevision"] as? Int, 3)
                XCTAssertEqual(body["authorityEpoch"] as? Int, 2)
                XCTAssertEqual(body["choice"] as? String, "alternative")
                XCTAssertEqual(body["alternative"] as? String, "Chamomile 20 bags")
                page["choice"] = body["choice"]
                page["alternative"] = body["alternative"]
                page["revision"] = 1
            }
            return (200, try JSONSerialization.data(withJSONObject: page))
        }
        let unanswered = try await service.substitution(for: id, in: session)
        XCTAssertEqual(unanswered.choice, .undecided)
        let saved = try await service.saveSubstitution(.alternative, alternative: "Chamomile 20 bags", reviewed: unanswered, in: session, key: key)
        XCTAssertEqual(saved.alternative, "Chamomile 20 bags")
        let (shopperService, shopper) = try await connectAdultPickup(shop: shop, capabilities: ["trip_substitutions"], role: "shopper") { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, try JSONSerialization.data(withJSONObject: ["requestId": id.uuidString, "requestRevision": 3, "authorityEpoch": 2,
                "originalItem": "Green tea 20 bags", "choice": "alternative", "alternative": "Chamomile 20 bags", "revision": 1, "own": false]))
        }
        let visible = try await shopperService.substitution(for: id, in: shopper)
        do {
            _ = try await shopperService.saveSubstitution(.skip, alternative: nil, reviewed: visible, in: shopper, key: UUID())
            XCTFail("A shopper issued an author-only change")
        } catch { XCTAssertEqual(error as? ClientError, .configuration) }
        XCTAssertEqual(lock.withLock { posted }, 1)
    }

    func testPendingPickSurvivesLostResponseWithSameActorDeviceRowAndOperationAndExpiresLocally() async throws {
        let shop = UUID(), permission = UUID(), row = UUID(), safety = UUID(), lock = NSLock()
        var attempts: [[String: String]] = []
        let (service, session) = try await connectAdultPickup(shop: shop, capabilities: ["shared_picking"]) { request in
            if request.httpMethod == "GET" {
                return (200, try JSONSerialization.data(withJSONObject: [
                    "managed": false, "authorityEpoch": 1, "shopRevision": 8, "permissionId": permission.uuidString, "recipientId": self.member,
                    "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)), "members": [], "availableRows": [],
                    "rows": [["id": row.uuidString, "safetyId": safety.uuidString, "label": "Apples", "packs": 3, "picked": 2, "revision": 4]]
                ]))
            }
            XCTAssertTrue(request.url!.path.hasSuffix("/shared-picking/operations"))
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: mockRequestBody(request)) as? [String: Any])
            let normalized = body.mapValues { String(describing: $0) }
            let first = lock.withLock { attempts.append(normalized); return attempts.count == 1 }
            if first { throw URLError(.networkConnectionLost) }
            return (200, try JSONSerialization.data(withJSONObject: ["operationId": body["operationId"]!, "rowId": row.uuidString, "revision": 5, "picked": 3]))
        }
        let page = try await service.sharedPicking(in: session), selected = try XCTUnwrap(page.rows.first)
        XCTAssertThrowsError(try SharedPickIntent(page: page, row: selected, in: session, action: .pick, packs: 2))
        let write = try SharedPickIntent(page: page, row: selected, in: session, action: .pick, packs: 1)
        XCTAssertFalse(write.matches(session, now: write.expiresAt))
        do { _ = try await service.applySharedPick(write, in: session); XCTFail("Expected a lost response") }
        catch { XCTAssertEqual(error as? ClientError, .transport) }
        let stored = try JSONEncoder().encode(write)
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("Apples"))
        let restored = try JSONDecoder().decode(SharedPickIntent.self, from: stored)
        let accepted = try await service.applySharedPick(restored, in: session)
        XCTAssertEqual(accepted.picked, 3)
        XCTAssertEqual(accepted.operationId, write.id)
        let sent = lock.withLock { attempts }
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first, sent.last)
        XCTAssertEqual(sent.last?["actorId"]?.lowercased(), member.lowercased())
        XCTAssertEqual(sent.last?["deviceId"], session.device.deviceID.uuidString)
        XCTAssertEqual(sent.last?["permissionId"], permission.uuidString)
        XCTAssertEqual(sent.last?["rowId"], row.uuidString)
        XCTAssertEqual(sent.last?["expectedRevision"], "4")
        XCTAssertEqual(sent.last?["packs"], "1")
        XCTAssertNil(sent.last?["label"])
        XCTAssertNil(sent.last?["undoOperationId"])
    }

    func testPickingRejectsForeignRecipientAndOwnerOnlyProjectionAndOldService() async throws {
        let shop = UUID(), lock = NSLock()
        var recipient = UUID().uuidString
        let (service, session) = try await connectAdultPickup(shop: shop, capabilities: ["shared_picking"]) { _ in
            (200, try JSONSerialization.data(withJSONObject: [
                "managed": false, "authorityEpoch": 1, "shopRevision": 2, "permissionId": UUID().uuidString, "recipientId": lock.withLock { recipient },
                "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600)), "members": [], "rows": [],
                "availableRows": lock.withLock { recipient == self.member } ? [["id": UUID().uuidString, "label": "Unshared", "packs": 2]] : []
            ]))
        }
        for target in [UUID().uuidString, member] {
            lock.withLock { recipient = target }
            do { _ = try await service.sharedPicking(in: session); XCTFail("Accepted an unauthorized projection") }
            catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        }
        let (legacy, old) = try await connectAdultPickup(shop: shop, capabilities: ["own_requests"]) { _ in
            XCTFail("Called an unsupported endpoint")
            throw ClientError.configuration
        }
        do { _ = try await legacy.sharedPicking(in: old); XCTFail("Old service received new request") }
        catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
    }
}
