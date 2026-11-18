import SwiftUI
import CoreDomain

struct DinnerSwapView: View {
    @ObservedObject var model: DinnerFeatureModel
    let meal: MealOccurrence
    @EnvironmentObject private var pickup: PickupModel
    @Environment(\.advanceToDinnerApply) private var advance
    @Environment(\.closeDinnerDecision) private var close
    @State private var owner: DinnerFeatureModel.EditorIdentity?
    @State private var groupID: UUID?
    @State private var options: [DinnerSwapOption] = []
    @State private var selected: UUID?
    @State private var matches: [UUID: UUID] = [:]

    var body: some View {
        Form {
            if owner == model.editorIdentity, model.accessAvailable {
                Section {
                    Text(meal.title).font(.headline)
                    Text(meal.scheduledDay.map(dinnerDay) ?? dinnerText("Unscheduled"))
                    if !meal.servingGroups.isEmpty {
                        Picker(dinnerText("Portion to replace"), selection: $groupID) {
                            Text(dinnerText("Whole dinner")).tag(nil as UUID?)
                            ForEach(meal.servingGroups.filter { !$0.isProtected }) { group in
                                Text(group.name).tag(Optional(group.id))
                            }
                        }
                        ForEach(meal.servingGroups.filter(\.isProtected)) { group in
                            LabeledContent(dinnerText("Protected portion"), value: group.name)
                        }
                    }
                }
                Section(dinnerText("Replacement dinner")) {
                    ForEach(options) { option in
                        VStack(alignment: .leading, spacing: 4) {
                            Button {
                                if selected != option.id { selected = option.id; matches = [:] }
                            } label: {
                                HStack {
                                    Text(option.title)
                                    if selected == option.id { Image(systemName: "checkmark").accessibilityHidden(true) }
                                }
                            }.disabled(!option.canChoose)
                                .accessibilityAddTraits(selected == option.id ? .isSelected : [])
                                .accessibilityIdentifier("swap.option." + option.id.uuidString)
                            if let issue = option.issue { Text(issueText(issue)).font(.subheadline) }
                            ForEach(Array((option.eligibility.blocked + option.eligibility.unresolved +
                                          option.eligibility.softDifferences).enumerated()), id: \.offset) { _, issue in
                                Text(tonightIssue(issue)).font(.subheadline)
                            }
                        }
                    }
                    if options.allSatisfy({ !$0.canChoose }) {
                        Text(dinnerText("Review a recipe for the selected servings in the dinner library. You can choose one accepted dinner as your Free reusable dinner."))
                    }
                    NavigationLink(dinnerText("Dinner library")) { DinnerLibraryView(model: model) }
                        .accessibilityIdentifier("swap.library")
                }
                if let option = options.first(where: { $0.id == selected && $0.canChoose }) {
                    Section(dinnerText("Match replacement ingredients")) {
                        ForEach(option.template.ingredients) { ingredient in
                            Picker(ingredient.name, selection: Binding(get: { matches[ingredient.id] }, set: { id in
                                matches[ingredient.id] = id
                            })) {
                                Text(dinnerText("Leave unmatched")).tag(nil as UUID?)
                                ForEach(option.foods) { food in
                                    Text(food.name + " · " + food.detail).tag(Optional(food.id))
                                }
                            }
                        }
                    }
                    Button(dinnerText("Review this swap")) {
                        do {
                            let reviewed = try model.prepareSwap(option, pickup: pickup, reviewedFoods: matches)
                            if model.installSwap(reviewed, pickup: pickup) { advance?() }
                        } catch { model.report(error) }
                    }.disabled(!model.editable).accessibilityIdentifier("swap.preview")
                }
                DinnerFeedback(model: model)
            }
        }.navigationTitle(dinnerText("Swap this dinner")).dinnerAccess(model)
            .onAppear {
                guard owner == nil || owner == model.editorIdentity else { close?(); return }
                owner = model.editorIdentity
                reload()
            }
            .onChange(of: groupID) { _, _ in reload() }
            .onChange(of: model.editorIdentity) { _, current in if current != owner { close?() } }
    }

    private func reload() {
        selected = nil; matches = [:]
        do { options = try model.swapOptions(occurrenceID: meal.id, groupID: groupID, pickup: pickup) }
        catch { options = []; model.report(error) }
    }

    private func issueText(_ issue: DinnerSwapOption.Issue) -> String {
        switch issue {
        case .servingsMismatch: dinnerText("Review a recipe with the same serving count as this portion.")
        case .protectedTarget: dinnerText("This portion is protected.")
        case .targetNeedsGroup: dinnerText("Choose the serving group to replace.")
        case .linkedTarget: dinnerText("Review the existing grocery links before changing this dinner.")
        case .unavailableRecipe: dinnerText("Review the saved recipe before using it here.")
        case .paidAccessRequired: dinnerText("Choose this recipe as your Free reusable dinner or use an active planning seat.")
        }
    }
}

struct DinnerSwapEvidenceView: View {
    let review: DinnerSwapReview
    let showPrices: Bool
    var body: some View {
        Section(dinnerText("Dinner swap")) {
            LabeledContent(dinnerText("Current dinner"), value: review.original.title)
            LabeledContent(dinnerText("Replacement dinner"), value: review.replacement.title)
            ForEach(review.ingredients) { ingredient in
                VStack(alignment: .leading) {
                    Text(ingredient.name).font(.headline)
                    LabeledContent(dinnerText("Before"), value: dinnerQuantity(ingredient.before))
                    LabeledContent(dinnerText("After"), value: dinnerQuantity(ingredient.after))
                }.accessibilityElement(children: .combine)
            }
        }
        if !review.foods.isEmpty {
            Section(dinnerText("Affected food and packages")) {
                ForEach(review.foods) { food in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(food.name).font(.headline)
                        LabeledContent(dinnerText("Before"), value: dinnerQuantity(food.beforeNeeded))
                        LabeledContent(dinnerText("After"), value: dinnerQuantity(food.afterNeeded))
                        ForEach(Array(food.free.enumerated()), id: \.offset) { _, quantity in
                            LabeledContent(dinnerText("Available"), value: dinnerQuantity(quantity))
                        }
                        ForEach(food.holds) { hold in
                            LabeledContent(hold.protected ? dinnerFormat("Protected for %@", hold.name) : dinnerFormat("Reserved for %@", hold.name),
                                           value: dinnerQuantity(hold.quantity))
                        }
                        if food.unresolved { Text(dinnerText("Available quantity needs review.")) }
                        if let label = food.packageLabel { Text(label) }
                        if let before = food.beforePacks, let after = food.afterPacks {
                            LabeledContent(dinnerText("Packages before and after"),
                                           value: dinnerFormat("%lld to %lld", before, after))
                        } else { Text(dinnerText("Package count needs review.")) }
                        if showPrices {
                            if let price = food.packagePrice { LabeledContent(dinnerText("Price per package"), value: dinnerMoney(price)) }
                            if let source = food.priceSource { Text(source) }
                            if let observed = food.priceDate { Text(observed.formatted(date: .abbreviated, time: .omitted)) }
                            if let before = food.beforeCost, let after = food.afterCost {
                                LabeledContent(dinnerText("Item cost before and after"), value: dinnerFormat("%@ to %@", dinnerMoney(before), dinnerMoney(after)))
                            }
                            Text(dinnerText("Confirm the current price."))
                        }
                    }
                }
            }
        }
        if !review.retained.isEmpty {
            Section(dinnerText("Food retained for reuse")) {
                ForEach(review.retained) { lot in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lot.name).font(.headline)
                        if lot.purchased { Text(dinnerText("Purchased food")) }
                        Text(pantryLocationName(lot.location) + " · " + pantryCount(lot.count))
                        Text(lot.confirmedAt.formatted(date: .abbreviated, time: .shortened))
                    }.accessibilityElement(children: .combine)
                }
            }
        }
    }
}

struct DinnerSwapUndoSection: View {
    @ObservedObject var model: DinnerFeatureModel
    let receipt: DinnerApplyReceipt
    @EnvironmentObject private var pickup: PickupModel
    @State private var reviewing = false
    var body: some View {
        if let effect = receipt.swapEffect {
            Section(dinnerText("Dinner swap")) {
                if reviewing {
                    LabeledContent(dinnerText("Replacement dinner"), value: effect.replacement.title)
                    LabeledContent(dinnerText("Dinner to restore"), value: effect.original.title)
                    Button(dinnerText("Confirm Undo")) {
                        Task { if await model.undoSwap(receipt, pickup: pickup) { reviewing = false } }
                    }.disabled(!model.editable).accessibilityIdentifier("swap.undo.confirm")
                    Button(dinnerText("Keep this swap")) { reviewing = false }
                } else {
                    Button(dinnerText("Review Undo for this swap")) { reviewing = true }
                        .accessibilityIdentifier("swap.undo.review")
                }
            }
        }
    }
}
