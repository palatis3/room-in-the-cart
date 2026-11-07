import CoreDomain
import HouseholdClient
import SwiftUI

struct SharedRecoveryReview: View {
    @ObservedObject var model: HouseholdShopModel
    @ObservedObject var household: HouseholdModel
    let page: SharedRecoveryPage
    let fallback: SharedFallbackOptions.Option?
    let usualMinutes: Int?
    let finish: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @State private var preview: SharedRecoveryPreview
    @State private var intent: SharedRecoveryIntent
    @State private var repeatAgreement = false
    @State private var tripAgreement = false
    @State private var unresolvedAgreement = false
    @State private var checking = false
    @State private var invalid = false
    @State private var message: String?
    @State private var presentation = UUID()

    init(model: HouseholdShopModel, household: HouseholdModel, page: SharedRecoveryPage,
         initial: SharedRecoveryPreview, originalIntent: SharedRecoveryIntent, fallback: SharedFallbackOptions.Option? = nil,
         usualMinutes: Int? = nil, finish: @escaping (Bool) -> Void) {
        self.model = model; self.household = household; self.page = page
        self.fallback = fallback; self.usualMinutes = usualMinutes
        self.finish = finish
        _intent = State(initialValue: originalIntent); _preview = State(initialValue: initial)
    }

    private var allowed: Bool {
        showsReviewedRecovery(page, model: model, household: household) && model.shop?.phase == "placed" && !invalid
    }
    private var agreed: Bool {
        (!preview.repeatRequired || repeatAgreement) && (!intent.proposesExtraTrip || tripAgreement) &&
        (preview.feasible || unresolvedAgreement)
    }
    private var agreementsReviewed: Bool {
        preview.consentSatisfied && intent.agreesToRepeat == repeatAgreement &&
        intent.agreesToExtraTrip == tripAgreement && intent.acceptsUnresolved == unresolvedAgreement
    }

    var body: some View {
        Form {
            if allowed {
                Section {
                    Text(verbatim: intent.replacement.title).font(.headline)
                    LabeledContent(sharedRecoveryText("Food coverage"), value: preview.foodConfirmed ? sharedRecoveryText("Confirmed") : sharedRecoveryText("Still unresolved"))
                    LabeledContent(sharedRecoveryText("Meal timing"), value: preview.timingConfirmed ? sharedRecoveryText("Confirmed") : sharedRecoveryText("Unresolved"))
                    if let date = serviceDate(preview.asOf) { LabeledContent(ht("Checked at"), value: date.formatted()) }
                }
                ForEach(preview.after.meals) { meal in
                    Section {
                        if let before = preview.before.meals.first(where: { $0.id == meal.id }) {
                            DisclosureGroup(sharedRecoveryText("Before replacement")) {
                                mealFacts(before, projection: preview.before)
                            }.accessibilityIdentifier("recovery.before." + meal.id.uuidString)
                        }
                        mealFacts(meal, projection: preview.after)
                    } header: { Text(verbatim: (sharedMealDayText(meal.day, locale: .current) ?? meal.day) + " · " + meal.title) }
                    .accessibilityIdentifier("recovery.after." + meal.id.uuidString)
                }
                Section {
                    if let fallback { SharedFallbackOptionFacts(option: fallback, usualMinutes: usualMinutes) }
                    if preview.repeatRequired {
                        Toggle(isOn: $repeatAgreement) {
                            Text(verbatim: sharedRecoveryText("I agree to repeat this meal") + " · " + intent.replacement.title)
                        }.disabled(checking).accessibilityIdentifier("recovery.agreeRepeat")
                    }
                    if intent.proposesExtraTrip {
                        Toggle(sharedRecoveryText("I agree to another trip for this replacement"), isOn: $tripAgreement)
                            .disabled(checking).accessibilityIdentifier("recovery.agreeTrip")
                    }
                    if !preview.feasible {
                        Toggle(sharedRecoveryText("Save this meal with its unresolved needs or timing"), isOn: $unresolvedAgreement)
                            .disabled(checking).accessibilityIdentifier("recovery.agreeUnresolved")
                    }
                    if agreementsReviewed {
                        Button(sharedRecoveryText("Apply meal replacement")) { Task { await apply() } }
                            .disabled(!agreed || checking || model.pending != nil || model.busy)
                            .accessibilityIdentifier("recovery.apply")
                    } else {
                        Button(sharedRecoveryText("Review these agreements")) { Task { await recheck() } }
                            .disabled(!agreed || checking || model.pending != nil || model.busy)
                            .accessibilityIdentifier("recovery.reviewAgreements")
                    }
                    if !preview.feasible {
                        Button(sharedRecoveryText("Keep the current meal and leave its needs open")) {
                            guard allowed, scene == .active, !checking, model.pending == nil else { return }
                            presentation = UUID()
                            finish(false)
                        }
                        .disabled(checking || model.busy || model.pending != nil)
                        .accessibilityIdentifier("recovery.keepCurrent")
                    }
                    if checking { ProgressView() }
                }
            } else {
                Text(sharedRecoveryText("Refresh the current meal record."))
            }
            if model.pendingMealRecovery { Text(sharedRecoveryText("Pending meal replacement")) }
            if let message { Text(verbatim: message) }
            if let notice = model.notice { Text(verbatim: notice) }
        }
        .navigationTitle(sharedRecoveryText("Review meal replacement"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { presentation = UUID(); dismiss() }.disabled(checking) } }
        .interactiveDismissDisabled(checking)
        .onChange(of: scene) { _, current in if current != .active { presentation = UUID(); invalid = true } }
        .onChange(of: allowed) { _, active in if !active { presentation = UUID() } }
    }

    @ViewBuilder private func mealFacts(_ meal: SharedRecoveryMeal, projection: SharedRecoveryPreview.Projection) -> some View {
        Text(verbatim: meal.title).font(.headline)
        LabeledContent(sharedRecoveryText("Meal deadline"), value: meal.due.flatMap { SharedMealDeadline(at: $0, zone: meal.zone ?? "UTC").display(locale: .current) } ?? ht("Unknown"))
        LabeledContent(ht("Portions"), value: String(meal.portions))
        ForEach(meal.groups) { group in
            let amount = group.servings.denominator == 1 ? String(group.servings.numerator) : "\(group.servings.numerator)/\(group.servings.denominator)"
            LabeledContent(group.name, value: amount + (group.protected ? " · " + ht("Protected portions") : ""))
        }
        if !meal.exclusions.isEmpty { LabeledContent(ht("Meal exclusions"), value: meal.exclusions.joined(separator: ", ")) }
        if !meal.notes.isEmpty { Text(verbatim: meal.notes) }
        if let url = meal.sourceURL { Text(verbatim: url) }
        LabeledContent(sharedRecoveryText("Remaining preparation minutes"), value: meal.remainingElapsedMinutes.map(String.init) ?? ht("Unknown"))
        LabeledContent(sharedRecoveryText("Required lead time in minutes"), value: meal.requiredLeadMinutes.map(String.init) ?? ht("Unknown"))
        Text(meal.advanceStepsCompleted ? sharedRecoveryText("Advance steps confirmed complete") : sharedRecoveryText("Advance steps not confirmed complete"))
        ForEach(meal.needs) { need in
            if let demand = projection.demands.first(where: { $0.needId == need.id }) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: need.name + " · " + recoveryGroupNames(SharedRecoveryDraft.groups(need), meal: meal)).font(.headline)
                    if need.priority == "protected" { Text(ht("Protected portions")) }
                    if !need.exclusions.isEmpty { Text(verbatim: ht("Ingredient exclusions") + ": " + need.exclusions.joined(separator: ", ")) }
                    if !need.notes.isEmpty { Text(verbatim: need.notes) }
                    LabeledContent(ht("Ingredient quantity"), value: deliveryQuantityText(need.quantity))
                    LabeledContent(sharedRecoveryText("Allocated"), value: quantity(demand.allocated, unit: demand.unit))
                    LabeledContent(sharedRecoveryText("Still needed"), value: quantity(demand.shortfall, unit: demand.unit))
                    ForEach(demand.reservations, id: \.reservationId) { claim in
                        Text(verbatim: sourceName(claim.sourceId))
                        LabeledContent(ht("Amount set aside"), value: quantity(claim.requested, unit: demand.unit))
                        LabeledContent(sharedRecoveryText("Still backed"), value: quantity(claim.backed, unit: demand.unit))
                    }
                    ForEach(projection.allocations.filter { $0.needId == need.id }, id: \.sourceId) { allocation in
                        LabeledContent(sourceName(allocation.sourceId), value: quantity(allocation.amount, unit: allocation.unit))
                    }
                    ForEach(demand.issues, id: \.self) { issue in Text(recoveryIssue(issue)).font(.footnote) }
                    ForEach(demand.sourceIssues, id: \.sourceId) { issue in
                        Text(verbatim: sourceName(issue.sourceId) + " · " + recoveryIssue(issue.issue)).font(.footnote)
                    }
                }.padding(.vertical, 3)
            }
        }
        if meal.needs.isEmpty { Text(ht("This meal has no recorded ingredient requirements.")) }
    }

    private func sourceName(_ id: UUID) -> String {
        page.sourceOptions.first { $0.id == id }.map { $0.name + " · " + recoverySourceKind($0.kind) } ?? ht("Unknown")
    }

    private func quantity(_ amount: SharedDeliveryCoverage.Fraction?, unit: String?) -> String {
        guard let amount, let unit = unit.flatMap(UnitOfMeasure.init(rawValue:)) else { return ht("Unknown") }
        return pQuantity(amount.formatted, unit: unit, singular: amount.numerator == amount.denominator, language: nil)
    }

    private func recheck() async {
        guard allowed, scene == .active, agreed, !checking, model.pending == nil else { return }
        checking = true
        defer { checking = false }
        let review = presentation
        let candidate = intent.withFallbackAgreements(repeatMeal: repeatAgreement, extraTrip: tripAgreement, unresolved: unresolvedAgreement)
        do {
            let checked = try await model.previewMealRecovery(candidate, reviewed: page)
            guard review == presentation, allowed, scene == .active else { return }
            guard checked.before == preview.before && checked.after == preview.after && checked.base == preview.base &&
                  checked.timingConfirmed == preview.timingConfirmed && checked.foodConfirmed == preview.foodConfirmed &&
                  checked.feasible == preview.feasible && checked.repeatRequired == preview.repeatRequired else {
                invalid = true
                return
            }
            intent = candidate
            preview = checked
            message = nil
        } catch { message = model.notice ?? sharedRecoveryText("Reconnect and preview the current meal again.") }
    }

    private func apply() async {
        guard allowed, agreed, agreementsReviewed, scene == .active, !checking, model.pending == nil else { return }
        guard let expiry = serviceDate(preview.expiresAt), Date() < expiry else { invalid = true; return }
        checking = true
        defer { checking = false }
        if await model.applyMealRecovery(preview, intent: intent, reviewed: page) {
            finish(true)
        } else { message = model.notice ?? sharedRecoveryText("Check the current record before trying again.") }
    }
}

func recoveryIssue(_ key: String) -> String {
    switch key {
    case "unknown_food": sharedRecoveryText("No reviewed food match")
    case "unknown_split": sharedRecoveryText("Amounts for each group are unresolved")
    case "unknown_quantity": sharedRecoveryText("Required amount unknown")
    case "unconfirmed_stock", "reservation_unavailable": sharedRecoveryText("Usable stock unconfirmed")
    case "unit_mismatch": sharedRecoveryText("Incompatible unit")
    case "exclusion_conflict": sharedRecoveryText("Conflicts with a recorded exclusion")
    case "reservation_shortfall": sharedRecoveryText("The full amount set aside is no longer backed")
    case "protected_quantity_unknown": sharedRecoveryText("Held for a protected portion of unknown size")
    case "foreign_hold_unknown": sharedRecoveryText("Other commitments are unquantified")
    default: sharedRecoveryText("Review the current need")
    }
}
