import Foundation

/// Server-supplied existing-occurrence history, not a client inverse or cached authority.
public struct SharedOperationUndoMeal: Codable, Equatable, Sendable {
    public enum Field: String, Codable, Hashable, Sendable { case membership, title, day, kind, portions, protected, planning }
    public struct Fact: Codable, Equatable, Sendable {
        public let revision: Int
        public let meal: SharedMeal?
        private enum K: String, CodingKey { case revision, meal }
        public init(from decoder: Decoder) throws {
            try demandExactKeys(decoder, ["revision", "meal"])
            let c = try decoder.container(keyedBy: K.self)
            revision = try c.decode(Int.self, forKey: .revision)
            // decodeNil also throws for a missing required key.
            if try c.decodeNil(forKey: .meal) { meal = nil }
            else { meal = try undoDecodedMeal(c.superDecoder(forKey: .meal)) }
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encode(revision, forKey: .revision)
            if let meal { try c.encode(undoEncodedMeal(meal), forKey: .meal) }
            else { try c.encodeNil(forKey: .meal) }
        }
    }
    public struct Proposal: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case change, move }
        public let kind: Kind
        public let proposalId: SharedDemandID
        private enum K: String, CodingKey { case kind, proposalId }
        public init(from decoder: Decoder) throws {
            try demandExactKeys(decoder, ["kind", "proposalId"])
            let c = try decoder.container(keyedBy: K.self)
            kind = try c.decode(Kind.self, forKey: .kind); proposalId = try c.decode(SharedDemandID.self, forKey: .proposalId)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encode(kind, forKey: .kind); try c.encode(proposalId, forKey: .proposalId)
        }
    }
    public let occurrenceId: SharedDemandID
    public let targetBefore, targetAfter, current: Fact
    public let restoredMeal: SharedMeal
    public let touchedFields: [Field]
    public let proposal: Proposal?
    private enum K: String, CodingKey { case occurrenceId, targetBefore, targetAfter, current, restoredMeal, touchedFields, proposal }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["occurrenceId", "targetBefore", "targetAfter", "current", "restoredMeal", "touchedFields", "proposal"])
        let c = try decoder.container(keyedBy: K.self)
        occurrenceId = try c.decode(SharedDemandID.self, forKey: .occurrenceId)
        targetBefore = try c.decode(Fact.self, forKey: .targetBefore)
        try demandRequire(targetBefore.meal != nil)
        targetAfter = try c.decode(Fact.self, forKey: .targetAfter)
        current = try c.decode(Fact.self, forKey: .current)
        restoredMeal = try undoDecodedMeal(c.superDecoder(forKey: .restoredMeal))
        touchedFields = try c.decode([Field].self, forKey: .touchedFields)
        proposal = try c.decode(Proposal?.self, forKey: .proposal)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(occurrenceId, forKey: .occurrenceId)
        try c.encode(targetBefore, forKey: .targetBefore); try c.encode(targetAfter, forKey: .targetAfter)
        try c.encode(current, forKey: .current); try c.encode(undoEncodedMeal(restoredMeal), forKey: .restoredMeal)
        try c.encode(touchedFields, forKey: .touchedFields); try c.encode(proposal, forKey: .proposal)
    }

    func validate(scope: SharedOperationUndoScope, base: SharedDemandActionSourceBase, shop: ShopperShop, edit: SharedDemandMealEdit) throws {
        try demandIDs([occurrenceId, proposal?.proposalId])
        guard let before = targetBefore.meal else { throw ClientError.invalidResponse }
        try demandRequire(demandRevision(targetBefore.revision) && targetBefore.revision <= scope.baseShopRevision &&
            targetAfter.revision == scope.resultShopRevision && current.revision >= targetAfter.revision && current.revision <= base.shopRevision)
        try demandRequire(edit.occurrenceId == occurrenceId && edit.meal == restoredMeal && edit.proposalId == nil && edit.changeProposalId == nil)
        guard let meals = shop.meals else { throw ClientError.invalidResponse }
        let active = meals.filter { $0.id == occurrenceId.uuid }
        if let now = current.meal {
            try demandRequire(active.count == 1 && active[0].revision == current.revision && active[0].meal == now)
        } else { try demandRequire(active.isEmpty) }
        if let after = targetAfter.meal {
            guard let now = current.meal else { throw ClientError.invalidResponse }
            let ordered: [Field] = [.title, .day, .kind, .portions, .protected, .planning]
            let changed = ordered.filter { !equal($0, before, after) }
            try demandRequire(!changed.isEmpty && touchedFields == changed && edit.baseMealRevision == current.revision)
            // Verify the supplied compensation field-by-field; never synthesize an inverse.
            for field in ordered {
                if changed.contains(field) {
                    try demandRequire(equal(field, now, after) && equal(field, restoredMeal, before))
                } else { try demandRequire(equal(field, restoredMeal, now)) }
            }
            try undoPreservesProtectedMeal(now, restoredMeal)
        } else {
            try demandRequire(current.meal == nil && current.revision == targetAfter.revision && touchedFields == [.membership] &&
                restoredMeal == before && edit.baseMealRevision == nil)
        }
        try before.validatePlanning(); try targetAfter.meal?.validatePlanning()
        try current.meal?.validatePlanning(); try restoredMeal.validatePlanning()
    }
    private func equal(_ field: Field, _ a: SharedMeal, _ b: SharedMeal) -> Bool {
        switch field {
        case .title: a.title == b.title
        case .day: a.day == b.day
        case .kind: a.kind == b.kind
        case .portions: a.portions == b.portions
        case .protected: a.protected == b.protected
        case .planning: a.planning == b.planning
        case .membership: false
        }
    }
}

private enum UndoMealEditKey: String, CodingKey { case meal }
func undoMealShapeInEdit(_ decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: UndoMealEditKey.self)
    _ = try undoDecodedMeal(c.superDecoder(forKey: .meal)) // Compensation always restores a nonnull meal.
}

/// A typed roundtrip rejects unknown fields and omitted required-null fields,
/// without trimming literals or normalizing historical quantities. UUID case is
/// handled only at the existing meal schema's identifier fields, never in text.
private func undoDecodedMeal(_ decoder: Decoder) throws -> SharedMeal {
    let raw = try JSONValue(from: decoder), meal = try SharedMeal(from: decoder)
    let typed = try JSONDecoder().decode(JSONValue.self, from: encoded(meal))
    let received = try undoMealIdentities(raw, wire: true), encodedValue = try undoMealIdentities(typed, wire: false)
    try demandRequire(received == encodedValue)
    try meal.validatePlanning()
    if let planning = meal.planning {
        let bindings = planning.bindings ?? []
        try demandRequire(Set(bindings.map { $0.groupId.uuidString + "/" + $0.ingredientId.uuidString }).count == bindings.count)
        for binding in bindings {
            try binding.quantity.amount.validate()
            try demandRequire(SharedDemandUnit(rawValue: binding.quantity.unit) != nil && sharedMealText(binding.quantity.originalLiteral, 240))
        }
        for ingredient in planning.ingredients {
            let rows = bindings.filter { $0.ingredientId == ingredient.id }
            if rows.isEmpty { continue }
            guard let quantity = ingredient.quantity else { throw ClientError.invalidResponse }
            try demandRequire(rows.allSatisfy { $0.quantity.unit == quantity.unit })
            let sum = rows.reduce(SharedDeliveryCoverage.Fraction(numerator: "0", denominator: "1")) { $0.adding(undoMealFraction($1.quantity.amount)) }
            try demandRequire(sum.compare(undoMealFraction(quantity.amount)) == .orderedSame)
        }
    }
    return meal
}
/// Only strict Undo response DTOs use this encoder. General SharedMeal/action
/// encoding and existing outbox bytes are intentionally unchanged.
func undoEncodedMeal(_ meal: SharedMeal) throws -> JSONValue {
    let value = try JSONDecoder().decode(JSONValue.self, from: encoded(meal))
    return try undoMealIdentities(value, wire: false)
}
private func undoMealIdentities(_ value: JSONValue, key: String? = nil, wire: Bool) throws -> JSONValue {
    switch value {
    case .object(let fields): return .object(try fields.mapValuesWithKey { try undoMealIdentities($1, key: $0, wire: wire) })
    case .array(let values): return .array(try values.map { try undoMealIdentities($0, key: key == "groupIds" ? "id" : nil, wire: wire) })
    case .string(let text) where ["id", "sourceOccurrenceId", "groupId", "ingredientId"].contains(key ?? ""):
        guard let uuid = UUID(uuidString: text) else { throw ClientError.invalidResponse }
        let id = SharedDemandID(uuid); try demandIDs([id]); try demandRequire(!wire || text == id.string)
        return .string(id.string)
    default: return value
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func mapValuesWithKey(_ transform: (String, JSONValue) throws -> JSONValue) rethrows -> [String: JSONValue] {
        try Dictionary(uniqueKeysWithValues: map { (key, value) in (key, try transform(key, value)) })
    }
}
private func undoMealFraction(_ value: SharedMealAmount) -> SharedDeliveryCoverage.Fraction {
    .init(numerator: String(value.numerator), denominator: String(value.denominator))
}
private func undoPreservesProtectedMeal(_ old: SharedMeal, _ next: SharedMeal) throws {
    func atLeast(_ a: SharedMealAmount, _ b: SharedMealAmount) -> Bool { undoMealFraction(a).compare(undoMealFraction(b)) != .orderedAscending }
    if old.protected { try demandRequire(next.protected && next.portions >= old.portions && next.kind == old.kind) }
    let groups = old.planning?.groups.filter { old.protected || $0.protected } ?? []
    if old.protected || !groups.isEmpty {
        try demandRequire(Set(old.planning?.exclusions ?? []).isSubset(of: Set(next.planning?.exclusions ?? [])))
    }
    for group in groups {
        guard let row = next.planning?.groups.first(where: { $0.id == group.id }) else { throw ClientError.invalidResponse }
        try demandRequire((!group.protected || row.protected) && row.name == group.name && atLeast(row.servings, group.servings))
    }
    for binding in old.planning?.bindings ?? [] where groups.contains(where: { $0.id == binding.groupId }) {
        guard let row = next.planning?.bindings?.first(where: { $0.id == binding.id }) else { throw ClientError.invalidResponse }
        try demandRequire(row.groupId == binding.groupId && row.ingredientId == binding.ingredientId && row.quantity.unit == binding.quantity.unit && atLeast(row.quantity.amount, binding.quantity.amount))
    }
    for ingredient in old.planning?.ingredients ?? [] {
        let protected = ingredient.groupIds.filter { id in groups.contains { $0.id == id } }
        if !old.protected && protected.isEmpty { continue }
        guard let row = next.planning?.ingredients.first(where: { $0.id == ingredient.id }) else { throw ClientError.invalidResponse }
        try demandRequire(row.name == ingredient.name && Set(protected).isSubset(of: Set(row.groupIds)) && Set(ingredient.exclusions).isSubset(of: Set(row.exclusions)))
        let bound = protected.allSatisfy { id in old.planning?.bindings?.contains { $0.ingredientId == ingredient.id && $0.groupId == id } == true }
        if (old.protected || !bound), let quantity = ingredient.quantity {
            guard let replacement = row.quantity else { throw ClientError.invalidResponse }
            try demandRequire(replacement.unit == quantity.unit && atLeast(replacement.amount, quantity.amount))
        }
    }
}
