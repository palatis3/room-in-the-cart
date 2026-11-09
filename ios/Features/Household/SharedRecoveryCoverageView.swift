import HouseholdClient
import SwiftUI

struct SharedRecoveryCoverageView: View {
    @ObservedObject var model: HouseholdShopModel
    @ObservedObject var household: HouseholdModel
    let delivery: SharedDeliveryPage
    @State private var snapshot: Snapshot?
    @State private var failed = false
    @Environment(\.locale) private var locale
    private struct Snapshot {
        let record: SharedRecoveryPage
        let coverage: SharedRecoveryCoverage
    }

    private var allowed: Bool {
        !household.locked && household.sharedShop === model && model.canReadMealRecovery && model.deliveryRecord == delivery &&
            model.scope.shopId.flatMap(UUID.init(uuidString:)) == delivery.shopId
    }

    var body: some View {
        List {
            if allowed, let snapshot, showsReviewedRecovery(snapshot.record, model: model, household: household) {
                if let when = serviceDate(snapshot.coverage.asOf) { LabeledContent(ht("Checked at"), value: when.formatted()) }
                ForEach(snapshot.record.meals) { meal in
                    Section {
                        if snapshot.coverage.unplannedOccurrenceIds.contains(meal.id) {
                            Text(ht("This meal has no recorded ingredient requirements."))
                        }
                        if let renderer = SharedDeliveryCookDraft(language: locale.language.languageCode?.identifier == "es" ? "es-US" : "en-US") {
                            ForEach(snapshot.coverage.needs.filter { $0.occurrenceId == meal.id }, id: \.needId) { need in
                                VStack(alignment: .leading, spacing: 5) {
                                    let lines = renderer.recoveryNeed(need, meal: meal, record: snapshot.record)
                                    if let first = lines.first { Text(verbatim: first).font(.headline) }
                                    ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in Text(verbatim: line) }
                                }.accessibilityIdentifier("recovery.currentNeed." + need.needId.uuidString)
                            }
                        }
                        if let sealed = delivery.meals?.first(where: { $0.id == meal.id && $0.revision == meal.sourceMealRevision }) {
                            NavigationLink(pTr("Preview a dated cook instruction")) {
                                SharedDeliveryCookView(model: model, household: household, page: delivery,
                                    coverage: .recovered(snapshot.record, snapshot.coverage, meal), occurrence: sealed)
                            }.accessibilityIdentifier("recovery.cook." + meal.id.uuidString)
                        }
                    } header: { Text(verbatim: meal.title + " · " + (sharedMealScheduleText(meal.day, locale: locale))) }
                }
            } else if failed || !allowed || snapshot != nil {
                Text(sharedRecoveryText("Refresh the current meal record."))
            } else { ProgressView() }
            if allowed {
                Button(ht("Refresh")) { Task { await load() } }.disabled(model.busy)
            }
        }
        .navigationTitle(sharedRecoveryText("Current food by meal"))
        .task { await load() }
    }

    private func load() async {
        guard allowed else { return }
        failed = false
        snapshot = nil
        await model.loadMealRecovery()
        guard !Task.isCancelled else { return }
        guard allowed, let record = model.recoveryRecord, record.shopId == delivery.shopId,
              record.placedRevision == delivery.placedRevision, record.base.recoveryRevision == delivery.recoveryRevision,
              record.base.shopRevision == delivery.shopRevision, record.base.authorityEpoch == delivery.authorityEpoch,
              record.base.supplyRevision == delivery.supplyRevision else { failed = true; return }
        do {
            let coverage = try await model.effectiveCoverage(reviewed: record)
            guard !Task.isCancelled, allowed, model.recoveryRecord == record else { return }
            snapshot = .init(record: record, coverage: coverage)
        } catch { if !Task.isCancelled { failed = true } }
    }
}
