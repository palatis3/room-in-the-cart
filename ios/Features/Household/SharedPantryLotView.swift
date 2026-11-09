import CoreDomain
import HouseholdClient
import SwiftUI

/// Keep the household, placed order and physical stock on the same reviewed versions.
struct PantryLotReview {
    let delivery: SharedDeliveryPage
    let pantry: SharedPantryPage
    let lot: SharedPantryPage.Lot

    @MainActor init?(model: HouseholdShopModel, shopID: UUID, lotID: UUID) {
        guard model.canReadPantry, let delivery = model.deliveryRecord, let pantry = model.pantryRecord,
              delivery.shopId == shopID, pantry.shopId == shopID, pantry.shopRevision == delivery.shopRevision,
              pantry.placedRevision == delivery.placedRevision, pantry.authorityEpoch == delivery.authorityEpoch,
              pantry.supplyRevision == delivery.supplyRevision, let lot = pantry.lots.first(where: { $0.id == lotID }) else { return nil }
        self.delivery = delivery
        self.pantry = pantry
        self.lot = lot
    }
}

struct SharedPantryLotView: View {
    @ObservedObject var model: HouseholdShopModel
    let shopID: UUID
    let lotID: UUID
    @State private var observing = false
    @State private var error: String?

    private var record: PantryLotReview? { PantryLotReview(model: model, shopID: shopID, lotID: lotID) }

    var body: some View {
        Form {
            if let record {
                let lot = record.lot
                Section {
                    LabeledContent(ht("Storage location"), value: pantryLocation(lot.location))
                    LabeledContent(ht("Batch reference"), value: String(lotID.uuidString.suffix(8)))
                    LabeledContent(ht("Confirmed usable quantity"), value: deliveryQuantityText(lot.observation?.quantity))
                    if let date = lot.observation.flatMap({ serviceDate($0.confirmedAt) }) {
                        LabeledContent(ht("Confirmed at"), value: date.formatted())
                    }
                    if let date = lot.storedAt.flatMap(serviceDate) {
                        LabeledContent(ht("Stored at"), value: date.formatted())
                    }
                    if let date = lot.useFirstAt.flatMap(serviceDate) {
                        LabeledContent(ht("Use first by"), value: date.formatted())
                    }
                    if !lot.exclusionTags.isEmpty {
                        LabeledContent(ht("Food exclusions"), value: lot.exclusionTags.joined(separator: ", "))
                    }
                }
                if model.shop?.phase == "placed" && model.pending == nil {
                    if lot.origin == "manual" {
                        Button(ht("Review usable stock")) { observing = true }
                            .accessibilityIdentifier("pantry.observe")
                    } else {
                        Text(ht("This batch follows its original delivery. Correct its usable quantity in What came home for that order."))
                    }
                    Section {
                        Button(lot.selected ? ht("Remove from this shop") : ht("Use this batch for this shop")) {
                            Task {
                                let saved = await model.savePantry(.select(lot: lotID, selected: !lot.selected),
                                                                   reviewed: record.pantry, delivery: record.delivery)
                                error = saved ? nil : model.notice ?? ht("Refresh deliveries and review the current record.")
                            }
                        }
                        .disabled(model.busy || (lot.selected && !lot.matches.isEmpty))
                        .accessibilityIdentifier("pantry.select")
                        if lot.selected {
                            NavigationLink(ht("Meal ingredient matches")) {
                                SharedPantryMatches(model: model, shopID: shopID, lotID: lotID)
                            }
                            .accessibilityIdentifier("pantry.matches")
                        }
                    } footer: {
                        if lot.selected && !lot.matches.isEmpty {
                            Text(ht("Release reservations and remove this shop’s ingredient matches before removing the batch."))
                        }
                    }
                }
                if let error { Text(error) }
            } else { Text(ht("Refresh deliveries and review the current record.")) }
        }
        .navigationTitle(record?.lot.foodName ?? ht("Pantry and freezer"))
        .sheet(isPresented: $observing) {
            if let record { SharedPantryObservationView(model: model, record: record) }
        }
    }
}

private struct SharedPantryObservationView: View {
    @ObservedObject var model: HouseholdShopModel
    @State private var record: PantryLotReview
    @Environment(\.dismiss) private var dismiss
    @State private var literal = ""
    @State private var unit = UnitOfMeasure.count
    @State private var checked: Checked?
    @State private var previewing = false
    @State private var error: String?
    @FocusState private var editing: Bool

    private struct Checked {
        let edit: SharedPantryEdit
        let preview: SharedPantryObservationPreview
        let quantity: SharedMealQuantity?
    }

    init(model: HouseholdShopModel, record: PantryLotReview) {
        self.model = model
        _record = State(initialValue: record)
        if let q = record.lot.observation?.quantity, let oldUnit = UnitOfMeasure(rawValue: q.unit),
           let amount = try? Rational(Int64(q.amount.numerator), Int64(q.amount.denominator)) {
            _literal = State(initialValue: amount.description)
            _unit = State(initialValue: oldUnit)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(record.lot.foodName) {
                    LabeledContent(ht("Storage location"), value: pantryLocation(record.lot.location))
                    LabeledContent(ht("Previously confirmed"), value: deliveryQuantityText(record.lot.observation?.quantity))
                }
                if let checked {
                    LabeledContent(ht("New usable quantity"), value: deliveryQuantityText(checked.quantity))
                    Section(ht("Effect on linked meals")) {
                        ForEach(Array(checked.preview.needs.enumerated()), id: \.offset) { _, row in
                            if let meal = record.delivery.meals?.first(where: { $0.id == row.occurrenceId && $0.revision == row.mealRevision }),
                               let plan = meal.meal.planning, let ingredient = plan.ingredients.first(where: { $0.id == row.ingredientId }) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(meal.meal.title + " · " + sharedMealScheduleText(meal.meal.day)).font(.headline)
                                    Text(ingredient.name)
                                    Text(plan.groups.filter { row.groupIds.contains($0.id) }.map(\.name).joined(separator: ", "))
                                    impact(ht("Covered before"), row.beforeCovered, row.required)
                                    impact(ht("Covered after"), row.afterCovered, row.required)
                                    impact(ht("Missing before"), row.beforeMissing, row.required)
                                    impact(ht("Missing after"), row.afterMissing, row.required)
                                    ForEach(row.afterReservations, id: \.reservationId) { promise in
                                        if let before = row.beforeReservations.first(where: { $0.reservationId == promise.reservationId }) {
                                            let source = record.pantry.lots.first(where: { $0.id == promise.sourceId })?.foodName
                                                ?? record.delivery.sources.first(where: { $0.id == promise.sourceId })?.foodName
                                            if let source { Text(source).font(.subheadline.bold()) }
                                            impact(ht("Reserved quantity"), promise.requested, row.required)
                                            impact(ht("Available for this reservation before"), before.backed, row.required)
                                            impact(ht("Available for this reservation after"), promise.backed, row.required)
                                        }
                                    }
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("pantry.impact." + ([row.occurrenceId, row.ingredientId] + row.groupIds).map(\.uuidString).joined(separator: "."))
                            }
                        }
                        if checked.preview.needs.isEmpty { Text(ht("This batch has no linked needs in this shop.")) }
                        if checked.preview.otherShopsAffected {
                            Text(ht("This change also affects food committed to another shop."))
                        } else if checked.preview.otherShopsCommitted {
                            Text(ht("Another shop uses this batch. Its covered quantities stay the same."))
                        }
                    }
                    Button(ht("Edit quantity")) { self.checked = nil; error = nil }
                        .disabled(model.busy)
                } else {
                    Section {
                        TextField(ht("New usable quantity"), text: $literal).focused($editing)
                            .accessibilityIdentifier("pantry.amount")
                        Picker(ht("Unit"), selection: $unit) {
                            ForEach(UnitOfMeasure.allCases, id: \.self) { Text(dinnerUnit($0)).tag($0) }
                        }
                    } footer: { Text(ht("Leave the quantity blank if it is unknown. Enter 0 for a confirmed zero.")) }
                }
                if let error { Text(error) }
            }
            .navigationTitle(ht("Review usable stock"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    if let checked {
                        Button(ht("Confirm")) { Task { await confirm(checked) } }
                            .disabled(model.busy).accessibilityIdentifier("pantry.confirmObservation")
                    } else {
                        Button(ht("Preview")) { editing = false; Task { await preview() } }
                            .disabled(model.busy || previewing).accessibilityIdentifier("pantry.preview")
                    }
                }
            }
            .interactiveDismissDisabled(model.busy)
        }
    }

    private func impact(_ label: String, _ fraction: SharedDeliveryCoverage.Fraction?, _ requirement: SharedMealQuantity?) -> some View {
        let u = requirement.flatMap { UnitOfMeasure(rawValue: $0.unit) }
        let amount = fraction.flatMap { f in u.map { pQuantity(f.formatted, unit: $0, singular: f.numerator == f.denominator, language: nil) } }
        return LabeledContent(label, value: amount ?? ht("Unknown"))
    }

    private func preview() async {
        guard !previewing else { return }
        previewing = true
        defer { previewing = false }
        let currentLiteral = literal, currentUnit = unit
        do {
            let value = try DinnerEntry.quantity(literal, unit: unit).map {
                SharedMealQuantity(amount: .init(numerator: Int($0.amount.numerator), denominator: Int($0.amount.denominator)),
                                   unit: unit.rawValue, originalLiteral: $0.originalLiteral)
            }
            let edit = SharedPantryEdit.observe(lot: record.lot.id, previous: record.lot.observation?.observationId,
                                                confirmedAt: Date(), quantity: value)
            _ = try edit.body(reviewed: record.pantry, delivery: record.delivery)
            let proposed = try await model.previewPantryObservation(edit, reviewed: record.pantry, delivery: record.delivery)
            guard literal == currentLiteral, unit == currentUnit else { return }
            checked = .init(edit: edit, preview: proposed, quantity: value)
            error = nil
        } catch {
            self.error = ht("Check the quantity and refresh the batch before reviewing again.")
        }
    }

    private func confirm(_ checked: Checked) async {
        if await model.savePantry(checked.edit, reviewed: record.pantry, delivery: record.delivery, preview: checked.preview) {
            dismiss()
        } else {
            error = model.notice ?? ht("Refresh deliveries and review the current record.")
        }
    }
}
