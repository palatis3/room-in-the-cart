import Foundation

public struct SharedFallbackRecipe: Codable, Equatable, Sendable {
    public struct Group: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let name: String
        public let servings: SharedMealAmount
        public let `protected`: Bool
        public let exclusions: [String]
        public init(id: UUID, name: String, servings: SharedMealAmount, protected: Bool, exclusions: [String]) {
            self.id = id
            self.name = name
            self.servings = servings
            self.protected = protected
            self.exclusions = exclusions
        }
    }

    public struct Binding: Codable, Equatable, Sendable {
        public let groupId: UUID
        public let quantity: SharedMealQuantity
        public init(groupId: UUID, quantity: SharedMealQuantity) {
            self.groupId = groupId
            self.quantity = quantity
        }
    }

    public struct Ingredient: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let name: String
        @RecoveryNullable public var quantity: SharedMealQuantity?
        public let exclusions: [String]

        public let notes: String
        public let groupIds: [UUID]?
        public let bindings: [Binding]?
        public init(id: UUID, name: String, quantity: SharedMealQuantity?, exclusions: [String], notes: String = "",
                    groupIds: [UUID]? = nil, bindings: [Binding]? = nil) {
            self.notes = notes
            self.groupIds = groupIds
            self.bindings = bindings
            self.id = id
            self.name = name
            self.quantity = quantity
            self.exclusions = exclusions
        }
    }

    public let title: String
    public let portions: Int
    public let notes: String
    @RecoveryNullable public var sourceURL: String?
    public let exclusions: [String]
    @RecoveryNullable public var requiredLeadMinutes: Int?
    @RecoveryNullable public var elapsedMinutes: Int?
    public let ingredients: [Ingredient]
    public let groups: [Group]?

    public init(title: String, portions: Int, notes: String, sourceURL: String?, exclusions: [String],
                requiredLeadMinutes: Int?, elapsedMinutes: Int?, ingredients: [Ingredient], groups: [Group]? = nil) {
        self.groups = groups
        self.title = title
        self.portions = portions
        self.notes = notes
        self.sourceURL = sourceURL
        self.exclusions = exclusions
        self.requiredLeadMinutes = requiredLeadMinutes
        self.elapsedMinutes = elapsedMinutes
        self.ingredients = ingredients
    }
}

public enum SharedFallbackSource: Codable, Equatable, Sendable {
    case disclosed
    case meal(occurrenceId: UUID, mealRevision: Int, revisionId: UUID?)
    case idea(ideaId: UUID, revision: Int)

    enum CodingKeys: String, CodingKey { case kind, occurrenceId, mealRevision, revisionId, ideaId, revision }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "disclosed": self = .disclosed
        case "meal":
            self = try .meal(occurrenceId: c.decode(UUID.self, forKey: .occurrenceId), mealRevision: c.decode(Int.self, forKey: .mealRevision),
                             revisionId: c.decode(UUID?.self, forKey: .revisionId))
        case "idea": self = try .idea(ideaId: c.decode(UUID.self, forKey: .ideaId), revision: c.decode(Int.self, forKey: .revision))
        default: throw ClientError.invalidResponse
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .disclosed: try c.encode("disclosed", forKey: .kind)
        case let .meal(id, revision, revisionId):
            try c.encode("meal", forKey: .kind)
            try c.encode(id, forKey: .occurrenceId)
            try c.encode(revision, forKey: .mealRevision)
            try c.encode(revisionId, forKey: .revisionId)
        case let .idea(id, revision):
            try c.encode("idea", forKey: .kind)
            try c.encode(id, forKey: .ideaId)
            try c.encode(revision, forKey: .revision)
        }
    }
}

public struct SharedFallbackLibrary: Decodable, Equatable, Sendable {
    public struct Candidate: Decodable, Equatable, Sendable, Identifiable {
        public var id: UUID { candidateId }
        public let candidateId: UUID
        public let revision: Int
        public let recipe: SharedFallbackRecipe
        public let usual: Bool
    }
    public let shopId: UUID
    public let shopRevision, authorityEpoch, registryRevision: Int
    public internal(set) var candidates: [Candidate]
    @RecoveryNullable public internal(set) var nextCursor: UUID?
    var actor: GuardianActorBinding?
    enum CodingKeys: String, CodingKey { case shopId, shopRevision, authorityEpoch, registryRevision, candidates, nextCursor }
}

public struct SharedFallbackSourcePreview: Decodable, Equatable, Sendable {
    public let shopId: UUID
    public let shopRevision, authorityEpoch, registryRevision: Int
    public let source: SharedFallbackSource
    public let recipe: SharedFallbackRecipe
}

public enum SharedFallbackEdit: Codable, Equatable, Sendable {
    case accept(candidateId: UUID, baseRevision: Int?, source: SharedFallbackSource, recipe: SharedFallbackRecipe, usual: Bool)
    case revoke(candidateId: UUID, baseRevision: Int)
}

public struct SharedFallbackReceipt: Decodable, Equatable, Sendable {
    public let shopId, candidateId: UUID
    public let shopRevision, authorityEpoch, revision, registryRevision: Int
    public let accepted: Bool
}

public struct PendingFallbackWrite: Codable, Equatable, Sendable {
    public let householdID, memberID, deviceID, subject: String
    public let shopId, candidateId, clientKey: UUID
    public let shopRevision, authorityEpoch, registryRevision: Int
    public let bytes: Data
}

public struct SharedFallbackOffer: Codable, Equatable, Sendable {
    public let label: String
    public let exclusionTags: [String]
    public let usablePerPack: SharedMealQuantity
    public let priceMinor, availablePacks: Int
    public let packId: UUID?

    public init(label: String, exclusionTags: [String], usablePerPack: SharedMealQuantity, priceMinor: Int, availablePacks: Int, packId: UUID? = nil) {
        self.label = label
        self.exclusionTags = exclusionTags
        self.usablePerPack = usablePerPack
        self.priceMinor = priceMinor
        self.availablePacks = availablePacks
        self.packId = packId
    }
}

public struct SharedFallbackReview: Codable, Equatable, Sendable {
    public struct Ingredient: Codable, Equatable, Sendable {
        public let ingredientId: UUID
        public let sourceIds: [UUID]
        @RecoveryNullable public var offer: SharedFallbackOffer?

        public init(ingredientId: UUID, sourceIds: [UUID], offer: SharedFallbackOffer?) {
            self.ingredientId = ingredientId
            self.sourceIds = sourceIds
            self.offer = offer
        }
    }
    public let candidateId: UUID
    public let revision: Int
    @RecoveryNullable public var remainingElapsedMinutes: Int?
    public let advanceStepsCompleted: Bool
    public let ingredients: [Ingredient]

    public init(candidateId: UUID, revision: Int, remainingElapsedMinutes: Int?, advanceStepsCompleted: Bool, ingredients: [Ingredient]) {
        self.candidateId = candidateId
        self.revision = revision
        self.remainingElapsedMinutes = remainingElapsedMinutes
        self.advanceStepsCompleted = advanceStepsCompleted
        self.ingredients = ingredients
    }
}

public struct SharedFallbackTrip: Codable, Equatable, Sendable {
    public let minutes, budgetMinor, chargesMinor: Int
    public let currency: String

    public init(minutes: Int, budgetMinor: Int, chargesMinor: Int, currency: String) {
        self.minutes = minutes
        self.budgetMinor = budgetMinor
        self.chargesMinor = chargesMinor
        self.currency = currency
    }
}

public struct SharedFallbackSelection: Codable, Equatable, Sendable {
    public let review: SharedFallbackReview
    @RecoveryNullable public var trip: SharedFallbackTrip?
}

public struct SharedFallbackOptions: Decodable, Equatable, Sendable {
    public struct Conditional: Decodable, Equatable, Sendable, Identifiable {
        public var id: UUID { candidateId }
        public let candidateId: UUID
        public let revision: Int
        public let reason: String
        public let minutes, availableMinutes, requiredPacks, availablePacks, extraCashMinor, budgetMinor: Int?
        public let currency: String?
    }

    public struct Buy: Decodable, Equatable, Sendable {
        public let ingredientId: UUID
        public let label: String
        public let packs, subtotalMinor: Int
    }
    public struct Projection: Decodable, Equatable, Sendable {
        public let demands: [SharedRecoveryPreview.Demand]
        public let allocations: [SharedRecoveryPreview.Allocation]
    }
    public struct Option: Decodable, Equatable, Sendable, Identifiable {
        public var id: UUID { candidateId }
        public let candidateId: UUID
        public let revision: Int
        public let title, kind: String
        public let minutes, packCount, merchandiseMinor, extraCashMinor: Int
        @RecoveryNullable public var currency: String?
        public let buys: [Buy]
        public let after: Projection
        public let repeatRequired: Bool
        public let intent: SharedRecoveryIntent
    }
    public let shopId: UUID
    public let base: SharedRecoveryBase
    public let asOf: String
    public let target: SharedRecoveryMeal
    public let registryRevision: Int
    @RecoveryNullable public internal(set) var nextReviewIndex: Int?
    @RecoveryNullable public internal(set) var usualMinutes: Int?
    public internal(set) var conditional: [Conditional]
    public internal(set) var options: [Option]
    public internal(set) var assistanceValidUntil: Date?
    enum CodingKeys: String, CodingKey { case shopId, base, asOf, target, options, conditional, usualMinutes, registryRevision, nextReviewIndex }
}

extension SharedFallbackLibrary {
    public func belongsToSameDevice(as pending: PendingFallbackWrite) -> Bool {
        guard shopId == pending.shopId, let actor else { return false }
        return actor.subject == pending.subject && actor.deviceID == pending.deviceID &&
            actor.memberID == pending.memberID && actor.householdID == pending.householdID
    }
}
