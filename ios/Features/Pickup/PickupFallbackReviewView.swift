import SwiftUI
import CoreDomain

struct PickupFallbackReviewEntry: View {
    @ObservedObject var model: PickupModel
    @ObservedObject var ledger: LedgerModel
    @EnvironmentObject private var membership: MembershipCoordinator
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    let select: (PickupFallbackOption,UUID,Date) -> Void

    private var permitted: Bool {
        access.unlocked && !household.locked && (household.projection.map { ["shopper","organizer"].contains($0.role) } ?? true) &&
        membership.model?.hasPaidAccess == true && ledger.ready && !ledger.saving && !ledger.hasPendingSave && model.ready && !model.saving && !model.hasPendingSave
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { tick in
            if permitted, let journey = model.journey {
                let state = ledger.workspace.dinnerPlanning
                let shop = ledger.workspace.shops.first { $0.id == journey.id }
                let chosen = Set((shop?.mealOccurrences ?? []).filter { $0.removedAt == nil }.compactMap(\.templateID))
                PickupFallbackReviewView(journey: journey, library: state.acceptedDinners.filter(\.acceptedFallback), chosen: chosen,
                                         now: tick.date, authorized: { permitted && model.journey?.revision == journey.revision &&
                                            model.journey?.id == journey.id && ledger.workspace.dinnerPlanning.revisionID == state.revisionID &&
                                            ledger.workspace.shops.first(where: { $0.id == journey.id })?.revisionID == shop?.revisionID }, select: select)
                    .id("\(journey.id)/\(journey.revision)/\(state.revisionID)/\(shop?.revisionID.uuidString ?? "")")
            } else { Text(dinnerText("This assisted tool requires paid access. Manual dinner editing remains available.")).padding() }
        }.navigationTitle(dinnerText("Recover with an accepted dinner"))
            .task { if !ledger.ready { await ledger.open() } }
    }
}

private struct PickupFallbackReviewView: View {
    let journey: PickupJourney
    let library: [AcceptedDinner]
    let chosen: Set<UUID>
    let now: Date
    let authorized: () -> Bool
    let select: (PickupFallbackOption,UUID,Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var review = PickupFallbackReview()
    private var choices: [StockNeed] { PickupFallbackOptions.needs(journey) }
    private var foodNames: [UUID:String] {
        var names = Dictionary(uniqueKeysWithValues: (journey.pickup?.orderLines ?? []).map { ($0.id,$0.name) })
        for lot in PickupFallbackOptions.lots(journey, at: now) { names[lot.foodID] = names[lot.foodID] ?? lot.name }
        return names
    }
    private func rankedBest(at date: Date) -> PickupFallbackOption? {
        try? PickupFallbackOptions.ranked(journey: journey, library: library, chosenTemplates: chosen,
                                          draft: review.draft, at: date, paid: authorized()).first
    }

    var body: some View {
        let draft = review.draft
        let best = review.isReviewed ? rankedBest(at: now) : nil
        Form {
            Section {
                Text(dinnerText("Only checked usable food from this pickup and its confirmed stock can feed a fallback. All other named needs stay reserved."))
                Picker(dinnerText("Need to repair"), selection: $review.draft.target) {
                    Text(dinnerText("Choose a meal")).tag(UUID?.none)
                    ForEach(choices.filter { $0.priority != .protected && !journey.recoveryCurrentUrgent.filter(\.resolved).map(\.id).contains($0.id) }) { need in
                        Text(need.name).tag(Optional(need.id))
                    }
                }
                TextField(dinnerText("Required portions"), text: $review.draft.portions)
                Toggle(dinnerText("Meal deadline is known"), isOn: Binding(get: { review.draft.deadline != nil }, set: { review.draft.deadline = $0 ? Date() : nil }))
                if let date = Binding($review.draft.deadline) { DatePicker(dinnerText("Meal deadline"), selection: date) }
                ForEach(choices.filter { $0.id != draft.target }) { need in
                    Text(dinnerFormat("Reserved: %@ · %@",need.name,dinnerQuantity(need.amount)))
                }
                if let rule = journey.recoveryCurrentDetails.first(where: { $0.id == draft.target }), !rule.exclusions.isEmpty { Text(rule.exclusions.joined(separator: ", ")) }
                TextField(dinnerText("Usual fallback minutes, optional"), text: $review.draft.usualMinutes)
                TextField(dinnerText("Maximum available for a top-up, USD"), text: $review.draft.topUpBudget)
                TextField(dinnerText("Top-up fees and tax, including zero, USD"), text: $review.draft.topUpCharges)
                TextField(dinnerText("Round-trip minutes for a top-up"), text: $review.draft.tripMinutes)
                Toggle(dinnerText("I agree to consider a repeated dinner"), isOn: $review.draft.permitsRepeat)
            }
            Section(dinnerText("Accepted fallbacks")) {
                if library.isEmpty { Text(dinnerText("No household dinner is marked as an accepted fallback.")) }
                ForEach(library) { dinner in
                    NavigationLink(dinner.template.title) {
                        FallbackRecipeEditor(dinner: dinner, foods: foodNames, review: Binding(get: { review.draft.reviews[dinner.id] ?? .init() }, set: { review.draft.reviews[dinner.id] = $0 }))
                    }
                }
                Button(dinnerText("Review feasible repairs")) { if authorized() { review.reviewDraft() } }
                    .disabled(draft.target == nil || draft.deadline == nil || draft.portions.isEmpty)
            }
            if review.isReviewed {
                Section(dinnerText("Smallest feasible repair")) {
                    if let best {
                        Text(best.instruction)
                        Text(dinnerFormat("Remaining time including any trip: %d minutes",best.minutes))
                        if let usual = try? DinnerEntry.minutes(draft.usualMinutes) {
                            Text(dinnerFormat("Your usual fallback: %d minutes",usual))
                        }
                        ForEach(best.buys) { buy in Text("\(buy.label) × \(buy.count) · \(dinnerMoney(buy.cost))") }
                        if best.requiresTrip {
                            Text(dinnerFormat("Extra checkout including entered fees and tax: %@",dinnerMoney(best.extraCash)))
                            Toggle(dinnerText("I agree to an extra top-up trip for this repair"), isOn: Binding(
                                get: { review.agreedTrip == best },
                                set: { agrees in
                                    if review.isReviewed, draft == review.draft { review.agreedTrip = agrees ? best : nil }
                                }
                            ))
                        }
                        Button(dinnerText("Use in manual repair instructions")) {
                            guard draft == review.draft, let target = draft.target, let due = draft.deadline,
                                  let fresh = rankedBest(at: Date()),
                                  review.canUse(best, fresh: fresh) else {
                                review.agreedTrip = nil
                                return
                            }
                            let savedDue = journey.savedMealDeadline(for: target)
                            select(fresh,target,min(due,savedDue ?? due)); dismiss()
                        }.disabled(best.requiresTrip && review.agreedTrip != best)
                    } else { Text(dinnerText("No feasible accepted repair is confirmed. Keep the need open or edit it manually.")) }
                }
            }
        }
        .onChange(of: best) { _, updated in review.rankedOfferChanged(to: updated) }
        .onChange(of: draft.target) { _, new in
            review.draft.deadline = journey.savedMealDeadline(for: new)
            review.draft.reviews = [:]
        }
    }
}

private struct FallbackRecipeEditor: View {
    let dinner: AcceptedDinner
    let foods: [UUID:String]
    @Binding var review: FallbackRecipeReview
    var body: some View {
        Form {
            Text(dinnerFormat("Servings: %@",dinner.template.servings.description))
            ForEach(dinner.template.ingredients) { ingredient in
                let binding = Binding(get: { review.ingredients[ingredient.id] ?? FallbackIngredientReview() }, set: { review.ingredients[ingredient.id] = $0 })
                Section(ingredient.name) {
                    Text(dinnerQuantity(ingredient.quantity))
                    let rules = dinner.template.exclusions + ingredient.exclusions
                    if !rules.isEmpty { Text(rules.joined(separator: ", ")) }
                    Picker(dinnerText("Reviewed food identity"), selection: binding.foodID) {
                        Text(dinnerText("Select a food identity")).tag(UUID?.none)
                        ForEach(foods.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in Text(foods[id] ?? "").tag(Optional(id)) }
                        if foods[ingredient.id] == nil { Text(dinnerText("Top-up only for this ingredient")).tag(Optional(ingredient.id)) }
                    }
                    TextField(dinnerText("Pack description"), text: binding.packLabel)
                    TextField(dinnerText("Usable amount per pack"), text: binding.packYield)
                    DinnerUnitPicker(unit: binding.packUnit)
                    TextField(dinnerText("Price per pack"), text: binding.packPrice)
                    TextField(dinnerText("Confirmed packages available"), text: binding.availablePacks)
                }
            }
            Section(dinnerText("Preparation timing")) {
                if let lead = dinner.template.leadTimeMinutes { Text(dinnerFormat("Saved elapsed preparation: %d minutes",lead)) }
                TextField(dinnerText("Reviewed remaining elapsed minutes"), text: $review.elapsedMinutes)
                Toggle(dinnerText("I checked that the required advance steps are already complete"), isOn: $review.completedLeadReviewed)
                Toggle(dinnerText("I checked these food identities, yields and exclusions for this meal"), isOn: $review.reviewedIdentityYieldAndExclusions)
            }
        }.navigationTitle(dinner.template.title)
    }
}
