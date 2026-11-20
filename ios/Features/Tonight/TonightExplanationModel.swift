import Foundation
import Combine
import CoreDomain
import HouseholdClient

/// A non-persisted proposal. Neither a provider response nor selecting a row can
/// allocate food or save a dinner; the ordinary Tonight preview remains required.
@MainActor final class TonightExplanationModel: ObservableObject {
    struct Candidate: Identifiable {
        let review: PantryMealMatcher.Review
        let reasons: [MealExplanationReason]
        var id: UUID { review.id }
    }
    @MainActor struct Snapshot {
        let input: TonightMealModel.Input
        let ledgerID: UUID
        let candidates: [Candidate]
        let reviews: [PantryMealMatcher.Review]
        let matches: [UUID: [UUID: UUID]]
        init(model: TonightMealModel, ledgerID: UUID) throws {
            guard let input = model.input, !model.busy, !model.failed else { throw TonightMealModel.Failure.unavailable }
            self.input = input; self.ledgerID = ledgerID; reviews = model.reviews; matches = model.matches
            candidates = model.suggestions.filter(TonightMealModel.canChoose).map { review in
                var reasons: [MealExplanationReason] = [.pantryMatch]
                if review.allIngredientsCovered { reasons.append(.ingredientsCovered) }
                else if !review.measuredIngredientsCovered { reasons.append(.needsMoreFood) }
                if review.recipe.leadTimeMinutes != nil { reasons.append(.reviewedPreparationTime) }
                return Candidate(review: review, reasons: reasons)
            }
        }
        func isCurrent(in model: TonightMealModel) -> Bool {
            guard let current = model.input, !model.busy, !model.failed else { return false }
            return current.basis == input.basis && current.workspace == input.workspace &&
                current.ledgerRevision == input.ledgerRevision && current.sources == input.sources &&
                current.freeLots == input.freeLots && current.unresolvedFoods == input.unresolvedFoods &&
                current.foods == input.foods && model.reviews == reviews && model.matches == matches
        }
        func request(selected: Set<UUID>, locale: String) throws -> MealExplanationRequest {
            guard !selected.isEmpty, selected.count <= 8, selected.isSubset(of: Set(candidates.map(\.id))) else {
                throw TonightMealModel.Failure.stale
            }
            let chosen = candidates.filter { selected.contains($0.id) }
            return try MealExplanationRequest(consentingTo: chosen.map { .init(id: $0.id, text: $0.review.recipe.title) },
                candidates: chosen.map { .init(id: $0.id, allowedReasons: $0.reasons) }, locale: locale)
        }
    }
    @Published private(set) var reply: MealExplanationReply?
    @Published private(set) var busy = false
    @Published private(set) var failed = false
    private var generation = UUID()
    private var retainedRequest: MealExplanationRequest?

    func clear() {
        generation = UUID(); reply = nil; retainedRequest = nil; busy = false; failed = false
    }
    func send(snapshot: Snapshot, selected: Set<UUID>, locale: String,
              isCurrent: () -> Bool, refresh: () async -> Bool,
              transport: (MealExplanationRequest) async throws -> MealExplanationReply) async {
        guard !busy else { return }
        guard isCurrent() else { clear(); return }
        let token = generation
        busy = true; failed = false; reply = nil
        defer { if token == generation { busy = false } }
        do {
            let refreshed = await refresh()
            guard token == generation else { return }
            guard refreshed, !Task.isCancelled, isCurrent() else { clear(); return }
            let prepared = try snapshot.request(selected: selected, locale: locale)
            // Retain the exact identity for an explicit retry of identical consent.
            let request: MealExplanationRequest
            if let prior = retainedRequest, prior.sourceLines == prepared.sourceLines,
               prior.candidates == prepared.candidates, prior.locale == prepared.locale { request = prior }
            else { request = prepared; retainedRequest = prepared }
            let result = try await transport(request)
            try result.validate(for: request)
            guard token == generation else { return }
            guard !Task.isCancelled, isCurrent() else { clear(); return }
            let stillCurrent = await refresh()
            guard token == generation else { return }
            guard stillCurrent, !Task.isCancelled, isCurrent() else { clear(); return }
            reply = result
        } catch {
            guard token == generation else { return }
            if !isCurrent() || Task.isCancelled { clear() }
            else { failed = true }
        }
    }
}
