import Foundation

extension HouseholdService {
    public func householdPantryPage(for session: HouseholdPantrySession, after previous: HouseholdPantryPage? = nil) async throws -> HouseholdPantryPage {
        try requireHouseholdPantrySession(session)
        if let previous, previous.householdId != session.householdID || previous.nextCursor == nil { throw ClientError.configuration }
        let query = previous?.nextCursor.map { [URLQueryItem(name: "cursor", value: $0.uuidString.lowercased())] } ?? []
        let page: HouseholdPantryPage = try await perform("pantry", method: "GET", query: query, omitSelectedShop: true)
        try page.validate(for: session, after: previous)
        return page
    }

    /// Make a durable intent from exactly the page reviewed. Retrying sends the
    /// same command key, grant epoch and base even if the household has since moved on.
    public func prepareHouseholdPantryAddition(_ body: HouseholdPantryAddition, reviewed page: HouseholdPantryPage,
                                               session: HouseholdPantrySession) async throws -> HouseholdPantryIntent {
        try body.validate()
        guard page.v == 1, page.householdId == session.householdID, page.grantEpoch >= 0, page.pantryRevision >= 0 else {
            throw ClientError.configuration
        }
        let start = generation
        try requireHouseholdPantrySession(session)
        let window: ReplayWindow = try await perform("replay-windows", method: "POST", body: Data("{}".utf8), omitSelectedShop: true)
        guard generation == start else { throw ClientError.cancelled }
        guard let id = UUID(uuidString: window.id), validHelperTimestamp(window.expiresAt) else { throw ClientError.invalidResponse }
        return HouseholdPantryIntent(session: session, expiresAt: window.expiresAt,
            command: .init(v: 1, kind: "pantry.addLot", clientKey: UUID(), replayWindow: id,
                           grantEpoch: page.grantEpoch, pantryRevision: page.pantryRevision, body: body))
    }

    public func submitHouseholdPantryAddition(_ intent: HouseholdPantryIntent, session: HouseholdPantrySession) async throws -> HouseholdPantryReceipt {
        try intent.validate(for: session)
        try requireHouseholdPantrySession(session)
        let receipt: HouseholdPantryReceipt = try await perform("pantry/commands", method: "POST",
            body: encoded(intent.command), omitSelectedShop: true)
        try receipt.validate(intent)
        return receipt
    }

    public func householdPantryGrants(for session: HouseholdPantrySession) async throws -> HouseholdPantryGrants {
        try requireHouseholdPantrySession(session)
        let result: HouseholdPantryGrants = try await perform("pantry/grants", method: "GET", omitSelectedShop: true)
        try result.validate(for: session)
        return result
    }

    public func changeHouseholdPantryGrant(_ adult: HouseholdPantryGrants.Adult, enabled: Bool,
                                           session: HouseholdPantrySession) async throws -> HouseholdPantryGrants {
        struct Edit: Encodable { let v: Int; let memberId: UUID; let enabled: Bool; let expectedGrantEpoch: Int }
        guard adult.id != session.memberID, adult.enabled != enabled, adult.grantEpoch >= 0, adult.grantEpoch < Int.max else {
            throw ClientError.configuration
        }
        try requireHouseholdPantrySession(session)
        let edit = Edit(v: 1, memberId: adult.id, enabled: enabled, expectedGrantEpoch: adult.grantEpoch)
        let result: HouseholdPantryGrants = try await perform("pantry/grants", method: "POST", body: encoded(edit), omitSelectedShop: true)
        try result.validate(for: session)
        guard let updated = result.adults.first(where: { $0.id == adult.id }), updated.enabled == enabled,
              updated.grantEpoch == adult.grantEpoch + 1 else { throw ClientError.invalidResponse }
        return result
    }

    // Household endpoints verify the current grant under the household lock. A
    // shop-scoped bootstrap here would also make pantry access depend on that shop.
    private func requireHouseholdPantrySession(_ expected: HouseholdPantrySession) throws {
        guard try currentHouseholdPantrySession() == expected else { throw ClientError.accessEnded }
    }
}
