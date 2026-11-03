import XCTest
@testable import HouseholdClient

extension HouseholdClientTests {
    private var historyShop: String { "00000000-0000-4000-8000-000000000041" }
    private var historyPeriod: String { "00000000-0000-4000-8000-000000000042" }
    private var historyDate: String { "2026-11-03T00:00:00.000Z" }
    private func historyObservation(id: String = UUID().uuidString.lowercased()) throws -> HistoryPriceObservation {
        try .init(id: id, shopId: historyShop, itemName: "  Rice  ", packLabel: "2 × 500 g", usablePack: nil,
                  price: .bounded(lowerMinor: 200, upperMinor: 300, reason: "  Entered estimate  "), store: "Store", branch: "Branch",
                  channel: .warehouse, mode: .inStore, eligibility: "", observedAt: historyDate, sourceText: "Entered shelf text", sourceLocale: "en-US")
    }
    private func historyPlan(reservations: [HistoryFutureReservation] = []) throws -> HistoryBudgetPeriod {
        try .init(id: historyPeriod, title: "  November plan  ", startsAt: "2026-11-01T00:00:00Z", endsAt: "2026-11-15T00:00:00Z", timeZoneId: "America/New_York",
                  shopBudgetMinor: 10_000, alreadyExcludedReserveMinor: 1000, shopIds: [historyShop], reservations: reservations, reviewedCompleteAt: nil)
    }
    private func historySubtotal(includesShop: Bool = true) -> HistoryPermittedSubtotal {
        let value = includesShop ? 100 : 0
        let range = HistoryMoneyRange(lowerMinor: value, upperMinor: value)
        let zero = HistoryMoneyRange(lowerMinor: 0, upperMinor: 0)
        let shop = HistoryShopBudgetSummary(shopId: historyShop, sourceVersion: .init(shopRevision: 3, authorityEpoch: 2, financialRevision: 4),
            postedNetMinor: 100, pendingCreditsMinor: 0, includedCreditsMinor: 0, paymentHoldsMinor: 0, expectedUnpaid: zero, projectedCommitment: range, reconciledEntered: true)
        return .init(shops: includesShop ? [shop] : [], postedNetMinor: value, pendingCreditsMinor: 0, includedCreditsMinor: 0, paymentHoldsMinor: 0, expectedUnpaid: zero, projectedCommitment: range)
    }
    private func historyComplete(revision: Int = 1) throws -> HistoryPeriodResponse {
        .complete(.init(periodId: historyPeriod, revision: revision, period: try historyPlan(), permitted: historySubtotal(), futureReservedMinor: 0,
                        remaining: .init(minimumMinor: 9900, maximumMinor: 9900), reconciledEnteredPeriod: false))
    }
    private func historyBootstrap() throws -> Data {
        // Owning a past shop does not require being the currently selected active shopper.
        try JSONSerialization.data(withJSONObject: ["household": ["id": household, "label": "Home"], "memberId": member,
            "role": "contributor", "shopId": NSNull(), "enrolled": true, "queueConsent": false, "capabilities": ["own_requests"]])
    }
    private func historyFixtureResponse(_ request: URLRequest) throws -> (Int, Data)? {
        if let response = authResponse(request) { return response }
        if request.url!.path.hasSuffix("/devices") { return (200, Data(#"{"deviceId":"device","deviceToken":"device-token"}"#.utf8)) }
        if request.url!.path.hasSuffix("/bootstrap") { return (200, try historyBootstrap()) }
        return nil
    }
    private func historyRequestBytes(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return data
    }
    private func historyObject<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: encoded(value)) }
    private func historySourceBytes() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["shopId": historyShop, "sourceVersion": ["shopRevision": 3, "authorityEpoch": 2, "financialRevision": 4], "evidenceSource": "shopper_reported", "entries": [], "nextCursor": NSNull()])
    }
    func testHistoryWirePreservesExactTextNullsAndDistinctPackDimensions() throws {
        var observation = try historyObservation()
        let intent = try PriceObservationIntent(subject: "account", householdID: household, memberID: member, deviceID: "device", observation: observation)
        try intent.validate()
        let payload = try XCTUnwrap(historyObject(JSONDecoder().decode(JSONValue.self, from: intent.bytes)) as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["clientKey", "observation"])
        let entry = try XCTUnwrap(payload["observation"] as? [String: Any])
        XCTAssertTrue(entry["usablePack"] is NSNull); XCTAssertEqual(entry["itemName"] as? String, "  Rice  ")
        XCTAssertEqual(entry["channel"] as? String, "warehouse"); XCTAssertEqual(entry["eligibility"] as? String, "")
        for unit in [HistoryUnit.ounce, .fluidOunce, .count] {
            observation.usablePack = try .init(amount: .init(numerator: 1, denominator: 2), unit: unit, originalLiteral: "½ pack")
            XCTAssertEqual(try JSONDecoder().decode(HistoryPriceObservation.self, from: encoded(observation)).usablePack?.unit, unit)
        }
        observation.itemName = String(repeating: "😀", count: 129)
        XCTAssertThrowsError(try observation.validate())
        observation = try historyObservation(); observation.currency = "EUR"
        XCTAssertThrowsError(try observation.validate())
        XCTAssertThrowsError(try HistoryCostEvidence.bounded(lowerMinor: 300, upperMinor: 200, reason: "Bad range").validate())
        let period = try historyPlan()
        let periodJSON = try XCTUnwrap(historyObject(period) as? [String: Any])
        XCTAssertTrue(periodJSON["reviewedCompleteAt"] is NSNull)
        XCTAssertEqual(periodJSON["alreadyExcludedReserveMinor"] as? Int, 1000)
        let restored = try JSONDecoder().decode(PriceObservationIntent.self, from: encoded(intent)); XCTAssertEqual(restored.bytes, intent.bytes)
        var tampered = try XCTUnwrap(historyObject(intent) as? [String: Any]); tampered["bytes"] = Data("{}".utf8).base64EncodedString()
        XCTAssertThrowsError(try JSONDecoder().decode(PriceObservationIntent.self, from: JSONSerialization.data(withJSONObject: tampered)).validate())
    }
    func testHistoryPeriodValidatesIdentityDatesReservationsAndScopeWithoutDoubleSubtractingReserve() throws {
        var period = try historyPlan()
        try period.validate()
        period.shopIds.append(historyShop.uppercased()); XCTAssertThrowsError(try period.validate())
        period = try historyPlan(); period.timeZoneId = "Not/A_Timezone"; XCTAssertThrowsError(try period.validate())
        period = try historyPlan(); period.endsAt = period.startsAt; XCTAssertThrowsError(try period.validate())
        let applied = try HistoryFutureReservation(originalText: "Future shop", amountMinor: 2000, plannedAt: historyDate, state: .applied(shopID: UUID().uuidString))
        XCTAssertThrowsError(try historyPlan(reservations: [applied]))
        let reserved = try HistoryFutureReservation(originalText: "Future shop", amountMinor: 2000, plannedAt: historyDate, state: .reserved)
        period = try historyPlan(reservations: [reserved]); period.reviewedCompleteAt = "2026-11-16T00:00:00Z"; XCTAssertThrowsError(try period.validate())
        if case .complete(let complete) = try historyComplete() { try complete.validate(id: historyPeriod); XCTAssertEqual(complete.remaining.maximumMinor, 9900) }
    }
    func testHistoryPartialPeriodRejectsEnvelopeAndHiddenSourceMetadata() throws {
        let partial = HistoryPeriodResponse.permittedOnly(historySubtotal(includesShop: false))
        let data = try encoded(partial)
        XCTAssertEqual(try JSONDecoder().decode(HistoryPeriodResponse.self, from: data), partial)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for field in ["periodId", "hiddenShopCount", "remaining", "period", "title", "funding"] {
            var bad = object; bad[field] = "must never reach UI"
            XCTAssertThrowsError(try JSONDecoder().decode(HistoryPeriodResponse.self, from: JSONSerialization.data(withJSONObject: bad)), field)
        }
        object["permitted"] = try historyObject(historySubtotal())
        let response = try JSONDecoder().decode(HistoryPeriodResponse.self, from: JSONSerialization.data(withJSONObject: object))
        guard case .permittedOnly = response else { return XCTFail("Partial scope became full") }
    }
    func testHistoryPaidLapseKeepsFreeSavedRecordsAndOwnedShopsAvailable() async throws {
        let auth = try auth(); let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        let observation = try historyObservation()
        var paths: [String] = []
        MockURLProtocol.handler = { request in
            if let response = try self.historyFixtureResponse(request) { return response }
            let path = request.url!.path; paths.append(path)
            if path.hasSuffix("/price-observations") { return (403, Data(#"{"error":{"code":"membership_inactive","correlationId":"paid-lapse"}}"#.utf8)) }
            if path.hasSuffix("/price-observations/\(observation.id)") { return (200, try JSONSerialization.data(withJSONObject: ["observation": self.historyObject(observation)])) }
            if path.hasSuffix("/budget-periods") { return (200, try encoded(HistoryBudgetPeriodPage(periods: [.init(periodId: self.historyPeriod, revision: 1, updatedAt: self.historyDate)], nextCursor: nil))) }
            if path.hasSuffix("/record") { return (200, try encoded(HistorySavedBudgetPeriod(periodId: self.historyPeriod, revision: 1, period: self.historyPlan()))) }
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [.init(name: "scope", value: "owned")])
            return (200, try encoded(HistoryOwnedShopPage(shops: [.init(shopId: self.historyShop, createdAt: self.historyDate, phase: "closed", revision: 3, authorityEpoch: 2)], nextCursor: nil)))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        do { _ = try await service.priceObservations(); XCTFail("Paid lapse accepted") }
        catch { XCTAssertEqual(error as? ClientError, .service(status: 403, code: "membership_inactive", correlationID: "paid-lapse", retryAfter: nil)) }
        let saved = try await service.priceObservation(observationID: observation.id); XCTAssertEqual(saved, observation)
        let periods = try await service.budgetPeriods(); XCTAssertEqual(periods.periods.first?.periodId, historyPeriod)
        let raw = try await service.savedBudgetPeriod(periodID: historyPeriod); XCTAssertEqual(raw.period, try historyPlan())
        let shops = try await service.historyOwnedShops(); XCTAssertEqual(shops.shops.first?.phase, "closed")
        XCTAssertEqual(paths.count, 5)
    }
    func testHistoryObservationRetryKeepsOriginalBytesAndStopsAfterSourceAuthorityLoss() async throws {
        let auth = try auth(); let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        let observation = try historyObservation(); var bodies: [Data] = []; var denied = false
        MockURLProtocol.handler = { request in
            if let response = try self.historyFixtureResponse(request) { return response }
            if request.url!.path.hasSuffix("/financial-evidence") { return denied ? (404, Data(#"{"error":{"code":"unavailable"}}"#.utf8)) : (200, try self.historySourceBytes()) }
            XCTAssertEqual(request.url!.path, "/v1/households/\(self.household)/price-observations")
            bodies.append(self.historyRequestBytes(request))
            if bodies.count == 1 { throw URLError(.networkConnectionLost) }
            return (200, try encoded(PriceObservationReceipt(observationId: observation.id, shopId: observation.shopId)))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let intent = try await service.preparePriceObservation(observation)
        do { _ = try await service.executePriceObservation(intent); XCTFail("Lost response") } catch { XCTAssertEqual(error as? ClientError, .transport) }
        let receipt = try await service.executePriceObservation(intent); XCTAssertTrue(receipt.recorded)
        XCTAssertEqual(bodies, [intent.bytes, intent.bytes])
        denied = true
        do { try await service.authorizePriceObservation(intent); XCTFail("Restored revoked private record") } catch {}
        do { _ = try await service.executePriceObservation(intent); XCTFail("Sent after source transfer") } catch {}
        XCTAssertEqual(bodies.count, 2)
    }
    func testHistoryPeriodRetryDoesNotRebaseAfterLostReceiptAndPaidScopeLossStopsSend() async throws {
        let auth = try auth(); let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        var bodies: [Data] = []; var revision = 1; var denied = false; var partial = false
        MockURLProtocol.handler = { request in
            if let response = try self.historyFixtureResponse(request) { return response }
            let path = request.url!.path
            if path.hasSuffix("/budget-history") {
                if denied { return (403, Data(#"{"error":{"code":"membership_inactive"}}"#.utf8)) }
                return (200, try JSONSerialization.data(withJSONObject: ["permitted": self.historyObject(self.historySubtotal())]))
            }
            if path.hasSuffix("/record") { return (200, try encoded(HistorySavedBudgetPeriod(periodId: self.historyPeriod, revision: revision, period: self.historyPlan()))) }
            if path.hasSuffix("/budget-periods/\(self.historyPeriod)") { return (200, try encoded(partial ? HistoryPeriodResponse.permittedOnly(self.historySubtotal(includesShop: false)) : self.historyComplete(revision: revision))) }
            XCTAssertTrue(path.hasSuffix("/budget-periods")); bodies.append(self.historyRequestBytes(request))
            if bodies.count == 1 { revision = 2; throw URLError(.networkConnectionLost) }
            return (200, try encoded(BudgetPeriodReceipt(periodId: self.historyPeriod, revision: 2)))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let intent = try await service.prepareBudgetPeriod(historyPlan(), baseRevision: 1)
        do { _ = try await service.executeBudgetPeriod(intent); XCTFail("Lost response") } catch { XCTAssertEqual(error as? ClientError, .transport) }
        let receipt = try await service.executeBudgetPeriod(intent); XCTAssertEqual(receipt.revision, 2); XCTAssertEqual(bodies, [intent.bytes, intent.bytes])
        partial = true
        do { try await service.authorizeBudgetPeriod(intent); XCTFail("Partial current scope restored cached envelope") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(bodies.count, 2)
        partial = false; denied = true
        do { _ = try await service.executeBudgetPeriod(intent); XCTFail("Paid lapse sent") } catch {}
        XCTAssertEqual(bodies.count, 2)
    }
    func testHistoryPagesRejectDuplicateIdentityAndInvalidCursorWithoutBroadeningQuery() async throws {
        let auth = try auth(); let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        let cursor = UUID().uuidString.lowercased(); let observation = try historyObservation(); var duplicate = false
        MockURLProtocol.handler = { request in
            if let response = try self.historyFixtureResponse(request) { return response }
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [.init(name: "cursor", value: cursor)])
            return (200, try encoded(HistoryPriceObservationPage(observations: duplicate ? [observation, observation] : [observation], nextCursor: nil)))
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        let page = try await service.priceObservations(cursor: cursor); XCTAssertEqual(page.observations, [observation])
        duplicate = true
        do { _ = try await service.priceObservations(cursor: cursor); XCTFail("Duplicate source identity") } catch { XCTAssertEqual(error as? ClientError, .invalidResponse) }
        do { _ = try await service.priceObservations(cursor: "../budget-periods"); XCTFail("Invalid cursor") } catch { XCTAssertEqual(error as? ClientError, .configuration) }
    }
    func testHistoryWrongEnrollmentCannotRestoreOrSendPersistedIntents() async throws {
        let auth = try auth(); let service = HouseholdService(configuration: try .init(baseURL: URL(string: "https://service.test")!), auth: auth, deviceVault: MemoryVault(), transport: transport())
        let observation = try PriceObservationIntent(subject: "another-account", householdID: household, memberID: member, deviceID: "device", observation: historyObservation())
        let period = try BudgetPeriodIntent(subject: "account", householdID: household, memberID: member, deviceID: "another-device", baseRevision: 0, period: historyPlan())
        var calls = 0
        MockURLProtocol.handler = { request in
            if let response = try self.historyFixtureResponse(request) { return response }
            calls += 1; return (500, Data())
        }
        _ = try await auth.verifyEmailCode(email: "adult@example.test", code: "123456"); _ = try await service.enroll(householdID: household)
        do { try await service.authorizePriceObservation(observation); XCTFail("Wrong account restored") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        do { _ = try await service.executeBudgetPeriod(period); XCTFail("Wrong device sent") } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        XCTAssertEqual(calls, 0)
    }
}
