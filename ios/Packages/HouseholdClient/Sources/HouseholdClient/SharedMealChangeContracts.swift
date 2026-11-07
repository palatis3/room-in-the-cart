import Foundation

public struct SharedMealAmount: Codable, Equatable, Sendable {
    public var numerator: Int; public var denominator: Int
    public init(numerator: Int, denominator: Int = 1) { self.numerator = numerator; self.denominator = denominator }
    public func validate() throws {
        guard (1...1_000_000_000).contains(numerator), (1...1_000_000_000).contains(denominator) else { throw ClientError.configuration }
    }
}
public struct SharedMealQuantity: Codable, Equatable, Sendable {
    public var amount: SharedMealAmount; public var unit: String; public var originalLiteral: String
    public init(amount: SharedMealAmount, unit: String, originalLiteral: String) {
        self.amount = amount; self.unit = unit; self.originalLiteral = originalLiteral
    }
}
public struct SharedMealPlanning: Codable, Equatable, Sendable {
    public struct Group: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID; public var name: String; public var servings: SharedMealAmount; public var protected: Bool
        public init(id: UUID = UUID(), name: String, servings: SharedMealAmount, protected: Bool) {
            self.id = id; self.name = name; self.servings = servings; self.protected = protected
        }
    }
    public struct Ingredient: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID; public var name: String; public var quantity: SharedMealQuantity?
        public var groupIds: [UUID]; public var exclusions: [String]
        public init(id: UUID = UUID(), name: String, quantity: SharedMealQuantity?, groupIds: [UUID], exclusions: [String]) {
            self.id = id; self.name = name; self.quantity = quantity; self.groupIds = groupIds; self.exclusions = exclusions
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
            try c.encode(quantity, forKey: .quantity); try c.encode(groupIds, forKey: .groupIds); try c.encode(exclusions, forKey: .exclusions)
        }
    }
    public struct Allocation: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID; public var groupId: UUID; public var ingredientId: UUID; public var quantity: SharedMealQuantity
        public init(id: UUID, groupId: UUID, ingredientId: UUID, quantity: SharedMealQuantity) {
            self.id = id; self.groupId = groupId; self.ingredientId = ingredientId; self.quantity = quantity
        }
    }
    public var bindings: [Allocation]?
    public var groups: [Group]; public var ingredients: [Ingredient]
    public var sourceOccurrenceId: UUID?
    public var exclusions: [String]?
    public var leadTimeMinutes: Int?
    public var completedSteps: [String]?

    public init(groups: [Group], ingredients: [Ingredient], sourceOccurrenceId: UUID? = nil,
                bindings: [Allocation]? = nil, exclusions: [String]? = nil,
                leadTimeMinutes: Int? = nil, completedSteps: [String]? = nil) {
        self.groups = groups
        self.ingredients = ingredients
        self.sourceOccurrenceId = sourceOccurrenceId
        self.bindings = bindings
        self.exclusions = exclusions
        self.leadTimeMinutes = leadTimeMinutes
        self.completedSteps = completedSteps
    }
    public func validate() throws {
        guard (exclusions?.count ?? 0) <= 20, (completedSteps?.count ?? 0) <= 100,
              (exclusions ?? []).allSatisfy({ sharedMealText($0, 240) }),
              (completedSteps ?? []).allSatisfy({ sharedMealText($0, 240) }),
              leadTimeMinutes.map({ (0...1_000_000).contains($0) }) ?? true else { throw ClientError.configuration }
        guard groups.count <= 30, ingredients.count <= 60,
              Set(groups.map(\.id)).count == groups.count, Set(ingredients.map(\.id)).count == ingredients.count else { throw ClientError.configuration }
        guard (bindings?.count ?? 0) <= 200, Set((bindings ?? []).map(\.id)).count == (bindings?.count ?? 0) else { throw ClientError.configuration }
        for binding in bindings ?? [] {
            try binding.quantity.amount.validate()
            guard groups.contains(where: { $0.id == binding.groupId }), ingredients.contains(where: { $0.id == binding.ingredientId && $0.groupIds.contains(binding.groupId) }) else { throw ClientError.configuration }
        }
        for group in groups { try group.servings.validate(); guard sharedMealText(group.name, 240) else { throw ClientError.configuration } }
        for ingredient in ingredients {
            guard sharedMealText(ingredient.name, 240), ingredient.groupIds.count <= 30,
                  Set(ingredient.groupIds).count == ingredient.groupIds.count,
                  ingredient.groupIds.allSatisfy({ id in groups.contains { $0.id == id } }),
                  ingredient.exclusions.count <= 20, ingredient.exclusions.allSatisfy({ sharedMealText($0, 240) }) else { throw ClientError.configuration }
            if let quantity = ingredient.quantity {
                try quantity.amount.validate()
                guard ["count","gram","kilogram","ounce","pound","milliliter","liter","fluidOunce","cup"].contains(quantity.unit),
                      sharedMealText(quantity.originalLiteral, 240) else { throw ClientError.configuration }
            }
        }
    }
}
private func sharedMealText(_ value: String, _ limit: Int) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= limit
}
extension SharedMeal {
    public func validatePlanning() throws {
        guard sharedMealText(title, 240), ["dinner","lunch","side"].contains(kind), (1...1000).contains(portions) else { throw ClientError.configuration }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard let date = f.date(from: day), f.string(from: date) == day else { throw ClientError.configuration }
        try planning?.validate()
    }
}
public struct SharedMealChangeRequest: Codable, Equatable, Sendable {
    public let proposalId: UUID; public let occurrenceId: UUID; public let baseMealRevision: Int?
    public let shopRevision: Int; public let authorityEpoch: Int; public let grantRevision: Int
    public let meal: SharedMeal; public let reason: String
    public let approvedIdeaId: UUID?; public let approvedIdeaRevision: Int?
    public init(proposalId: UUID = UUID(), occurrenceId: UUID, baseMealRevision: Int?, shopRevision: Int, authorityEpoch: Int, grantRevision: Int, meal: SharedMeal, reason: String, approvedIdeaId: UUID? = nil, approvedIdeaRevision: Int? = nil) {
        self.proposalId = proposalId; self.occurrenceId = occurrenceId; self.baseMealRevision = baseMealRevision
        self.shopRevision = shopRevision; self.authorityEpoch = authorityEpoch; self.grantRevision = grantRevision; self.meal = meal; self.reason = reason; self.approvedIdeaId = approvedIdeaId; self.approvedIdeaRevision = approvedIdeaRevision
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(proposalId, forKey: .proposalId); try c.encode(occurrenceId, forKey: .occurrenceId)
        try c.encode(baseMealRevision, forKey: .baseMealRevision); try c.encode(shopRevision, forKey: .shopRevision)
        try c.encode(authorityEpoch, forKey: .authorityEpoch); try c.encode(grantRevision, forKey: .grantRevision)
        try c.encode(meal, forKey: .meal); try c.encode(reason, forKey: .reason)
        try c.encodeIfPresent(approvedIdeaId, forKey: .approvedIdeaId); try c.encodeIfPresent(approvedIdeaRevision, forKey: .approvedIdeaRevision)
    }
    public func validate() throws {
        guard [shopRevision,authorityEpoch].allSatisfy({ $0 > 0 && $0 <= Int(Int32.max) }), grantRevision >= 0, sharedMealText(reason, 500) else { throw ClientError.configuration }
        if let baseMealRevision {
            guard baseMealRevision > 0, grantRevision > 0, approvedIdeaId == nil, approvedIdeaRevision == nil else { throw ClientError.configuration }
        } else { guard approvedIdeaId != nil, (approvedIdeaRevision ?? 0) > 0 else { throw ClientError.configuration } }
        try meal.validatePlanning()
    }
}
public struct SharedMealChangePage: Codable, Equatable, Sendable {
    public struct Proposal: Codable, Equatable, Identifiable, Sendable {
        public let proposalId: UUID; public let request: SharedMealChangeRequest; public let original: SharedMeal?; public let state: String
        public var id: UUID { proposalId }
        public func isCurrent(in page: SharedMealChangePage) -> Bool {
            state == "pending" && page.phase == "draft" && request.shopRevision == page.shopRevision && request.authorityEpoch == page.authorityEpoch && request.grantRevision == page.grantRevision && (request.baseMealRevision == nil ? (original == nil && !page.meals.contains { $0.id == request.occurrenceId }) : page.meals.contains { $0.id == request.occurrenceId && $0.revision == request.baseMealRevision && $0.meal == original })
        }
    }
    public let shopId: UUID; public let shopRevision: Int; public let authorityEpoch: Int; public let grantRevision: Int
    public let phase: String; public let shopper: Bool; public let meals: [SharedMealOccurrence]; public let proposals: [Proposal]
    public func validate() throws {
        guard shopRevision > 0, authorityEpoch > 0, grantRevision >= 0,
              ["draft","frozen","placed","closed"].contains(phase), meals.count <= 100, proposals.count <= 100,
              Set(meals.map(\.id)).count == meals.count, Set(proposals.map(\.id)).count == proposals.count else { throw ClientError.invalidResponse }
        for occurrence in meals { try occurrence.meal.validatePlanning() }
        for proposal in proposals {
            try proposal.request.validate(); try proposal.original?.validatePlanning()
            guard (proposal.original == nil) == (proposal.request.baseMealRevision == nil), proposal.id == proposal.request.proposalId, ["pending","applied","dismissed"].contains(proposal.state) else { throw ClientError.invalidResponse }
        }
    }
}
public struct SharedMealChangeIntent: Codable, Equatable, Identifiable, Sendable {
    public let subject: String; public let householdID: String; public let memberID: String; public let deviceID: String
    public let shopID: UUID; public let request: SharedMealChangeRequest; public let bytes: Data
    public var id: UUID { request.proposalId }
    public init(subject: String, householdID: String, memberID: String, deviceID: String, shopID: UUID, request: SharedMealChangeRequest) throws {
        self.subject = subject; self.householdID = householdID; self.memberID = memberID; self.deviceID = deviceID; self.shopID = shopID; self.request = request
        bytes = try encoded(request); try validate()
    }
    public func validate() throws {
        try request.validate()
        guard !subject.isEmpty, !deviceID.isEmpty, UUID(uuidString: householdID) != nil, UUID(uuidString: memberID) != nil,
              try JSONDecoder().decode(SharedMealChangeRequest.self, from: bytes) == request else { throw ClientError.configuration }
    }
}
struct SharedMealChangeReceipt: Decodable { let saved: Bool; let proposalId: UUID }
