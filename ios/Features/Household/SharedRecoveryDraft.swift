import CoreDomain
import Foundation
import HouseholdClient

/// A row represents either one named group's requirement, an unsplit total,
/// or a genuinely ungrouped requirement. Group identity comes from the target.
struct RecoveryIngredientDraft: Identifiable, Equatable {
    let id = UUID()
    var ingredientID = UUID()
    var groups: [UUID]
    var name = ""
    var literal = ""
    var unit = UnitOfMeasure.count
    var exclusions: [String] = []
    var notes = ""
    var matched = Set<UUID>()
    var repeatQuantity: SharedMealQuantity?
}

struct SharedRecoveryDraft: Equatable {
    var title = ""
    var notes = ""
    var sourceURL: String?
    var repeatID: UUID?
    var ingredients: [RecoveryIngredientDraft]
    var remaining = ""
    var lead = ""
    var completed = false
    var extraTrip = false
    var additionalExclusions: [String] = []

    static func groups(_ need: SharedRecoveryNeed) -> [UUID] { need.groupId.map { [$0] } ?? need.groupIds ?? [] }

    /// Preserve every required group commitment, including an unresolved split.
    static func scopes(_ target: SharedRecoveryMeal) -> [[UUID]] {
        target.needs.filter { $0.priority == "required" }.reduce(into: [[UUID]]()) { result, need in
            let ids = groups(need)
            if !result.contains(where: { Set($0) == Set(ids) }) { result.append(ids) }
        }
    }

    init(target: SharedRecoveryMeal) {
        ingredients = Self.scopes(target).map { RecoveryIngredientDraft(groups: $0) }
    }

    static func repeated(_ donor: SharedRecoveryMeal, for target: SharedRecoveryMeal) -> Self? {
        guard donor.id != target.id, donor.portions == target.portions,
              donor.needs.contains(where: { $0.priority == "required" }) else { return nil }
        let receiving = target.groups.filter { !$0.protected }
        var mapping: [UUID: UUID] = [:]
        let ordinary = donor.groups.filter { !$0.protected }
        let ordinaryIDs = Set(ordinary.map(\.id))
        guard !donor.needs.contains(where: { $0.priority == "protected" && (groups($0).isEmpty || !ordinaryIDs.isDisjoint(with: groups($0))) }) else { return nil }
        for group in ordinary {
            let candidates = receiving.filter {
                $0.servings == group.servings && !$0.protected && !group.protected &&
                ($0.id == group.id || $0.name == group.name || (receiving.count == 1 && ordinary.count == 1))
            }
            guard candidates.count == 1, let candidate = candidates.first, !mapping.values.contains(candidate.id) else { return nil }
            mapping[group.id] = candidate.id
        }
        var result = Self(target: target)
        result.repeatID = donor.id
        result.title = donor.title
        result.notes = donor.notes
        result.sourceURL = donor.sourceURL
        result.additionalExclusions = donor.exclusions
        result.lead = donor.requiredLeadMinutes.map(String.init) ?? ""
        let protected = target.needs.filter { $0.priority == "protected" }
        guard protected.allSatisfy({ Set($0.exclusions).isSuperset(of: donor.exclusions) }) else { return nil }
        var ingredientIDs = [UUID: UUID]()
        result.ingredients = donor.needs.filter { $0.priority == "required" }.map { need in
            var row = RecoveryIngredientDraft(groups: groups(need).compactMap { mapping[$0] })
            row.ingredientID = ingredientIDs[need.ingredientId] ?? row.ingredientID
            ingredientIDs[need.ingredientId] = row.ingredientID
            row.name = need.name
            row.notes = need.notes
            row.exclusions = need.exclusions
            row.repeatQuantity = need.quantity
            return row
        }
        guard scopes(target).allSatisfy({ ids in result.ingredients.contains { Set($0.groups) == Set(ids) } }) else { return nil }
        return result
    }

    func intent(page: SharedRecoveryPage, target: SharedRecoveryMeal, now: Date = Date()) throws -> SharedRecoveryIntent {
        guard page.meals.contains(target), let digest = page.targetDigests.first(where: { $0.occurrenceId == target.id })?.digest,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !ingredients.isEmpty else { throw ClientError.configuration }
        guard Self.scopes(target).allSatisfy({ scope in ingredients.contains { Set($0.groups) == Set(scope) } }) else { throw ClientError.configuration }
        let offered = Set(page.sourceOptions.map(\.sourceId))
        func minutes(_ text: String) throws -> Int? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            guard let value = Int(trimmed), (0...1_000_000).contains(value) else { throw ClientError.configuration }
            return value
        }
        func union(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
        var meal = target
        meal.revisionId = UUID()
        meal.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        meal.template = nil
        meal.notes = notes
        meal.sourceURL = sourceURL
        meal.remainingElapsedMinutes = try minutes(remaining)
        meal.requiredLeadMinutes = try minutes(lead)
        meal.advanceStepsCompleted = completed
        meal.exclusions = union(target.exclusions + additionalExclusions)
        let required = target.needs.filter { $0.priority == "required" }
        meal.needs = target.needs.filter { $0.priority == "protected" }
        for row in ingredients {
            guard !row.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  offered.isSuperset(of: row.matched),
                  row.groups.allSatisfy({ id in target.groups.contains { $0.id == id } }) else { throw ClientError.configuration }
            let quantity: SharedMealQuantity?
            if repeatID != nil {
                quantity = row.repeatQuantity
            } else if let value = try DinnerEntry.quantity(row.literal, unit: row.unit) {
                guard value.amount.numerator > 0, value.amount.numerator <= 1_000_000_000,
                      value.amount.denominator <= 1_000_000_000 else { throw ClientError.configuration }
                quantity = SharedMealQuantity(amount: .init(numerator: Int(value.amount.numerator), denominator: Int(value.amount.denominator)),
                                              unit: row.unit.rawValue, originalLiteral: row.literal)
            } else { quantity = nil }
            let linked = Set(row.groups)
            let inherited = required.filter { need in
                let original = Set(Self.groups(need))
                return original.isEmpty ? linked.isEmpty : !original.isDisjoint(with: linked)
            }.flatMap(\.exclusions)
            let restrictions = union(meal.exclusions + target.groups.filter { linked.contains($0.id) }.flatMap(\.exclusions) + inherited + row.exclusions)
            meal.needs.append(.init(id: row.id, foodId: nil, matchedSourceIds: row.matched.sorted { $0.uuidString < $1.uuidString },
                ingredientId: row.ingredientID, groupId: row.groups.count == 1 ? row.groups.first : nil,
                groupIds: row.groups.count > 1 ? row.groups : nil, name: row.name.trimmingCharacters(in: .whitespacesAndNewlines), notes: row.notes, quantity: quantity,
                priority: "required", due: target.due, exclusions: restrictions))
        }
        return .init(occurrenceId: target.id, targetDigest: digest, replacement: meal, reviewedAt: now.ISO8601Format(),
                     repeatOfOccurrenceId: repeatID, agreesToRepeat: false, proposesExtraTrip: extraTrip, agreesToExtraTrip: false, acceptsUnresolved: false)
    }
}
