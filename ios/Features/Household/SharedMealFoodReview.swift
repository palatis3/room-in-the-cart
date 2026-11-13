import Foundation
import SwiftUI
import HouseholdClient

/// A read-only catalog bound to the entered action and the current graph. Final
/// preview and Apply independently revalidate the live proposal and authority.
struct SharedMealFoodContext: Equatable {
    let request: SharedDemandActionSourceRequest
    let catalog: SharedDemandActionSources
    init(page: SharedDemandPage, request: SharedDemandActionSourceRequest, catalog: SharedDemandActionSources) throws {
        try catalog.validate(page: page, request: request)
        self.request = request; self.catalog = catalog
    }
    var mealEdit: SharedDemandMealEdit? {
        if case .patch(let patch) = request.action { return patch.mealEdit }; return nil
    }
    func prepare(_ draft: inout SharedFoodDraft, page: SharedDemandPage) throws {
        try catalog.validate(page: page, request: request)
        guard let graph = page.graph else { throw ClientError.invalidResponse }
        draft.mealSourcesReviewed = false
        draft.mealRetirements = catalog.retirementCandidates.compactMap { id in graph.contributions.first { $0.id == id }.map { SharedFoodRetirement(source: $0) } }
        draft.mealRelationships = graph.edges.map { SharedFoodRelationshipReview(edge: $0) }
        // A listed retirement may accompany an explicitly removed basket item.
        // Other meal/request/protected commitments still require keeping it.
        for i in draft.removedLines.indices { draft.removedLines[i].mealRetirementIDs = Set(catalog.retirementCandidates) }
        draft.sources = catalog.sources.filter { $0.transition != .retain }.map { row in
            let fact = row.proposed
            var value = SharedFoodSourceDraft()
            value.id = fact.id; value.source = fact.source; value.sourceLabel = fact.sourceLabel
            value.lineID = fact.requiredLineId; value.requiredLineID = fact.requiredLineId
            value.productName = fact.productName; value.originalText = fact.originalText
            value.fixedQuantity = fact.quantity; value.quantityIsFixed = true
            value.originalQuantityText = fact.originalQuantityText; value.restrictions = fact.sourceExclusions
            value.restrictionTags = Array(repeating: "", count: fact.sourceExclusions.count)
            value.previousContribution = row.before
            if let old = row.before {
                value.exclusions = old.exclusions.joined(separator: ", "); value.contains = old.contains.joined(separator: ", ")
            }
            return value
        }
    }
    func validate(_ draft: SharedFoodDraft, page: SharedDemandPage) throws {
        try catalog.validate(page: page, request: request)
        guard draft.mealSourcesReviewed,
              draft.mealRetirements.map({ $0.source.id }) == catalog.retirementCandidates,
              draft.mealRetirements.allSatisfy({ page.graph?.contributions.contains($0.source) == true }),
              draft.mealRetirements.allSatisfy(\.confirmed),
              draft.mealRelationships.map(\.edge) == page.graph?.edges,
              draft.mealRelationships.allSatisfy({ $0.decision != .unreviewed }) else { throw SharedFoodEditorError.mealReview }
        let changed = catalog.sources.filter { $0.transition != .retain }
        for row in changed {
            let fact = row.proposed
            guard let entered = draft.sources.first(where: { $0.id == fact.id }),
                  entered.source == fact.source, entered.sourceLabel == fact.sourceLabel,
                  entered.productName == fact.productName, entered.originalText == fact.originalText,
                  entered.originalQuantityText == fact.originalQuantityText,
                  entered.quantityIsFixed, entered.fixedQuantity == fact.quantity,
                  entered.previousContribution == row.before, entered.requiredLineID == fact.requiredLineId,
                  entered.restrictions == fact.sourceExclusions,
                  fact.requiredLineId == nil || entered.lineID == fact.requiredLineId else { throw ClientError.configuration }
            if let old = row.before, case .reservation = old.source {
                guard entered.contains == old.contains.joined(separator: ", "), Set(old.exclusions).isSubset(of: Set(SharedFoodSourceDraft.tags(entered.exclusions))) else { throw ClientError.configuration }
                if old.quantity == nil && fact.quantity != nil && !entered.quantificationConfirmed { throw SharedFoodEditorError.mealReview }
                // Product clarification is a separate, identity-only review.
                guard old.productKey != nil || (!draft.lines.contains(where: { $0.id == old.lineId && $0.confirmExistingSources }) && !draft.sources.contains(where: { $0.id != old.id && $0.lineID == old.lineId }) && page.graph?.contributions.contains(where: { $0.id != old.id && $0.lineId == old.lineId && $0.removedAt == nil }) != true) else { throw SharedFoodEditorError.protectedIdentity }
            }
        }
        let changedIDs = Set(changed.map { $0.proposed.id })
        for source in draft.sources where !changedIDs.contains(source.id) {
            guard case .manual = source.source, source.previousContribution == nil, page.graph?.usedIds.contains(source.id) == false else { throw ClientError.configuration }
        }
        // A removed endpoint cannot leave a relationship silently in place.
        let removed = Set(draft.mealRetirements.map { $0.source.id } + draft.removedLines.flatMap { $0.sources.map(\.id) })
        for relation in draft.mealRelationships where relation.decision == .keep {
            guard !removed.contains(relation.edge.demandId), !removed.contains(relation.edge.supplyId) else { throw SharedFoodEditorError.mealReview }
        }
    }
}
struct SharedFoodRetirement: Identifiable, Equatable {
    let source: SharedDemandContribution
    var confirmed = false
    var id: SharedDemandID { source.id }
}
struct SharedFoodRelationshipReview: Identifiable, Equatable {
    enum Decision: String, CaseIterable { case unreviewed, keep, remove }
    let edge: SharedDemandEdge
    var decision: Decision = .unreviewed
    var id: SharedDemandID { edge.id }
}

@MainActor extension SharedDemandFlowModel {
    func mealRetirementBinding(_ id: SharedDemandID) -> Binding<SharedFoodRetirement> {
        let empty = SharedDemandContribution(id: id, lineId: id, source: .manual, productKey: nil, productName: "", originalText: "", quantity: nil)
        return draftRowBinding(\.mealRetirements, id: id, empty: .init(source: empty))
    }
    func mealRelationshipBinding(_ id: SharedDemandID) -> Binding<SharedFoodRelationshipReview> {
        // Fixed nonprivate placeholder; the valid literal is never submitted.
        let quantity = SharedDemandQuantity(amount: try! .init(numerator: 1), unit: .count, originalLiteral: "")
        let empty = SharedDemandEdge(id: id, kind: .withinExisting, demandId: id, supplyId: id, quantity: quantity,
            confirmation: .init(productMatchConfirmed: false, confirmedAt: "", evidence: ""))
        return draftRowBinding(\.mealRelationships, id: id, empty: .init(edge: empty))
    }
}
