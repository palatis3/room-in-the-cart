import Foundation

public struct HouseholdStaplePage: Decodable, Equatable, Sendable {
    public struct Group: Decodable, Equatable, Identifiable, Sendable {
        public struct Purchase: Decodable, Equatable, Sendable { public let lotId: UUID; public let day: String; public let foodName: String? }
        public struct Prompt: Decodable, Equatable, Sendable {
            public let purchaseDays: Int
            public let intervalDays: Int
            public let dueDay: String
            public let basis: String
        }
        public let id: UUID
        public let name: String
        public let purchases: [Purchase]
        public let prompt: Prompt?
    }

    public let v: Int
    public let householdId: UUID
    public let memberId: UUID
    public let grantEpoch: Int
    public let pantryRevision: Int
    public let zone: String
    public let today: String
    public let revision: UUID?
    public let enabled: Bool
    public let groups: [Group]

    func validate(for session: HouseholdPantrySession, zone: String) throws {
        let day = #"^\d{4}-\d{2}-\d{2}$"#
        guard v == 1, householdId == session.householdID, memberId == session.memberID, self.zone == zone,
              grantEpoch >= 0, pantryRevision >= 0, today.range(of: day, options: .regularExpression) != nil,
              groups.count <= 32, Set(groups.map(\.id)).count == groups.count,
              enabled ? revision != nil : groups.isEmpty else { throw ClientError.invalidResponse }
        var lots = Set<UUID>()
        for group in groups {
            guard sharedMealText(group.name, 120), group.purchases.count <= 64 else { throw ClientError.invalidResponse }
            for purchase in group.purchases {
                guard lots.insert(purchase.lotId).inserted, purchase.day.range(of: day, options: .regularExpression) != nil,
                      purchase.foodName.map({ sharedMealText($0, 240) }) != false else { throw ClientError.invalidResponse }
            }
            if let prompt = group.prompt {
                guard prompt.purchaseDays >= 3, prompt.purchaseDays <= Set(group.purchases.map(\.day)).count,
                      prompt.intervalDays > 0, prompt.dueDay <= today, prompt.dueDay.range(of: day, options: .regularExpression) != nil,
                      prompt.basis.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw ClientError.invalidResponse }
            }
        }
    }
}

public enum HouseholdStapleAction: Encodable, Sendable {
    public enum Answer: String, Encodable, Sendable { case stillHave, dismiss, snooze }
    case enable(Bool)
    case remember(String)
    case purchase(group: UUID?, name: String?, lot: UUID, reviewed: UUID, day: String)
    case answer(group: UUID, basis: String, choice: Answer)
    case removePurchase(group: UUID, lot: UUID)
    case forget(UUID)

    private enum Keys: CodingKey { case kind, enabled, groupId, name, lotId, observationId, purchaseDay, basis, choice }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .enable(let enabled):
            try c.encode("enable", forKey: .kind)
            try c.encode(enabled, forKey: .enabled)
        case .remember(let name):
            try c.encode("remember", forKey: .kind)
            try c.encode(name, forKey: .name)
        case let .purchase(group, name, lot, reviewed, day):
            try c.encode("purchase", forKey: .kind)
            try c.encode(group, forKey: .groupId)
            try c.encode(name, forKey: .name)
            try c.encode(lot, forKey: .lotId)
            try c.encode(reviewed, forKey: .observationId)
            try c.encode(day, forKey: .purchaseDay)
        case let .answer(group, basis, choice):
            try c.encode("answer", forKey: .kind)
            try c.encode(group, forKey: .groupId)
            try c.encode(basis, forKey: .basis)
            try c.encode(choice, forKey: .choice)
        case let .removePurchase(group, lot):
            try c.encode("removePurchase", forKey: .kind)
            try c.encode(group, forKey: .groupId)
            try c.encode(lot, forKey: .lotId)
        case .forget(let group):
            try c.encode("forget", forKey: .kind)
            try c.encode(group, forKey: .groupId)
        }
    }
}

extension HouseholdService {
    public func householdStaples(for session: HouseholdPantrySession, zone: String) async throws -> HouseholdStaplePage {
        guard try currentHouseholdPantrySession() == session else { throw ClientError.accessEnded }
        let result: HouseholdStaplePage = try await perform("pantry/staples", method: "GET",
            query: [.init(name: "zone", value: zone)], omitSelectedShop: true)
        try result.validate(for: session, zone: zone)
        return result
    }

    public func changeHouseholdStaples(_ action: HouseholdStapleAction, reviewed: HouseholdStaplePage, session: HouseholdPantrySession) async throws -> HouseholdStaplePage {
        struct Command: Encodable {
            let v: Int, zone: String, grantEpoch: Int, pantryRevision: Int, expectedRevision: UUID?, clientKey: UUID, replayWindow: UUID
            let action: HouseholdStapleAction
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(v, forKey: .v)
                try c.encode(zone, forKey: .zone)
                try c.encode(grantEpoch, forKey: .grantEpoch)
                try c.encode(pantryRevision, forKey: .pantryRevision)
                try c.encode(expectedRevision, forKey: .expectedRevision)
                try c.encode(clientKey, forKey: .clientKey)
                try c.encode(replayWindow, forKey: .replayWindow)
                try c.encode(action, forKey: .action)
            }
            enum CodingKeys: CodingKey { case v, zone, grantEpoch, pantryRevision, expectedRevision, clientKey, replayWindow, action }
        }
        try reviewed.validate(for: session, zone: reviewed.zone)
        guard try currentHouseholdPantrySession() == session else { throw ClientError.accessEnded }
        let start = generation
        let window: ReplayWindow = try await perform("replay-windows", method: "POST", body: Data("{}".utf8), omitSelectedShop: true)
        guard generation == start, try currentHouseholdPantrySession() == session else { throw ClientError.cancelled }
        guard let id = UUID(uuidString: window.id) else { throw ClientError.invalidResponse }
        let command = Command(v: 1, zone: reviewed.zone, grantEpoch: reviewed.grantEpoch, pantryRevision: reviewed.pantryRevision,
                              expectedRevision: reviewed.revision, clientKey: UUID(), replayWindow: id, action: action)
        let result: HouseholdStaplePage = try await perform("pantry/staples", method: "POST", body: encoded(command), omitSelectedShop: true)
        try result.validate(for: session, zone: reviewed.zone)
        guard result.grantEpoch == reviewed.grantEpoch, result.revision != reviewed.revision else { throw ClientError.invalidResponse }
        return result
    }
}
