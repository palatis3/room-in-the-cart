import Foundation

/// Exact rational household evidence. Legacy JSON integers round-trip as integers.
public struct SharedMealIdeaAmount: Codable, Equatable, Sendable, ExpressibleByIntegerLiteral {
    public let numerator: Int
    public let denominator: Int
    private let integerEncoding: Bool
    public init(_ numerator: Int, _ denominator: Int = 1) {
        self.numerator = numerator; self.denominator = denominator; integerEncoding = denominator == 1
    }
    private init(numerator: Int, denominator: Int, integerEncoding: Bool) {
        self.numerator = numerator; self.denominator = denominator; self.integerEncoding = integerEncoding
    }
    public init(integerLiteral value: Int) { self.init(value) }
    private enum CodingKeys: String, CodingKey { case numerator, denominator }
    public init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(Int.self) { self.init(value); return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let numerator = try c.decode(Int.self, forKey: .numerator), denominator = try c.decode(Int.self, forKey: .denominator)
        guard numerator >= 0, denominator > 0 else { throw ClientError.invalidResponse }
        self.init(numerator: numerator, denominator: denominator, integerEncoding: false)
    }
    public func encode(to encoder: Encoder) throws {
        if integerEncoding { var c = encoder.singleValueContainer(); try c.encode(numerator) }
        else { var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(numerator, forKey: .numerator); try c.encode(denominator, forKey: .denominator) }
    }
    public var text: String { denominator == 1 ? String(numerator) : "\(numerator)/\(denominator)" }
    public static func parse(_ text: String) -> Self? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let n = Int(parts[0]), (0...1_000_000).contains(n) else { return nil }
        let d = parts.count == 2 ? Int(parts[1]) : 1
        guard let d, (1...1_000_000).contains(d) else { return nil }
        return Self(n,d)
    }
    public func validInput(allowZero: Bool = false) -> Bool {
        ((allowZero ? 0 : 1)...1_000_000).contains(numerator) && (1...1_000_000).contains(denominator)
    }
}

/// Household-entered evidence only. Never populated from a device-private food or decision store.
public struct SharedMealIdeaDraft: Codable, Equatable, Sendable {
    public struct Reservation: Codable, Equatable, Sendable {
        public var name: String; public var amount: SharedMealIdeaAmount
        public init(name: String, amount: SharedMealIdeaAmount) { self.name = name; self.amount = amount }
    }
    public struct Ingredient: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID; public var name: String; public var required: SharedMealIdeaAmount?; public var unit: String
        public var stock: SharedMealIdeaAmount?; public var reservations: [Reservation]; public var pack: SharedMealIdeaAmount?
        public var usableNumerator: Int?; public var usableDenominator: Int?; public var evidence: String
        public init(id: UUID = UUID(), name: String = "", required: SharedMealIdeaAmount? = nil, unit: String = "gram", stock: SharedMealIdeaAmount? = nil,
                    reservations: [Reservation] = [], pack: SharedMealIdeaAmount? = nil, usableNumerator: Int? = nil, usableDenominator: Int? = nil, evidence: String = "") {
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
    /// Match the service's trimmed draft before a save, review or lost-reply comparison.
    public func normalizedForSave() -> Self {
        func trim(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var copy = self
        copy.title = trim(title)
        copy.exclusions = exclusions.map(trim).filter { !$0.isEmpty }
        copy.assumedExtras = assumedExtras.map(trim).filter { !$0.isEmpty }
        for i in copy.ingredients.indices {
            copy.ingredients[i].name = trim(ingredients[i].name)
            copy.ingredients[i].evidence = trim(ingredients[i].evidence)
            for r in copy.ingredients[i].reservations.indices {
                copy.ingredients[i].reservations[r].name = trim(ingredients[i].reservations[r].name)
            }
        }
        return copy
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
            guard text(i.name), text(i.evidence), ["count","gram","kilogram","ounce","pound","milliliter","liter","fluidOunce","cup"].contains(i.unit), i.required?.validInput() != false, i.pack?.validInput() != false,
                  positive(i.usableNumerator), positive(i.usableDenominator), i.stock?.validInput(allowZero: true) != false,
                  i.reservations.count <= 20, i.reservations.allSatisfy({ text($0.name) && $0.amount.validInput() }),
                  i.usableNumerator == nil || i.usableDenominator == nil || i.usableNumerator! <= i.usableDenominator! else { throw ClientError.configuration }
        }
    }
    public func proposedMeal(day: String) throws -> SharedMeal {
        try validate()
        let ingredients = ingredients.map { i in
            SharedMealPlanning.Ingredient(id: i.id, name: i.name,
                quantity: i.required.map { .init(amount: .init(numerator: $0.numerator, denominator: $0.denominator), unit: i.unit, originalLiteral: "\($0.text) \(i.unit)") }, groupIds: [], exclusions: [])
        }
        let value = SharedMeal(title: title, day: day, kind: "dinner", portions: servings, protected: false,
                               planning: .init(groups: [], ingredients: ingredients,
                                               exclusions: exclusions.isEmpty ? nil : exclusions, leadTimeMinutes: minutes))
        try value.validatePlanning(); return value
    }
}
public struct SharedMealIdeaPreview: Codable, Equatable, Sendable {
    public struct Ingredient: Codable, Equatable, Identifiable, Sendable {
        public let ingredientId: UUID; public let excluded: Bool; public let reserved: SharedMealIdeaAmount?
        public let remaining: SharedMealIdeaAmount?; public let shortage: SharedMealIdeaAmount?; public let wholePacks: Int?; public let unresolvedPrice: Bool; public let arithmeticUnavailable: Bool?
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
                  idea.preview.ingredients.allSatisfy({ ($0.reserved == nil || ($0.reserved!.numerator >= 0 && $0.reserved!.denominator > 0)) && $0.unresolvedPrice && ($0.wholePacks == nil || $0.wholePacks! >= 0) }) else { throw ClientError.invalidResponse }
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
