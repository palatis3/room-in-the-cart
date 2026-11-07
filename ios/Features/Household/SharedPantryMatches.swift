import CoreDomain
import HouseholdClient
import SwiftUI

struct SharedPantryMatches: View {
    @ObservedObject var model: HouseholdShopModel
    let shopID: UUID
    let lotID: UUID
    var body: some View {
        List {
            if let review = PantryLotReview(model: model, shopID: shopID, lotID: lotID), review.lot.selected {
                ForEach(review.delivery.meals ?? []) { occurrence in
                    if let plan = occurrence.meal.planning, !plan.ingredients.isEmpty {
                        Section(occurrence.meal.title + " · " + occurrence.meal.day) {
                            ForEach(plan.ingredients) { ingredient in
                                let target = SharedDeliveryPage.IngredientMatch(occurrence: occurrence, ingredient: ingredient)
                                NavigationLink {
                                    PantryIngredientView(model: model, shopID: shopID, lotID: lotID, occurrence: occurrence, ingredient: ingredient)
                                } label: {
                                    if review.lot.matches.contains(target) {
                                        Label(ingredient.name, systemImage: "checkmark.circle").accessibilityValue(ht("Matched"))
                                    } else { Text(ingredient.name) }
                                }
                                .accessibilityIdentifier("pantry.ingredient." + occurrence.id.uuidString + "." + ingredient.id.uuidString)
                            }
                        }
                    }
                }
            } else { Text(ht("Refresh deliveries and review the current record.")) }
        }
        .navigationTitle(ht("Meal ingredient matches"))
    }
}

private struct PantryIngredientView: View {
    @ObservedObject var model: HouseholdShopModel
    let shopID: UUID
    let lotID: UUID
    let occurrence: SharedMealOccurrence
    let ingredient: SharedMealPlanning.Ingredient
    @State private var reserving: PantryReservationReview?
    @State private var error: String?
    private var target: SharedDeliveryPage.IngredientMatch { .init(occurrence: occurrence, ingredient: ingredient) }

    var body: some View {
        Form {
            if let record = PantryLotReview(model: model, shopID: shopID, lotID: lotID), record.lot.selected,
               record.delivery.meals?.contains(occurrence) == true, let planning = occurrence.meal.planning {
                let matched = record.lot.matches.contains(target)
                Section(record.lot.foodName) {
                    LabeledContent(ht("Storage location"), value: pantryLocation(record.lot.location))
                    LabeledContent(ht("Confirmed usable quantity"), value: deliveryQuantityText(record.lot.observation?.quantity))
                    if !record.lot.exclusionTags.isEmpty {
                        LabeledContent(ht("Food exclusions"), value: record.lot.exclusionTags.joined(separator: ", "))
                    }
                }
                Section(occurrence.meal.title + " · " + occurrence.meal.day) {
                    SharedMealPreparationFacts(planning: planning)
                    LabeledContent(ht("Ingredient quantity"), value: deliveryQuantityText(ingredient.quantity))
                    if !ingredient.exclusions.isEmpty {
                        LabeledContent(ht("Ingredient exclusions"), value: ingredient.exclusions.joined(separator: ", "))
                    }
                    ForEach(planning.groups.filter { ingredient.groupIds.contains($0.id) }) { group in
                        let required = record.delivery.reservableQuantity(for: target, group: group.id)
                        let reservation = record.lot.reservations.first { sameIngredient($0) && $0.groupId == group.id }
                        if group.protected || occurrence.meal.protected {
                            Label(group.name, systemImage: "lock").accessibilityLabel(group.name + ", " + ht("Protected portions"))
                        } else { Text(group.name) }
                        LabeledContent(ht("Required for group"), value: deliveryQuantityText(required))
                        if let saved = reservation?.quantity {
                            LabeledContent(ht("Set aside from this batch"), value: deliveryQuantityText(saved))
                        }
                        if matched, model.shop?.phase == "placed", model.pending == nil, let required,
                           let unit = UnitOfMeasure(rawValue: required.unit), reservation?.quantity != nil || record.lot.observation?.quantity != nil {
                            Button(ht("Set food aside") + " · " + group.name) {
                                reserving = .init(group: group, record: record, target: target, head: reservation, unit: unit, required: required)
                            }
                            .accessibilityIdentifier("pantry.group." + group.id.uuidString)
                        }
                    }
                }
                if model.shop?.phase == "placed", model.pending == nil {
                    Section {
                        Button(matched ? ht("Remove ingredient match") : ht("Match this ingredient")) {
                            Task {
                                let saved = await model.savePantry(.match(lot: lotID, ingredient: target, matched: !matched),
                                                                   reviewed: record.pantry, delivery: record.delivery)
                                error = saved ? nil : model.notice ?? ht("Refresh deliveries and review the current record.")
                            }
                        }
                        .disabled(model.busy || record.lot.reservations.contains { sameIngredient($0) && $0.quantity != nil })
                        .accessibilityIdentifier("pantry.match")
                    } footer: { Text(ht("Matching identifies the food. Portions are reserved separately.")) }
                }
            } else { Text(ht("Refresh deliveries and review the current record.")) }
            if let error { Text(error) }
        }
        .navigationTitle(ingredient.name)
        .sheet(item: $reserving) { review in
            if model.canReadPantry { PantryReservationEditor(model: model, review: review) }
        }
    }

    private func sameIngredient(_ head: SharedDeliveryPage.Reservation) -> Bool {
        head.occurrenceId == occurrence.id && head.mealRevision == occurrence.revision && head.ingredientId == ingredient.id
    }
}

private struct PantryReservationReview: Identifiable {
    var id: UUID { group.id }
    let group: SharedMealPlanning.Group
    let record: PantryLotReview
    let target: SharedDeliveryPage.IngredientMatch
    let head: SharedDeliveryPage.Reservation?
    let unit: UnitOfMeasure
    let required: SharedMealQuantity
}

private struct PantryReservationEditor: View {
    @ObservedObject var model: HouseholdShopModel
    let review: PantryReservationReview
    @State private var amount = ""
    @State private var releasing = false
    @State private var error: String?
    @FocusState private var editing: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(review.record.lot.foodName) {
                    LabeledContent(ht("Serving group"), value: review.group.name)
                    LabeledContent(ht("Required for group"), value: deliveryQuantityText(review.required))
                    LabeledContent(ht("Confirmed usable quantity"), value: deliveryQuantityText(review.record.lot.observation?.quantity))
                    if let current = review.head?.quantity {
                        LabeledContent(ht("Set aside from this batch"), value: deliveryQuantityText(current))
                    }
                    TextField(ht("Amount to set aside"), text: $amount).focused($editing)
                        .accessibilityIdentifier("pantry.reserveAmount")
                    LabeledContent(ht("Unit"), value: dinnerUnit(review.unit))
                }
                if review.head?.quantity != nil {
                    Button(ht("Release this reservation"), role: .destructive) { editing = false; releasing = true }
                        .disabled(model.busy)
                        .confirmationDialog(ht("Release this reservation?"), isPresented: $releasing, titleVisibility: .visible) {
                            Button(ht("Release amount set aside"), role: .destructive) { Task { await save(nil) } }
                            Button(ht("Cancel"), role: .cancel) {}
                        }
                }
                if let error { Text(error) }
            }
            .navigationTitle(ht("Set food aside"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ht("Save")) {
                        guard let quantity = proposed else { return }
                        editing = false
                        Task { await save(quantity) }
                    }.disabled(proposed == nil || model.busy).accessibilityIdentifier("pantry.saveReservation")
                }
            }
            .interactiveDismissDisabled(model.busy)
        }
    }

    private var proposed: SharedMealQuantity? {
        guard let value = try? DinnerEntry.positive(amount) else { return nil }
        return .init(amount: .init(numerator: Int(value.numerator), denominator: Int(value.denominator)),
                     unit: review.unit.rawValue, originalLiteral: amount)
    }

    private func save(_ quantity: SharedMealQuantity?) async {
        let edit = SharedPantryEdit.reserve(lot: review.record.lot.id, ingredient: review.target, group: review.group.id,
                                           previous: review.head?.reservationId, quantity: quantity)
        if await model.savePantry(edit, reviewed: review.record.pantry, delivery: review.record.delivery) {
            dismiss()
        } else { error = model.notice ?? ht("Refresh deliveries and review the current record.") }
    }
}
