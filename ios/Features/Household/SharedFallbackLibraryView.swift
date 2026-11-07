import HouseholdClient
import SwiftUI

struct SharedFallbackRecipeFacts: View {
    let recipe: SharedFallbackRecipe
    var body: some View {
        Section {
            Text(verbatim: recipe.title).font(.headline)
            LabeledContent(ht("Portions"), value: String(recipe.portions))
            LabeledContent(fallbackText("Total preparation minutes"), value: recipe.elapsedMinutes.map(String.init) ?? ht("Unknown"))
            LabeledContent(sharedRecoveryText("Required lead time in minutes"), value: recipe.requiredLeadMinutes.map(String.init) ?? ht("Unknown"))
            if let url = recipe.sourceURL { LabeledContent(fallbackText("Recipe source URL"), value: url) }
            if !recipe.notes.isEmpty { Text(verbatim: recipe.notes) }
            if !recipe.exclusions.isEmpty { LabeledContent(ht("Meal exclusions"), value: recipe.exclusions.joined(separator: ", ")) }
        }
        ForEach(recipe.groups ?? []) { group in
            Section(group.name) {
                let amount = group.servings.denominator == 1 ? String(group.servings.numerator)
                    : "\(group.servings.numerator)/\(group.servings.denominator)"
                LabeledContent(ht("Portions"), value: amount)
                if group.protected { Text(ht("Protected portions")) }
                if !group.exclusions.isEmpty { Text(verbatim: group.exclusions.joined(separator: ", ")) }
            }
        }
        ForEach(recipe.ingredients) { row in
            Section(row.name) {
                LabeledContent(ht("Ingredient quantity"), value: deliveryQuantityText(row.quantity))
                if !row.notes.isEmpty { Text(verbatim: row.notes) }
                if !row.exclusions.isEmpty { LabeledContent(ht("Ingredient exclusions"), value: row.exclusions.joined(separator: ", ")) }
                ForEach((recipe.groups ?? []).filter { row.groupIds?.contains($0.id) == true }) { group in
                    let binding = row.bindings?.first(where: { $0.groupId == group.id })
                    LabeledContent(group.name, value: binding.map { deliveryQuantityText($0.quantity) } ?? ht("Unknown"))
                }
            }
        }
    }
}

private struct FallbackApprovalReview: Identifiable {
    let id = UUID()
    let candidateID: UUID
    let priorRevision: Int?
    let source: SharedFallbackSource
    let recipe: SharedFallbackRecipe
    let usual: Bool
    let library: SharedFallbackLibrary
}

struct SharedFallbackLibraryView: View {
    @ObservedObject var model: SharedFallbackModel
    let recovery: SharedRecoveryPage
    @State private var enteringRecipe = false
    @State private var approval: FallbackApprovalReview?
    @State private var entered: SharedFallbackRecipe?
    @State private var withdrawal: SharedFallbackLibrary.Candidate?
    @State private var displayingSources = false
    @State private var sourceIdeas: [SharedMealIdeaPage.Idea] = []
    @State private var sourceFailure = false
    @State private var clearing = false
    @Environment(\.scenePhase) private var scene

    var body: some View {
        List {
            if model.live, let library = model.library, library.shopId == recovery.shopId {
                if model.pending != nil {
                    Section {
                        Button(fallbackText("Retry the saved recipe change")) { Task { await model.retry() } }
                            .disabled(model.busy)
                        Button(fallbackText("Clear local retry after checking the library")) { clearing = true }
                            .disabled(model.busy)
                    }
                }
                Section {
                    if library.candidates.isEmpty { Text(fallbackText("No household fallback recipes accepted yet.")) }
                    ForEach(library.candidates) { candidate in
                        NavigationLink {
                            if model.live, model.library == library {
                                Form {
                                    SharedFallbackRecipeFacts(recipe: candidate.recipe)
                                    if candidate.usual { Text(fallbackText("Usual fallback")) }
                                    if model.canSuggest {
                                        Button(fallbackText("Review household approval")) {
                                            approval = .init(candidateID: candidate.id, priorRevision: candidate.revision,
                                                source: .disclosed, recipe: candidate.recipe, usual: candidate.usual, library: library)
                                        }
                                    }
                                    Button(fallbackText("Withdraw household approval"), role: .destructive) { withdrawal = candidate }
                                        .disabled(model.busy || model.pending != nil)
                                }.navigationTitle(candidate.recipe.title)
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(verbatim: candidate.recipe.title)
                                if candidate.usual { Text(fallbackText("Usual fallback")).font(.subheadline) }
                            }
                        }
                    }
                } header: { Text(fallbackText("Household fallback recipes")) }
                if model.canSuggest, model.pending == nil {
                    Button(fallbackText("Share one fallback recipe")) { enteringRecipe = true }
                    DisclosureGroup(fallbackText("Review a scheduled meal or approved idea"), isExpanded: $displayingSources) {
                        ForEach(recovery.meals) { meal in
                            Button { Task { await loadSource(.meal(occurrenceId: meal.id, mealRevision: meal.sourceMealRevision,
                                revisionId: recovery.mealSources.first(where: { $0.occurrenceId == meal.id })?.sealedRevisionId == meal.revisionId ? nil : meal.revisionId), library) } } label: {
                                Text(verbatim: meal.title + " · " + (sharedMealDayText(meal.day, locale: .current) ?? meal.day))
                            }
                        }
                        ForEach(sourceIdeas) { idea in
                            Button { Task { await loadSource(.idea(ideaId: idea.id, revision: idea.revision), library) } } label: {
                                Text(verbatim: idea.draft.title)
                            }
                        }
                        if sourceFailure { Button(ht("Refresh")) { Task { await loadIdeas() } } }
                    }.onChange(of: displayingSources) { _, expanded in
                        if expanded { Task { await loadIdeas() } } else { sourceIdeas = []; sourceFailure = false }
                    }
                }
            }
            if model.busy { ProgressView() }
            if let notice = model.notice { Text(verbatim: notice) }
            if model.live {
                Button(ht("Refresh")) { Task { await model.load() } }.disabled(model.busy)
            }
        }
        .navigationTitle(fallbackText("Household fallback recipes"))
        .sheet(isPresented: $enteringRecipe, onDismiss: {
            guard let recipe = entered, model.canSuggest, let library = model.library else { entered = nil; return }
            entered = nil
            approval = .init(candidateID: UUID(), priorRevision: nil, source: .disclosed, recipe: recipe, usual: false, library: library)
        }) {
            if model.canSuggest {
                NavigationStack {
                    SharedFallbackRecipeEditor { recipe in entered = recipe; enteringRecipe = false }
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { enteringRecipe = false } } }
                }
            }
        }
        .sheet(item: $approval) { selected in
            if model.canSuggest, model.library == selected.library {
                FallbackApprovalSheet(model: model, review: selected)
            }
        }
        .confirmationDialog(fallbackText("Withdraw household approval?"), isPresented: Binding(get: { withdrawal != nil }, set: { if !$0 { withdrawal = nil } }),
            titleVisibility: .visible, presenting: withdrawal) { selected in
            Button(fallbackText("Withdraw household approval"), role: .destructive) {
                guard let library = model.library, library.candidates.contains(selected) else { return }
                Task { await model.save(.revoke(candidateId: selected.id, baseRevision: selected.revision), reviewed: library) }
            }
        } message: { candidate in Text(verbatim: candidate.recipe.title) }
        .confirmationDialog(fallbackText("Clear local retry?"), isPresented: $clearing, titleVisibility: .visible) {
            Button(fallbackText("Clear local retry"), role: .destructive) {
                guard let library = model.library else { return }
                Task { await model.clearRetryAfterReview(library) }
            }
        }
        .onChange(of: scene) { _, phase in if phase != .active { clearPersonalReview() } }
        .onChange(of: model.library) { _, _ in clearPersonalReview() }
        .onChange(of: model.paidUntil) { _, _ in if !model.canSuggest { clearPersonalReview() } }
    }

    private func clearPersonalReview() {
        approval = nil; withdrawal = nil; entered = nil; enteringRecipe = false
        sourceIdeas = []; displayingSources = false; clearing = false
    }

    private func loadSource(_ source: SharedFallbackSource, _ library: SharedFallbackLibrary) async {
        do {
            let result = try await model.source(source, reviewed: library)
            guard model.live, model.canSuggest, model.library == library, scene == .active, displayingSources else { return }
            approval = .init(candidateID: UUID(), priorRevision: nil, source: result.source,
                             recipe: result.recipe, usual: false, library: library)
        } catch { }
    }

    private func loadIdeas() async {
        guard let library = model.library, model.canSuggest, displayingSources else { return }
        do {
            let ideas = try await model.approvedIdeas(reviewed: library)
            guard model.canSuggest, model.library == library, displayingSources, scene == .active else { return }
            sourceIdeas = ideas; sourceFailure = false
        } catch {
            guard model.library == library, displayingSources, scene == .active else { return }
            sourceIdeas = []; sourceFailure = true
        }
    }
}

private struct FallbackApprovalSheet: View {
    @ObservedObject var model: SharedFallbackModel
    let review: FallbackApprovalReview
    @Environment(\.dismiss) private var dismiss
    @State private var usual: Bool
    init(model: SharedFallbackModel, review: FallbackApprovalReview) {
        self.model = model; self.review = review; _usual = State(initialValue: review.usual)
    }
    var body: some View {
        NavigationStack {
            Form {
                if model.canSuggest, model.library == review.library {
                    SharedFallbackRecipeFacts(recipe: review.recipe)
                    Toggle(fallbackText("Usual fallback"), isOn: $usual)
                    Button(fallbackText("Accept this recipe for household suggestions")) {
                        let edit = SharedFallbackEdit.accept(candidateId: review.candidateID, baseRevision: review.priorRevision,
                                                             source: review.source, recipe: review.recipe, usual: usual)
                        Task { if await model.save(edit, reviewed: review.library) { dismiss() } }
                    }.disabled(model.busy || model.pending != nil)
                }
                if let notice = model.notice { Text(verbatim: notice) }
            }
            .navigationTitle(fallbackText("Review household approval"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() } } }
        }
    }
}
