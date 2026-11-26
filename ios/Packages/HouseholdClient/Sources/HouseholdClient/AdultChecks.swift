import Foundation

public enum AdultCheckKind: String, Codable, Sendable { case attendance, cupboard }

public enum AdultCheckAnswer: String, Codable, Sendable {
    case home, latePlate, out, enough, low, cannotCheck
    public var kind: AdultCheckKind {
        switch self {
        case .home, .latePlate, .out: .attendance
        case .enough, .low, .cannotCheck: .cupboard
        }
    }
}

public struct AdultCheckPage: Decodable, Sendable {
    public struct Choice: Decodable, Identifiable, Sendable {
        public let id: UUID
        public let label: String
        public let day: String?
        public let shoppingPacks: Int?
    }
    public struct Quantity: Codable, Sendable {
        public let value, unit: String
        public init(value: String, unit: String) { self.value = value; self.unit = unit }
        fileprivate var valid: Bool {
            ["count", "gram", "kilogram", "milliliter", "liter"].contains(unit) &&
            value.range(of: #"^(0|[1-9][0-9]{0,5})(\.[0-9]{1,3})?$"#, options: .regularExpression) != nil &&
            (Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) ?? 0) > 0
        }
    }
    public struct Check: Decodable, Identifiable, Sendable {
        public let id, sourceId: UUID
        public let kind: AdultCheckKind
        public let label: String
        public let day: String?
        public let shoppingPacks: Int?
        public let expiresAt: String
        public let answer: AdultCheckAnswer?
        public let answeredAt: String?
        public let quantity: Quantity?
        public let reviewed, canAnswer: Bool
        public var deadline: Date? { HistoryValidation.date(expiresAt) }
        fileprivate func valid(shopper: Bool) -> Bool {
            guard deadline != nil, !label.isEmpty, (shoppingPacks ?? 0) >= 0,
                  (answer == nil) == (answeredAt == nil),
                  !canAnswer || (!shopper && answer == nil),
                  !reviewed || answer != nil else { return false }
            if let answer, answer.kind != kind { return false }
            if let answeredAt, HistoryValidation.date(answeredAt) == nil { return false }
            if let quantity { return quantity.valid && (answer == .low || answer == .enough) }
            return true
        }
    }
    public let shopId: UUID
    public let shopRevision, authorityEpoch, pairRevision: Int
    public let shopper: Bool
    public let recipient: Choice?
    public let dinners, items: [Choice]
    public let checks: [Check]
    public let validUntil: String
    public var deadline: Date? { HistoryValidation.date(validUntil) }

    func validate(shop: UUID) throws {
        guard shopId == shop, deadline != nil,
              shopper || (dinners.isEmpty && items.isEmpty && recipient == nil),
              Set(checks.map(\.id)).count == checks.count,
              checks.allSatisfy({ $0.valid(shopper: shopper) }) else { throw ClientError.invalidResponse }
    }
}

extension HouseholdService {
    private func adultChecks(_ session: AdultShopRequestSession, body: [String: JSONValue]?) async throws -> AdultCheckPage {
        guard session.adultChecks, session.generation == generation, try currentHouseholdDeviceSession() == session.device else { throw ClientError.accessEnded }
        let shop = session.shopID.uuidString.lowercased()
        let page: AdultCheckPage = try await perform("shops/\(shop)/adult-checks", method: body == nil ? "GET" : "POST",
                                                     body: try body.map(encoded), reportingShopID: shop)
        try page.validate(shop: session.shopID)
        return page
    }
    public func fetchAdultChecks(in session: AdultShopRequestSession) async throws -> AdultCheckPage {
        try await adultChecks(session, body: nil)
    }
    public func askAdultCheck(in session: AdultShopRequestSession, page: AdultCheckPage, id: UUID,
                              kind: AdultCheckKind, source: UUID, expires: Date) async throws -> AdultCheckPage {
        guard page.shopId == session.shopID, page.shopper, let recipient = page.recipient,
              (kind == .attendance ? page.dinners : page.items).contains(where: { $0.id == source }) else { throw ClientError.configuration }
        return try await adultChecks(session, body: ["action": .string("ask"), "id": .string(id.uuidString.lowercased()),
            "kind": .string(kind.rawValue), "sourceId": .string(source.uuidString.lowercased()), "recipientId": .string(recipient.id.uuidString.lowercased()),
            "shopRevision": .integer(page.shopRevision), "authorityEpoch": .integer(page.authorityEpoch), "pairRevision": .integer(page.pairRevision),
            "expiresAt": .string(ISO8601DateFormatter().string(from: expires))])
    }
    public func answerAdultCheck(in session: AdultShopRequestSession, check: AdultCheckPage.Check,
                                 answer: AdultCheckAnswer, quantity: AdultCheckPage.Quantity? = nil) async throws -> AdultCheckPage {
        guard check.canAnswer, answer.kind == check.kind, quantity == nil || (quantity?.valid == true && [.enough, .low].contains(answer)) else { throw ClientError.configuration }
        var body: [String: JSONValue] = ["action": .string("answer"), "id": .string(check.id.uuidString.lowercased()), "answer": .string(answer.rawValue)]
        if let quantity { body["quantity"] = .object(["value": .string(quantity.value), "unit": .string(quantity.unit)]) }
        return try await adultChecks(session, body: body)
    }
    public func reviewAdultCheck(in session: AdultShopRequestSession, check: AdultCheckPage.Check) async throws -> AdultCheckPage {
        guard let answer = check.answer, let time = check.answeredAt else { throw ClientError.configuration }
        return try await adultChecks(session, body: ["action": .string("review"), "id": .string(check.id.uuidString.lowercased()),
            "answer": .string(answer.rawValue), "answeredAt": .string(time)])
    }
    public func withdrawAdultCheck(in session: AdultShopRequestSession, id: UUID) async throws -> AdultCheckPage {
        try await adultChecks(session, body: ["action": .string("withdraw"), "id": .string(id.uuidString.lowercased())])
    }
}
