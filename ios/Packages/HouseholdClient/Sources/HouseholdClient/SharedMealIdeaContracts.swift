import Foundation

/// Household-entered evidence only. Never populated from a device-private food or decision store.
public struct SharedMealIdeaDraft: Codable, Equatable, Sendable {
    public struct Reservation: Codable, Equatable, Sendable {
        public var name: String; public var amount: Int
        public init(name: String, amount: Int) { self.name = name; self.amount = amount }
    }
    public struct Ingredient: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID; public var name: String; public var required: Int?; public var unit: String
        public var stock: Int?; public var reservations: [Reservation]; public var pack: Int?
        public var usableNumerator: Int?; public var usableDenominator: Int?; public var evidence: String
        public init(id: UUID = UUID(), name: String = "", required: Int? = nil, unit: String = "gram", stock: Int? = nil,
                    reservations: [Reservation] = [], pack: Int? = nil, usableNumerator: Int? = nil, usableDenominator: Int? = nil, evidence: String = "") {
            self.id = id; self.name = name; self.required = required; self.unit = unit; self.stock = stock
            self.reservations = reservations; self.pack = pack; self.usableNumerator = usableNumerator; self.usableDenominator = usableDenominator; self.evidence = evidence
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(required, forKey: .required)
            try c.encode(unit, forKey: .unit); try c.encode(stock, forKey: .stock); try c.encode(reservations, forKey: .reservations)
            try c.encode(pack, forKey: .pack); try c.encode(usableNumerator, forKey: .usableNumerator)
            try c.encode(usableDenominator, forKey: .usableDenominator); try c.encode(evidence, forKey: .evidence)
        }
    }
    public var title: String; public var source: String; public var servings: Int; public var minutes: Int?
    public var assumedExtras: [String]; public var exclusions: [String]; public var ingredients: [Ingredient]
    public init(title: String = "", source: String = "manual", servings: Int = 2, minutes: Int? = nil,
                assumedExtras: [String] = [], exclusions: [String] = [], ingredients: [Ingredient] = [.init()]) {
        self.title = title; self.source = source; self.servings = servings; self.minutes = minutes
        self.assumedExtras = assumedExtras; self.exclusions = exclusions; self.ingredients = ingredients
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title); try c.encode(source, forKey: .source); try c.encode(servings, forKey: .servings)
        try c.encode(minutes, forKey: .minutes); try c.encode(assumedExtras, forKey: .assumedExtras)
        try c.encode(exclusions, forKey: .exclusions); try c.encode(ingredients, forKey: .ingredients)
    }
    public func validate() throws {
        func text(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= 240 }
        func positive(_ value: Int?) -> Bool { value == nil || (1...1_000_000).contains(value!) }
        guard text(title), ["manual","app_template"].contains(source), (1...1000).contains(servings), positive(minutes),
              assumedExtras.count <= 20, exclusions.count <= 20, (assumedExtras + exclusions).allSatisfy(text),
              (1...60).contains(ingredients.count), Set(ingredients.map(\.id)).count == ingredients.count else { throw ClientError.configuration }
        for i in ingredients {
            guard text(i.name), text(i.evidence), ["count","gram","milliliter"].contains(i.unit), positive(i.required), positive(i.pack),
                  positive(i.usableNumerator), positive(i.usableDenominator), i.stock == nil || (0...1_000_000).contains(i.stock!),
                  i.reservations.count <= 20, i.reservations.allSatisfy({ text($0.name) && positive($0.amount) }),
                  i.usableNumerator == nil || i.usableDenominator == nil || i.usableNumerator! <= i.usableDenominator! else { throw ClientError.configuration }
        }
    }
    public func proposedMeal(day: String) throws -> SharedMeal {
        try validate()
        let ingredients = ingredients.map { i in
            SharedMealPlanning.Ingredient(id: i.id, name: i.name,
                quantity: i.required.map { .init(amount: .init(numerator: $0), unit: i.unit, originalLiteral: "\($0) \(i.unit)") }, groupIds: [], exclusions: [])
        }
        let value = SharedMeal(title: title, day: day, kind: "dinner", portions: servings, protected: false,
                               planning: .init(groups: [], ingredients: ingredients))
        try value.validatePlanning(); return value
    }
}
public struct SharedMealIdeaPreview: Codable, Equatable, Sendable {
    public struct Ingredient: Codable, Equatable, Identifiable, Sendable {
        public let ingredientId: UUID; public let excluded: Bool; public let reserved: Int
        public let remaining: Int?; public let shortage: Int?; public let wholePacks: Int?; public let unresolvedPrice: Bool
        public var id: UUID { ingredientId }
    }
    public let canApprove: Bool; public let ingredients: [Ingredient]
}
public struct SharedMealIdeaPage: Codable, Equatable, Sendable {
    public struct Idea: Codable, Equatable, Identifiable, Sendable {
        public let ideaId: UUID; public let revision: Int; public let actorId: UUID; public let state: String
        public let draft: SharedMealIdeaDraft; public let preview: SharedMealIdeaPreview
        public var id: UUID { ideaId }
    }
    public let shopId: UUID; public let shopRevision: Int; public let authorityEpoch: Int; public let grantRevision: Int; public let shopper: Bool
    public let ideas: [Idea]
    public func validate() throws {
        guard shopRevision > 0, authorityEpoch > 0, grantRevision >= 0, ideas.count <= 100, Set(ideas.map(\.id)).count == ideas.count else { throw ClientError.invalidResponse }
        for idea in ideas {
            try idea.draft.validate()
            guard idea.revision > 0, ["draft","approved"].contains(idea.state), idea.preview.ingredients.map(\.id) == idea.draft.ingredients.map(\.id),
                  idea.preview.ingredients.allSatisfy({ $0.reserved >= 0 && $0.unresolvedPrice && ($0.wholePacks == nil || $0.wholePacks! >= 0) }) else { throw ClientError.invalidResponse }
        }
    }
}
public struct SharedMealIdeaWrite: Codable, Equatable, Sendable {
    public let clientKey: UUID; public let ideaId: UUID; public let baseRevision: Int?
    public let shopRevision: Int; public let authorityEpoch: Int; public let grantRevision: Int
    public let action: String; public let draft: SharedMealIdeaDraft; public let reviewedHouseholdEvidence: Bool
    public init(clientKey: UUID = UUID(), ideaId: UUID, baseRevision: Int?, page: SharedMealIdeaPage, action: String, draft: SharedMealIdeaDraft, reviewedHouseholdEvidence: Bool) {
        self.clientKey = clientKey; self.ideaId = ideaId; self.baseRevision = baseRevision; shopRevision = page.shopRevision
        authorityEpoch = page.authorityEpoch; grantRevision = page.grantRevision; self.action = action; self.draft = draft; self.reviewedHouseholdEvidence = reviewedHouseholdEvidence
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(clientKey, forKey: .clientKey); try c.encode(ideaId, forKey: .ideaId); try c.encode(baseRevision, forKey: .baseRevision)
        try c.encode(shopRevision, forKey: .shopRevision); try c.encode(authorityEpoch, forKey: .authorityEpoch); try c.encode(grantRevision, forKey: .grantRevision)
        try c.encode(action, forKey: .action); try c.encode(draft, forKey: .draft); try c.encode(reviewedHouseholdEvidence, forKey: .reviewedHouseholdEvidence)
    }
}
public struct SharedMealIdeaReceipt: Codable, Equatable, Sendable {
    public let saved: Bool; public let ideaId: UUID; public let revision: Int; public let state: String
}
