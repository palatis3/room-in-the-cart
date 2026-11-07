import Foundation
import CoreDomain

/// Form state only. All resulting definitions are revalidated by the adapter.
struct PickupRecoveryDraft: Equatable {
    struct Ingredient: Identifiable, Equatable {
        let id = UUID()
        var ingredientID = UUID()
        let unknownFoodID = UUID()
        let groupID: UUID?
        let priority: AllocationPriority
        let requiredExclusions: [String]
        var name = ""
        var foodID: UUID?
        var amount = ""
        var unit: UnitOfMeasure = .count
        var notes = ""
        var extraExclusions = ""
    }
    private(set) var template: MealTemplate?
    let original: PickupRecoveryMealDefinition
    let operationID = UUID()
    let revisionID = UUID()
    var title = ""
    var notes = ""
    var sourceURL = ""
    var rows: [Ingredient] = []
    var minutes = ""
    var advanceComplete = false
    var confirmsDeadline = false
    var deadline = Date()
    var identityReviewed = false
    var proposesTrip = false

    init(_ original: PickupRecoveryMealDefinition) {
        self.original = original
        // Start new manual instructions blank, not with an old recipe under a new title.
        for group in editableGroups { add(groupID: group) }
    }
    init(_ original: PickupRecoveryMealDefinition, using template: MealTemplate) throws {
        self.init(original)
        try template.validate()
        guard !template.ingredients.isEmpty, !rows.isEmpty else { throw PickupMealRecoveryError.invalid }
        self.template = template
        title = template.title
        notes = template.notes
        sourceURL = template.sourceURL ?? ""
        let groups = rows
        rows = []
        for group in groups {
            let servings = try original.servings(for: group.groupID)
            let scale = try servings.divided(by: template.servings)
            for ingredient in template.ingredients {
                guard let quantity = ingredient.quantity, quantity.amount > .zero else { throw PickupMealRecoveryError.invalid }
                var row = Ingredient(groupID: group.groupID, priority: .required,
                    requiredExclusions: Array(Set(group.requiredExclusions + ingredient.exclusions)).sorted())
                row.ingredientID = ingredient.id
                row.name = ingredient.name
                row.amount = try quantity.amount.multiplied(by: scale).description
                row.unit = quantity.unit
                row.notes = ingredient.notes
                rows.append(row)
            }
        }
        try definition().validate(replacing: original)
    }
    var editableGroups: [UUID?] {
        var seen = Set<UUID?>()
        return original.meal.ingredients.filter { $0.need.priority != .protected }
            .compactMap { item -> [UUID?]? in
                seen.insert(item.groupID).inserted ? [item.groupID] : nil
            }.flatMap { $0 }
    }
    func groupName(_ id: UUID?) -> String {
        original.groups.first { $0.id == id }?.name ?? recoveryText("Dinner portions")
    }
    mutating func add(groupID: UUID?) {
        let old = original.meal.ingredients.filter { $0.groupID == groupID && $0.need.priority != .protected }
        let ids = Set(old.map(\.need.id))
        let required = Array(Set(original.ingredientRules.filter { ids.contains($0.needID) }.flatMap(\.exclusions))).sorted()
        rows.append(.init(groupID: groupID, priority: .required, requiredExclusions: required))
        identityReviewed = false
    }
    func definition() throws -> PickupRecoveryMealDefinition {
        var ingredients = original.meal.ingredients.filter { $0.need.priority == .protected }
        let protectedIDs = Set(ingredients.map(\.need.id))
        var rules = original.ingredientRules.filter { protectedIDs.contains($0.needID) }
        for row in rows {
            guard let amount = try DinnerEntry.quantity(row.amount, unit: row.unit) else { throw PickupMealRecoveryError.invalid }
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            ingredients.append(.init(ingredientID: row.ingredientID, groupID: row.groupID, foodName: name,
                need: .init(id: row.id, foodID: row.foodID ?? row.unknownFoodID,
                    name: title + " · " + groupName(row.groupID) + " · " + name,
                    amount: amount, priority: row.priority)))
            rules.append(.init(needID: row.id, notes: row.notes,
                exclusions: Array(Set(row.requiredExclusions + DinnerEntry.list(row.extraExclusions))).sorted()))
        }
        let meal = RecoveryMeal(id: original.meal.id, revisionID: revisionID, templateID: template?.id, templateVersion: template?.revision,
            title: template?.title ?? title.trimmingCharacters(in: .whitespacesAndNewlines), servings: original.meal.servings,
            ingredients: ingredients, scheduledDay: original.meal.scheduledDay,
            due: original.meal.due ?? (confirmsDeadline ? deadline : nil), timeZoneID: original.meal.timeZoneID,
            exclusions: Array(Set(original.meal.exclusions + (template?.exclusions ?? []))).sorted(), remainingElapsedMinutes: try DinnerEntry.minutes(minutes),
            requiredLeadMinutes: template == nil ? original.meal.requiredLeadMinutes : template?.leadTimeMinutes, advanceStepsCompleted: advanceComplete)
        let manualURL = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : sourceURL
        return .init(meal: meal, groups: original.groups, notes: notes,
            sourceURL: template == nil ? manualURL : template?.sourceURL,
            ingredientRules: rules, acceptedTemplate: template)
    }
}
