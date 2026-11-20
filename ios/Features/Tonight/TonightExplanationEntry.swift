import SwiftUI
import CoreDomain
import HouseholdClient

func mealExplanationText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "TonightExplanations")
}

@MainActor struct TonightExplanationEntry: View {
    @ObservedObject var meals: TonightMealModel
    let ledgerID: UUID
    let authorize: () -> Bool
    let refresh: () async -> Void
    let choose: (MealTemplate) -> Void
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @State private var session: Session?
    private struct Session: Identifiable {
        let id = UUID()
        let identity: CapturePrivateIdentity
        let scope: ReceiptAssistanceScope
        let snapshot: TonightExplanationModel.Snapshot
    }
    private var identity: CapturePrivateIdentity? {
        guard scene == .active, authorize(), UIApplication.shared.isProtectedDataAvailable,
              UIApplication.shared.applicationState == .active, !household.guardianChildOnly,
              household.projection?.grantId == nil,
              let value = CapturePrivateIdentity.current(access: access, household: household), value.subject != nil else { return nil }
        return value
    }
    private var scope: ReceiptAssistanceScope? {
        guard let value = identity, let subject = value.subject, let house = value.householdID, let member = value.memberID else { return nil }
        return .init(subject: subject, householdID: house, memberID: member, shopID: household.projection?.shopId)
    }
    var body: some View {
        Section(mealExplanationText("Optional meal explanations")) {
            Text(mealExplanationText("Tonight’s matches work on this device. Online help can propose among meals you have already reviewed; it cannot change stock, prices or preferences."))
            if let identity, let scope, let service = household.service {
                Button(mealExplanationText("Review meals to share")) {
                    Task { @MainActor in
                        await refresh()
                        guard self.identity == identity, self.scope == scope,
                              let snapshot = try? TonightExplanationModel.Snapshot(model: meals, ledgerID: ledgerID), !snapshot.candidates.isEmpty else { return }
                        session = Session(identity: identity, scope: scope, snapshot: snapshot)
                    }
                }.disabled(meals.busy || !meals.suggestions.contains(where: TonightMealModel.canChoose))
                    .accessibilityIdentifier("tonight.explanations.open")
                .sheet(item: $session) { original in
                    NavigationStack {
                        TonightExplanationReview(snapshot: original.snapshot, service: service, scope: original.scope,
                            isCurrent: { self.identity == original.identity && self.scope == original.scope && original.snapshot.isCurrent(in: meals) },
                            refresh: { await refresh(); return self.identity == original.identity && self.scope == original.scope && original.snapshot.isCurrent(in: meals) },
                            choose: { recipe in
                                guard self.identity == original.identity, self.scope == original.scope, original.snapshot.isCurrent(in: meals) else { return }
                                session = nil; choose(recipe)
                            })
                    }
                }
            } else {
                Text(mealExplanationText("Online help requires an authorized adult account. Keep reviewing local matches without signing in."))
            }
        }
        .onChange(of: identity) { _, _ in session = nil }
        .onChange(of: scene) { _, phase in if phase != .active { session = nil } }
    }
}

@MainActor private struct TonightExplanationReview: View {
    let snapshot: TonightExplanationModel.Snapshot
    let service: HouseholdService
    let scope: ReceiptAssistanceScope
    let isCurrent: () -> Bool
    let refresh: () async -> Bool
    let choose: (MealTemplate) -> Void
    @StateObject private var model = TonightExplanationModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @State private var selected = Set<UUID>()
    @State private var available: Bool?
    @State private var task: Task<Void, Never>?
    private var language: String { Locale.current.language.languageCode?.identifier ?? "" }
    var body: some View {
        WorkingForm {
            if scene != .active || !isCurrent() {
                Text(mealExplanationText("Meals, pantry or access changed. Close this review and refresh Tonight."))
            } else if available == nil { ProgressView() }
            else if available == false {
                Text(mealExplanationText("Online help is unavailable. Your local meal matches are unchanged."))
            } else if let reply = model.reply {
                Section(mealExplanationText("Review proposed meals")) {
                    if reply.suggestions.isEmpty { Text(mealExplanationText("No meal was proposed. Continue with your local matches.")) }
                    ForEach(reply.suggestions, id: \.sourceLineID) { suggestion in
                        if let candidate = snapshot.candidates.first(where: { $0.id == suggestion.sourceLineID }) {
                            Text(candidate.review.recipe.title).font(.headline)
                            ForEach(suggestion.reasons, id: \.self) { Text(reasonText($0)) }
                            // Quantities, dates and prices never come from generated text.
                            ForEach(candidate.review.numericIngredients) { row in
                                LabeledContent(row.ingredient.name, value: ledgerQuantity(TonightMealModel.missingQuantity(row)))
                            }
                            Text(mealExplanationText("Amounts above still need to be obtained; zero means covered. All figures come from the current local review."))
                            TonightPricesView(estimate: try? TonightPurchaseEstimate.estimate(candidate.review,
                                workspace: snapshot.input.workspace, workspaceID: snapshot.ledgerID,
                                shopID: snapshot.input.workspace.selectedShopID, at: Date()), hasHandCheckedIngredients: candidate.review.hasHandCheckedIngredients)
                            Button(mealExplanationText("Choose this meal for the usual preview")) {
                                task = Task { @MainActor in
                                    guard isCurrent(), await refresh(), !Task.isCancelled, isCurrent() else { model.clear(); return }
                                    choose(candidate.review.recipe)
                                }
                            }.accessibilityIdentifier("tonight.explanations.choose.\(candidate.id)")
                        }
                    }
                    Text(mealExplanationText("This proposal has not saved a dinner or changed any food. Review the destination and confirm in Tonight."))
                }
            } else {
                Section(mealExplanationText("Choose what to share with OpenAI")) {
                    Text(mealExplanationText("Select up to eight reviewed meals. Sending shares only their displayed titles, reference IDs, language and the explanation labels below. Ingredient names, quantities, prices and your preference profile stay on this device. Do not select a title containing details you do not want to share."))
                    ForEach(snapshot.candidates) { candidate in
                        Toggle(candidate.review.recipe.title, isOn: Binding(get: { selected.contains(candidate.id) }, set: { value in
                            if value { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
                        })).disabled(model.busy || (!selected.contains(candidate.id) && selected.count >= 8))
                        ForEach(candidate.reasons, id: \.self) { Text(reasonText($0)).font(.caption) }
                    }
                    Button(mealExplanationText("Send selected meals for a proposal")) {
                        task = Task { @MainActor in
                            await model.send(snapshot: snapshot, selected: selected, locale: language,
                                isCurrent: { scene == .active && isCurrent() }, refresh: refresh,
                                transport: { try await service.mealExplanations($0, scope: scope) })
                        }
                    }.disabled(model.busy || (try? snapshot.request(selected: selected, locale: language)) == nil)
                        .accessibilityIdentifier("tonight.explanations.send")
                    if model.busy { ProgressView() }
                    if model.failed { Text(mealExplanationText("The proposal could not be verified. Local matches are unchanged. You may retry or close this review.")) }
                }
            }
        }
        .navigationTitle(mealExplanationText("Meal explanations"))
        .privacySensitive()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(mealExplanationText("Close")) { cancel(); dismiss() } } }
        .task {
            guard isCurrent() else { return }
            let result = (try? await service.languageAssistanceAvailable(purpose: "meal-explanations", scope: scope)) ?? false
            if !Task.isCancelled, isCurrent() { available = result }
        }
        .onDisappear { cancel() }
        .onChange(of: scene) { _, phase in if phase != .active { cancel(); dismiss() } }
    }
    private func cancel() { task?.cancel(); task = nil; model.clear() }
    private func reasonText(_ value: MealExplanationReason) -> String {
        switch value {
        case .pantryMatch: mealExplanationText("Uses some reviewed, unreserved pantry food.")
        case .ingredientsCovered: mealExplanationText("All reviewed ingredients are covered by currently free food.")
        case .needsMoreFood: mealExplanationText("Some ingredients still need to be obtained.")
        case .reviewedPreparationTime: mealExplanationText("Preparation time has been reviewed.")
        }
    }
}
