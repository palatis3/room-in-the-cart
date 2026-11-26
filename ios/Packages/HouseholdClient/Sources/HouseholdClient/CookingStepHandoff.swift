import Foundation

public struct CookingStepHandoff: Decodable, Sendable {
    public enum Answer: String, Codable, Sendable { case accepted, declined }
    public struct Adult: Decodable, Sendable { public let id: UUID; public let label: String }
    public struct Offer: Decodable, Identifiable, Sendable {
        public let id: UUID
        public let instruction: String
        public let mine: Bool
        public let answer: Answer?
        public let expiresAt: String
        public var expiry: Date? { HistoryValidation.date(expiresAt) }
    }
    public let shopId: UUID
    public let shopRevision, authorityEpoch, pairRevision: Int
    public let otherAdult: Adult?
    public let offers: [Offer]
    public let validUntil: String
    public var deadline: Date? { HistoryValidation.date(validUntil) }

    func validate(shop: UUID) throws {
        guard shopId == shop, let deadline, min(shopRevision, authorityEpoch, pairRevision) >= 0,
              offers.isEmpty || otherAdult != nil, offers.count <= 2, Set(offers.map(\.mine)).count == offers.count,
              Set(offers.map(\.id)).count == offers.count, offers.allSatisfy({ offer in
                !offer.instruction.isEmpty && offer.instruction.count <= 240 && (offer.expiry ?? .distantPast) >= deadline
              }) else { throw ClientError.invalidResponse }
    }
}

extension HouseholdService {
    private func cookingStep(in session: AdultShopRequestSession, body: [String: JSONValue]?) async throws -> CookingStepHandoff {
        guard session.cookStepHandoff, session.generation == generation, try currentHouseholdDeviceSession() == session.device else {
            throw ClientError.accessEnded
        }
        let shop = session.shopID.uuidString.lowercased()
        let page: CookingStepHandoff = try await perform("shops/\(shop)/cooking-step", method: body == nil ? "GET" : "POST",
                                                        body: try body.map(encoded), reportingShopID: shop)
        guard session.generation == generation, try currentHouseholdDeviceSession() == session.device else { throw ClientError.accessEnded }
        try page.validate(shop: session.shopID)
        return page
    }

    public func fetchCookingStep(in session: AdultShopRequestSession) async throws -> CookingStepHandoff {
        try await cookingStep(in: session, body: nil)
    }
    public func offerCookingStep(in session: AdultShopRequestSession, page: CookingStepHandoff, id: UUID,
                                 instruction: String, expires: Date) async throws -> CookingStepHandoff {
        guard page.shopId == session.shopID, let peer = page.otherAdult, !instruction.isEmpty, instruction.count <= 240 else {
            throw ClientError.configuration
        }
        return try await cookingStep(in: session, body: ["action": .string("offer"), "reviewed": .bool(true),
            "id": .string(id.uuidString.lowercased()), "recipientId": .string(peer.id.uuidString.lowercased()),
            "shopRevision": .integer(page.shopRevision), "authorityEpoch": .integer(page.authorityEpoch), "pairRevision": .integer(page.pairRevision),
            "instruction": .string(instruction), "expiresAt": .string(ISO8601DateFormatter().string(from: expires))])
    }
    public func answerCookingStep(in session: AdultShopRequestSession, offer: CookingStepHandoff.Offer,
                                  answer: CookingStepHandoff.Answer) async throws -> CookingStepHandoff {
        guard !offer.mine, offer.answer == nil else { throw ClientError.configuration }
        return try await cookingStep(in: session, body: ["action": .string("reply"), "id": .string(offer.id.uuidString.lowercased()), "answer": .string(answer.rawValue)])
    }
    public func withdrawCookingStep(in session: AdultShopRequestSession, id: UUID) async throws -> CookingStepHandoff {
        try await cookingStep(in: session, body: ["action": .string("withdraw"), "id": .string(id.uuidString.lowercased())])
    }
}
