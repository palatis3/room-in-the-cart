import SwiftUI
import HouseholdClient

enum SharedTrackingFacts {
    @ViewBuilder static func factFacts(_ fact: SharedTrackingFact) -> some View {
        Text(fact.sourceLabel).font(.headline)
        Text(fact.originalText)
        if let text = fact.originalQuantityText { LabeledContent(st("Original quantity wording"), value: text) }
        LabeledContent(SharedDemandCopy.source(fact.source), value: SharedDemandCopy.quantity(fact.quantity))
        sourceIdentity(fact.source)
        if case .reservation = fact.source { Text(st("Protected commitment · hiding it does not remove it")) }
        restrictions(fact.sourceExclusions)
        if let quantity = fact.quantity { conversion(quantity) }
    }
    @ViewBuilder static func contribution(_ source: SharedDemandContribution) -> some View {
        Text(source.productName).font(.headline); Text(source.originalText)
        LabeledContent(SharedDemandCopy.source(source.source), value: SharedDemandCopy.quantity(source.quantity))
        sourceIdentity(source.source)
        if case .reservation = source.source { Text(st("Protected commitment · hiding it does not remove it")) }
        if let quantity = source.quantity { conversion(quantity) }
        restrictions(source.sourceExclusions ?? [])
        if !source.exclusions.isEmpty { LabeledContent(st("Exclusions"), value: source.exclusions.joined(separator: ", ")) }
        if !source.contains.isEmpty { LabeledContent(st("Contains"), value: source.contains.joined(separator: ", ")) }
        if source.productKey == nil { Text(st("Food identity remains unresolved")) }
        if source.removedAt != nil { Text(st("Removed source assertion")) }
    }
    @ViewBuilder static func sourceIdentity(_ source: SharedDemandSource) -> some View {
        // Source IDs/revisions are shown as provenance, not as authorization.
        switch source {
        case .request(let id, let revision):
            LabeledContent(st("Request identity"), value: id.string)
            LabeledContent(st("Accepted request revision"), value: String(revision))
        case .meal(let occurrence, let ingredient, let group, let binding):
            LabeledContent(st("Meal occurrence"), value: occurrence.string)
            LabeledContent(st("Ingredient identity"), value: ingredient.string)
            if let group { LabeledContent(st("Group identity"), value: group.string) }
            if let binding { LabeledContent(st("Binding identity"), value: binding.string) }
        case .reservation(let id, let purpose, let occurrence, let ingredient, let group, let binding):
            LabeledContent(st("Reservation identity"), value: id.string)
            if let occurrence { LabeledContent(st("Meal occurrence"), value: occurrence.string) }
            LabeledContent(st("Ingredient identity"), value: ingredient.string)
            Text(purpose)
            if let group { LabeledContent(st("Group identity"), value: group.string) }
            if let binding { LabeledContent(st("Binding identity"), value: binding.string) }
        case .imported(let batch, let entry):
            LabeledContent(st("Import batch identity"), value: batch.string)
            LabeledContent(st("Import entry identity"), value: entry.string)
        case .manual: EmptyView()
        }
    }
    @ViewBuilder static func restrictions(_ values: [SharedDemandSourceExclusion]) -> some View {
        ForEach(Array(values.enumerated()), id: \.offset) { _, value in
            Text(value.label)
            LabeledContent(st("Restriction source"), value: value.occurrenceId.string)
            switch value.resolution {
            case .unresolved: Text(st("Restriction mapping unknown"))
            case .mapped(let tags, let at): Text(tags.joined(separator: ", ")); Text(at)
            }
        }
    }
    @ViewBuilder static func conversion(_ quantity: SharedDemandQuantity) -> some View {
        if let basis = quantity.confirmedConversion {
            LabeledContent(st("Confirmed conversion"), value: "1 " + SharedDemandCopy.unit(basis.sourceUnit) + " = " + SharedDemandCopy.amount(basis.targetAmountPerSourceUnit) + " " + SharedDemandCopy.unit(basis.targetUnit))
            Text(basis.sourceNote); Text(basis.confirmedAt)
        }
    }
    @ViewBuilder static func graphFacts(_ graph: SharedDemandGraph, title: String) -> some View {
        Section(title) {
            ForEach(graph.lines, id: \.id) { line in
                VStack(alignment: .leading, spacing: 8) {
                    Text(line.name).font(.headline)
                    LabeledContent(st("Food total unit"), value: SharedDemandCopy.unit(line.unit))
                    if line.trashedAt != nil { Text(st("Trashed line assertion")) }
                    ForEach(graph.contributions.filter { $0.lineId == line.id }, id: \.id) { contribution($0) }
                }.accessibilityElement(children: .contain)
            }
            ForEach(graph.edges, id: \.id) { edge in
                Text(st(edge.kind == .withinExisting ? "Within existing food" : "Explicit duplicate"))
                Text((graph.contributions.first { $0.id == edge.demandId }?.originalText ?? edge.demandId.string) + " → " + (graph.contributions.first { $0.id == edge.supplyId }?.originalText ?? edge.supplyId.string))
                Text(SharedDemandCopy.quantity(edge.quantity)); conversion(edge.quantity)
                Text(edge.confirmation.evidence); Text(edge.confirmation.confirmedAt)
            }
        }
    }
    @ViewBuilder static func coverageFacts(_ coverage: SharedTrackingCoverage, graph: SharedDemandGraph) -> some View {
        Text(st("Tracked subtotals are not complete household coverage. Unbound food is never available supply."))
        Text(st(coverage.status == .unknown ? "Food quantities remain unknown" : coverage.status == .partial ? "Partial food tracking" : "Tracked food subtotals"))
        ForEach(coverage.trackedSubtotals, id: \.lineId) { total in
            LabeledContent(graph.lines.first { $0.id == total.lineId }?.name ?? total.lineId.string,
                value: SharedDemandCopy.amount(total.quantity, unit: total.unit))
        }
        LabeledContent(st("Unbound commitments"), value: String(coverage.unboundFactIds.count))
        LabeledContent(st("Protected unbound commitments"), value: String(coverage.protectedUnboundFactIds.count))
        LabeledContent(st("Untracked basket items"), value: String(coverage.untrackedBasketIds.count))
    }
    @ViewBuilder static func basketFacts(_ row: SharedTrackingBasketLine) -> some View {
        Text(row.name)
        LabeledContent(st("Whole packs"), value: String(row.packs))
        LabeledContent(st("Unit price"), value: row.priceMinor.map { (Double($0) / 100).formatted(.currency(code: "USD")) } ?? st("Unknown"))
        Text(st(row.feeEligible ? "Counts toward the fee threshold" : "Does not count toward the fee threshold"))
    }
    @ViewBuilder static func identifiers(_ title: String, _ ids: [SharedDemandID], state: SharedTrackingState) -> some View {
        if !ids.isEmpty {
            Text(title).font(.headline)
            ForEach(ids, id: \.self) { id in Text(state.basket.first { $0.id == id }?.name ?? id.string) }
        }
    }
    static func fieldName(_ value: SharedOperationUndoTouchedLine.Field) -> String {
        switch value { case .membership: st("Basket membership"); case .originalItem: st("Item name"); case .packs: st("Whole packs"); case .unitPriceMinor: st("Price per pack"); case .feeEligible: st("Fee threshold eligibility") }
    }
    @ViewBuilder static func changes(_ changes: SharedTrackingChanges) -> some View {
        switch changes {
        case .none: EmptyView()
        case .mealActionChange(let change):
            Section(st("Meal change")) {
                if let before = change.mealChange.before?.meal {
                    Text(st("Before")); SharedMealFacts(meal: before, deadlineIdentifier: "sharedTracking.change.before.deadline")
                } else { Text(st("No current meal")) }
                if let after = change.mealChange.after.meal {
                    Text(st("After")); SharedMealFacts(meal: after, deadlineIdentifier: "sharedTracking.change.after.deadline")
                } else { Text(st("Meal removed")) }
            }
            if !change.transferredChanges.isEmpty {
                Section(st("Retained commitments")) {
                    Text(st("Unbound food remains unavailable supply."))
                    ForEach(change.transferredChanges, id: \.factId) { delta in
                        Text(st("Before")); contribution(delta.before)
                        if let after = delta.after { Text(st("After")); contribution(after) }
                        else { Text(st("Commitment removed")) }
                    }
                }
            }
        case .mealOperationUndo(let undo):
            Section(st("Whole-meal Undo")) {
                if let before = undo.mealUndo.current.meal {
                    Text(st("Before")); SharedMealFacts(meal: before, deadlineIdentifier: "sharedTracking.mealUndo.before.deadline")
                } else { Text(st("No current meal")) }
                if let after = undo.mealUndo.restoredMeal {
                    Text(st("After")); SharedMealFacts(meal: after, deadlineIdentifier: "sharedTracking.mealUndo.after.deadline")
                } else { Text(st("Meal removed")) }
                Text(st("These source, line, relationship and pack assertions are reversed together."))
                ForEach(undo.transferredChanges, id: \.factId) { delta in
                    if let before = delta.before?.transferred { Text(st("Before")); contribution(before) }
                    if let after = delta.after?.transferred { Text(st("After")); contribution(after) }
                    if delta.after == nil { Text(st("Commitment removed")) }
                }
                Text(st("Unbound food remains unavailable supply."))
            }
        case .firstAdoptionUndo(let undo):
            Section(st("Whole first-adoption inverse")) {
                LabeledContent(st("Exact target operation"), value: undo.targetOperationId.string)
                Text(st("These source, line, relationship and pack assertions are reversed together."))
                ForEach(undo.reversedAssertions.lines, id: \.id) { Text($0.name) }
                ForEach(undo.reversedAssertions.contributions, id: \.id) { contribution($0) }
                ForEach(undo.reversedAssertions.edges, id: \.id) { edge in Text(SharedDemandCopy.quantity(edge.quantity)); Text(edge.confirmation.evidence) }
                ForEach(undo.reversedAssertions.packReviews, id: \.lineId) { Text(SharedDemandCopy.quantity($0.usablePerPack)) }
                ForEach(undo.basketChanges, id: \.id) { delta in
                    if let before = delta.before { Text(st("Before")); basketFacts(before) }
                    if let after = delta.after { Text(st("After")); basketFacts(after) }
                }
                Text(st("Transferred facts remain unbound and protected; later contribution identities are retained."))
                ForEach(undo.transferredFactIds, id: \.self) { Text($0.string) }
                ForEach(undo.retainedLaterContributionIds, id: \.self) { Text($0.string) }
            }
        case .compoundAdoptionUndo(let undo):
            Section(st("Whole first-adoption inverse")) {
                Text(st("These source, line, relationship and pack assertions are reversed together."))
                ForEach(undo.reversedAssertions.lines, id: \.id) { Text($0.name) }
                ForEach(undo.reversedAssertions.contributions, id: \.id) { contribution($0) }
                ForEach(undo.reversedAssertions.edges, id: \.id) { edge in Text(SharedDemandCopy.quantity(edge.quantity)); Text(edge.confirmation.evidence) }
                ForEach(undo.reversedAssertions.packReviews, id: \.lineId) { Text(SharedDemandCopy.quantity($0.usablePerPack)) }
                ForEach(undo.touchedBasket, id: \.lineId) { line in
                    Text(line.lineId.string)
                    ForEach(line.fields, id: \.rawValue) { field in Text(fieldName(field)) }
                }
                if let meal = undo.mealUndo {
                    if let before = meal.current.meal { Text(st("Before")); SharedMealFacts(meal: before, deadlineIdentifier: "sharedTracking.compound.before.deadline") }
                    if let after = meal.restoredMeal { Text(st("After")); SharedMealFacts(meal: after, deadlineIdentifier: "sharedTracking.compound.after.deadline") }
                    else { Text(st("Meal removed")) }
                }
                Text(st("Transferred facts remain unbound and protected; later contribution identities are retained."))
            }
        case .rebind(let rebind):
            Section(st("Exact restored identities")) {
                Text(st("No earlier allocations are restored."))
                ForEach(rebind.restored, id: \.factId) { restored in
                    if let before = restored.before.transferred { Text(st("Before")); contribution(before) }
                    Text(st("After")); contribution(restored.after)
                }
            }
        case .recover(let recovery):
            Section(st("Surviving facts only")) {
                ForEach(recovery.survivingCatalog, id: \.id) { factFacts($0) }
                Text(st("Erased facts and old previews cannot be restored."))
            }
        }
    }
}
