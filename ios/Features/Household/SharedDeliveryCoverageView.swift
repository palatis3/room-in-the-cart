import CoreDomain
import HouseholdClient
import SwiftUI

struct SharedDeliveryCoverageView: View {
    @ObservedObject var model: HouseholdShopModel
    let page: SharedDeliveryPage
    @Environment(\.dismiss) private var dismiss
    @State private var result: SharedDeliveryCoverage?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                if let result, result.supplyRevision == page.supplyRevision, result.authorityEpoch == page.authorityEpoch, result.shopRevision == page.shopRevision {
                    Section {
                        if let date = serviceDate(result.asOf) {
                            LabeledContent(ht("Checked at"), value: date.formatted())
                        }
                    } footer: {
                        Text(ht("These counts use confirmed deliveries for this order. Protected portions are counted first."))
                    }
                    ForEach(page.meals ?? []) { occurrence in
                        Section {
                            if let planning = occurrence.meal.planning { SharedMealPreparationFacts(planning: planning) }
                            if result.unplannedOccurrenceIds.contains(occurrence.id) {
                                Text(ht("This meal has no recorded ingredient requirements."))
                            }
                            ForEach(Array(result.needs.filter { $0.occurrenceId == occurrence.id }.enumerated()), id: \.offset) { _, need in
                                requirement(need, occurrence: occurrence)
                            }
                        } header: { Text(occurrence.meal.title + " · " + occurrence.meal.day) }
                    }
                } else if failed {
                    Text(ht("Refresh deliveries and review the current record."))
                    Button(ht("Refresh deliveries")) {
                        Task {
                            await model.load()
                            await model.loadDelivery()
                            if model.deliveryRecord == page { await load(page) }
                        }
                    }
                } else { ProgressView() }
            }
            .navigationTitle(ht("Delivered food by meal"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ht("Done")) { dismiss() } } }
            .task(id: page) { await load(page) }
        }
    }

    private func load(_ reviewed: SharedDeliveryPage) async {
        do {
            let updated = try await model.coverage(reviewed: reviewed)
            guard !Task.isCancelled else { return }
            result = updated; failed = false
        } catch {
            guard !Task.isCancelled else { return }
            result = nil; failed = true
        }
    }

    @ViewBuilder private func requirement(_ need: SharedDeliveryCoverage.Need, occurrence: SharedMealOccurrence) -> some View {
        if let plan = occurrence.meal.planning, let ingredient = plan.ingredients.first(where: { $0.id == need.ingredientId }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(ingredient.name).font(.headline)
                let ingredientRules = ingredient.exclusions.filter { !(plan.exclusions ?? []).contains($0) }
                if !ingredientRules.isEmpty {
                    LabeledContent(ht("Ingredient exclusions"), value: ingredientRules.joined(separator: ", "))
                }
                if need.protected { Label(ht("Protected portions"), systemImage: "lock") }
                let groups = plan.groups.filter { need.groupIds.contains($0.id) }.map(\.name)
                if !groups.isEmpty { Text(groups.joined(separator: ", ")) }
                LabeledContent(ht("Ingredient quantity"), value: deliveryQuantityText(need.required))
                if let unit = need.required.flatMap({ UnitOfMeasure(rawValue: $0.unit) }), let covered = need.covered, let missing = need.missing {
                    LabeledContent(ht("Covered by deliveries"), value: quantity(covered, unit: unit))
                    LabeledContent(ht("Uncovered by deliveries"), value: quantity(missing, unit: unit))
                    ForEach(need.reservations ?? [], id: \.reservationId) { reservation in
                        if let source = page.sources.first(where: { $0.id == reservation.sourceId }) {
                            VStack(alignment: .leading) {
                                Text(source.foodName + " · " + source.segmentKey.uuidString.prefix(8)).font(.subheadline)
                                LabeledContent(ht("Amount set aside"), value: quantity(reservation.requested, unit: unit))
                                LabeledContent(ht("Still backed by this delivery"), value: quantity(reservation.backed, unit: unit))
                            }
                        }
                    }
                    ForEach(need.allocations, id: \.sourceId) { allocation in
                        if let source = page.sources.first(where: { $0.id == allocation.sourceId }) {
                            LabeledContent(source.foodName + " · " + source.segmentKey.uuidString.prefix(8), value: quantity(allocation.amount, unit: unit))
                        }
                    }
                }
                ForEach(need.issues, id: \.self) { code in Text(explanation(code)).font(.footnote) }
            }
            .padding(.vertical, 4)
        }
    }

    private func quantity(_ fraction: SharedDeliveryCoverage.Fraction, unit: UnitOfMeasure) -> String {
        let single = fraction.numerator == "1" && fraction.denominator == "1"
        let label = unit == .count && !single ? dinnerText("units") : dinnerUnit(unit, singular: single)
        return fraction.formatted + " " + label
    }

    private func explanation(_ code: String) -> String {
        switch code {
        case "unknownQuantity": return ht("The required amount is unknown.")
        case "unknownSplit": return ht("The total is shared. Amounts for each group are unresolved.")
        case "noMatch": return ht("No delivery has been matched to this ingredient.")
        case "unconfirmed": return ht("A matched delivery is waiting for a usable count.")
        case "exclusion": return ht("A matched delivery conflicts with a recorded exclusion.")
        case "unitMismatch": return ht("A matched delivery uses an incompatible unit.")
        case "reservationShortfall": return ht("This delivery no longer covers the full amount set aside.")
        case "protectedQuantityUnknown": return ht("Matched food is held for a protected group whose quantity is unknown.")
        default: return ht("Refresh deliveries and review the current record.")
        }
    }
}
