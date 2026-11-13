import HouseholdClient
import SwiftUI

/// Reads both seals together. The delivery-only report remains available independently.
struct SharedFoodCoverageView: View {
    @ObservedObject var model: HouseholdShopModel
    @ObservedObject var household: HouseholdModel
    let page: SharedDeliveryPage
    @Environment(\.locale) private var locale
    @State private var result: Snapshot?
    @State private var failed = false
    @State private var refresh = 0

    private struct Snapshot {
        let pantry: SharedPantryPage
        let coverage: SharedFoodCoverage
    }

    private var allowed: Bool {
        !household.locked && household.sharedShop === model && model.canReadPantry &&
        model.scope.shopId.flatMap(UUID.init(uuidString:)) == page.shopId && model.shop?.shopId == model.scope.shopId &&
        model.deliveryRecord == page && model.shop?.authorityEpoch == page.authorityEpoch &&
        model.shop?.shopRevision == page.shopRevision
    }

    var body: some View {
        List {
            if allowed, let result, result.pantry == model.pantryRecord {
                report(result)
            } else if !allowed || failed || result != nil {
                Text(cookLabel("Review the current pantry and delivery records."))
                if allowed {
                    Button(cookLabel("Refresh food coverage")) { refresh += 1 }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(cookLabel("Food coverage by meal"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: refresh) { await load() }
        .onChange(of: allowed) { _, current in if !current { result = nil } }
    }

    @ViewBuilder private func report(_ snapshot: Snapshot) -> some View {
        let coverage = snapshot.coverage
        Section {
            if let checked = serviceDate(coverage.asOf) {
                LabeledContent(ht("Checked at"), value: checked.formatted())
            }
            Button(cookLabel("Refresh food coverage")) { refresh += 1 }
        } footer: {
            Text(cookLabel(SharedDeliveryCookDraft.foodScope))
        }
        let language = locale.language.languageCode?.identifier == "es" ? "es-US" : "en-US"
        if let renderer = SharedDeliveryCookDraft(language: language) {
            ForEach(page.meals ?? []) { occurrence in
                Section {
                    if let plan = occurrence.meal.planning { SharedMealPreparationFacts(planning: plan) }
                    if coverage.unplannedOccurrenceIds.contains(occurrence.id) {
                        Text(ht("This meal has no recorded ingredient requirements."))
                    }
                    let needs = coverage.needs.filter { $0.occurrenceId == occurrence.id }
                    ForEach(Array(needs.enumerated()), id: \.offset) { index, need in
                        let facts = renderer.foodNeed(need, occurrence: occurrence, page: page, pantry: snapshot.pantry)
                        VStack(alignment: .leading, spacing: 6) {
                            if let first = facts.first { Text(verbatim: first).font(.headline) }
                            ForEach(Array(facts.dropFirst().enumerated()), id: \.offset) { _, line in Text(verbatim: line) }
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("pantry.coverage.need." + occurrence.id.uuidString + "." + String(index))
                    }
                    NavigationLink(pTr("Preview a dated cook instruction")) {
                        SharedDeliveryCookView(model: model, household: household, page: page, coverage: .food(snapshot.pantry, coverage), occurrence: occurrence)
                    }
                    .accessibilityIdentifier("pantry.coverage.cook." + occurrence.id.uuidString)
                } header: {
                    Text(verbatim: occurrence.meal.title + " · " + (sharedMealScheduleText(occurrence.meal.day, locale: locale)))
                }
            }
        }
    }

    private func load() async {
        result = nil
        failed = false
        guard allowed else { return }
        await model.loadPantry(reviewed: page)
        guard !Task.isCancelled else { return }
        guard allowed, let pantry = model.pantryRecord else { failed = true; return }
        do {
            let coverage = try await model.foodCoverage(reviewed: pantry, delivery: page)
            guard !Task.isCancelled else { return }
            guard allowed, model.pantryRecord == pantry else { failed = true; return }
            result = Snapshot(pantry: pantry, coverage: coverage)
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }

    private func cookLabel(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), table: "DeliveryCook")
    }
}
