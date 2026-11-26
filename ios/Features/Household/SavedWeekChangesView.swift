import SwiftUI
import HouseholdClient
import CoreDomain

func savedWeekText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "SavedWeekChanges")
}

struct SavedWeekEntry: View {
    @ObservedObject var household: HouseholdModel
    let scope: SharedMealChangeScope
    let start: Date
    private enum Lookup { case checking, available, retry, hidden }
    @State private var lookup: Lookup = .checking

    var body: some View {
        if household.sharedMealChangeScope == scope {
            switch lookup {
            case .checking:
                ProgressView().accessibilityHidden(true).task { await checkAccess() }
            case .available:
                NavigationLink(savedWeekText("Change saved nights")) {
                    SavedWeekChangesView(household: household, scope: scope, start: start)
                }.accessibilityIdentifier("savedWeek.open")
            case .retry:
                Button(savedWeekText("Retry connection")) { lookup = .checking }
                    .accessibilityIdentifier("savedWeek.retryConnection")
            case .hidden:
                EmptyView()
            }
        }
    }

    @MainActor private func checkAccess() async {
        guard !Task.isCancelled, household.sharedMealChangeScope == scope else { return }
        guard let service = household.service else { lookup = .hidden; return }
        let result: Lookup
        do {
            _ = try await service.savedWeekProgress(shop: scope.shopID, week: sharedMealDay(start))
            result = .available
        } catch ClientError.transport {
            result = .retry
        } catch ClientError.service(let status, let code, _, let retryAfter)
            where (code == "rate_limited" && status == 429) ||
                  (code == "service_unavailable" && [408, 502, 503, 504].contains(status)) {
            if let retryAfter, retryAfter > 0 {
                // Respect the server's delay. Only a button tap starts another lookup.
                do { try await Task.sleep(for: .seconds(retryAfter)) } catch { return }
            }
            result = .retry
        } catch {
            result = .hidden
        }
        guard !Task.isCancelled, household.sharedMealChangeScope == scope else { return }
        lookup = result
    }
}

struct SavedWeekChangesView: View {
    @ObservedObject var household: HouseholdModel
    let scope: SharedMealChangeScope
    let start: Date
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scene
    @State private var plan: SharedMealPlan?
    @State private var selected = Set<UUID>()
    @State private var reviewed: SavedWeekReview?
    @State private var series: SavedWeekProgress?
    @State private var planID = UUID()
    @State private var working = false
    @State private var recoveryMessage: String?
    @State private var generation = UUID()
    private var active: Bool { household.sharedMealChangeScope == scope && scene == .active }
    private var week: String { sharedMealDay(start) }

    var body: some View {
        WorkingForm {
            if active {
                if let menu = self.plan {
                    if let progress = self.series {
                        Section(savedWeekText("Saved progress")) {
                            ForEach(Array(progress.steps.enumerated()), id: \.element.id) { index, step in
                                LabeledContent(sharedMealScheduleText(step.day, locale: locale),
                                    value: index < progress.completed ? savedWeekText("Saved") : savedWeekText("Pending"))
                            }
                            if progress.completed == progress.steps.count { Text(savedWeekText("All selected nights were saved.")) }
                            if progress.stopped { Text(savedWeekText("Stopped. Completed changes stay in the shared shop.")) }
                            if progress.conflicted { Text(savedWeekText("The shop changed. Stop the remaining changes and review the current week.")) }
                        }.accessibilityIdentifier("savedWeek.status")
                        if menu.shopper && progress.next != nil {
                            if !progress.conflicted {
                                Button(savedWeekText("Resume pending nights")) { run(.resume) }.accessibilityIdentifier("savedWeek.resume")
                            }
                            Button(savedWeekText("Stop remaining changes"), role: .destructive) { run(.stop) }
                        }
                    }
                    if self.series?.next == nil { selection(menu) }
                }
                if let message = recoveryMessage { Text(verbatim: message).accessibilityIdentifier("savedWeek.error") }
                Button(savedWeekText("Refresh week")) { run(.load) }.accessibilityIdentifier("savedWeek.reload")
            } else { Text(ht("Planning access changed or expired. Reconnect and review again.")) }
        }
        .disabled(working)
        .navigationTitle(savedWeekText("Change saved nights"))
        .task(id: active) {
            clear()
            if active { await perform(.load) }
        }
        .onDisappear { clear() }
    }

    @ViewBuilder private func selection(_ plan: SharedMealPlan) -> some View {
        let nights = sharedWeekMeals(plan.meals, starting: start)
        if let preview = self.reviewed {
            Section(savedWeekText("Remove these dinners")) {
                ForEach(preview.steps) { step in
                    if let meal = nights.first(where: { $0.id == step.id }) {
                        SharedMealFacts(meal: meal.meal)
                    }
                }
            }
            Section(savedWeekText("Dinners and lunches kept")) {
                ForEach(nights.filter { !selected.contains($0.id) }) { row in SharedMealFacts(meal: row.meal) }
            }
            if preview.shopper {
                Section(savedWeekText("Basket packs before and after")) {
                    if preview.basket.isEmpty { Text(savedWeekText("No packs in this basket.")) }
                    ForEach(preview.basket) { row in
                        VStack(alignment: .leading) {
                            LabeledContent(row.name, value: "\(row.before.formatted()) → \(row.after.formatted())")
                            if let before = row.beforeNeed {
                                let after = row.afterNeed.map { amountText($0) } ?? (row.after == 0 ? "0" : ht("Unknown"))
                                LabeledContent(savedWeekText("Food needed"), value: amountText(before) + " → " + after)
                            }
                            if row.unlinked { Text(savedWeekText("Entered packs kept. No reviewed dinner link.")) }
                            if row.manual { Text(savedWeekText("Includes an independent grocery item.")) }
                            if row.held { Text(savedWeekText("Includes a protected reservation.")) }
                            ForEach(row.mealIds, id: \.self) { id in
                                if let meal = plan.meals.first(where: { $0.id == id }) {
                                    Text(verbatim: meal.meal.title + " · " + sharedMealScheduleText(meal.meal.day, locale: locale))
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("savedWeek.basket." + row.id.uuidString.lowercased())
                    }
                }
                Button(savedWeekText("Confirm these changes")) { run(.confirm) }.accessibilityIdentifier("savedWeek.confirm")
            } else { Text(savedWeekText("The assigned shopper reviews the basket and confirms changes.")) }
            Button(savedWeekText("Back to selection")) { self.reviewed = nil }
        } else {
            Section(savedWeekText("Choose dinners to remove")) {
                ForEach(nights.filter { $0.meal.kind == "dinner" }) { night in
                    let held = night.meal.protected || night.meal.planning?.groups.contains(where: \.protected) == true
                    Toggle(isOn: Binding(get: { selected.contains(night.id) }, set: { on in
                        if on { selected.insert(night.id) } else { selected.remove(night.id) }
                    })) {
                        VStack(alignment: .leading) {
                            Text(verbatim: night.meal.title)
                            Text(verbatim: sharedMealScheduleText(night.meal.day, locale: locale))
                            if held { Text(savedWeekText("Protected portions")).font(.caption) }
                        }
                    }.disabled(held || (!selected.contains(night.id) && selected.count == 7))
                        .accessibilityIdentifier("savedWeek.select." + night.id.uuidString.lowercased())
                }
                Button(savedWeekText("Review grocery changes")) { run(.preview) }
                    .disabled(selected.isEmpty).accessibilityIdentifier("savedWeek.preview")
            }
        }
    }

    private func amountText(_ amount: SavedWeekReview.BasketRow.Amount) -> String {
        guard let n = Int64(amount.numerator), let d = Int64(amount.denominator),
              let value = try? Rational(n, d), let unit = UnitOfMeasure(rawValue: amount.unit) else { return ht("Unknown") }
        return pQuantity(value, unit: unit)
    }

    private enum Action { case load, preview, confirm, resume, stop }
    private func run(_ action: Action) { Task { await perform(action) } }
    @MainActor private func clear() {
        generation = UUID(); plan = nil; series = nil; reviewed = nil; selected = []; recoveryMessage = nil; working = false
    }
    @MainActor private func perform(_ action: Action) async {
        guard active, !working, let service = household.service else { return }
        let token = generation
        func current() -> Bool { active && token == generation && !Task.isCancelled }
        working = true; recoveryMessage = nil
        defer { if current() { working = false } }
        do {
            switch action {
            case .load:
                plan = nil; reviewed = nil; series = nil; selected = []
                let fresh = try await service.mealPlan(shopID: scope.shopID, currentWeek: true)
                guard current(), fresh.shopId == scope.shopID, fresh.phase == "draft" else { throw ClientError.configuration }
                let progress = try await service.savedWeekProgress(shop: scope.shopID, week: week)
                guard current() else { return }
                plan = fresh; series = progress; planID = UUID()
            case .preview:
                guard let menu = self.plan else { return }
                let review = try await service.reviewSavedWeek(menu, week: week, nights: selected)
                guard current() else { return }
                reviewed = review; planID = UUID()
            case .stop:
                guard let progress = self.series else { return }
                let stopped = try await service.advanceSavedWeek(shop: scope.shopID, series: progress, stop: true)
                guard current() else { return }
                self.series = stopped
                try await refreshMenu(service, current: current)
            case .confirm, .resume:
                var progress: SavedWeekProgress
                if action == .confirm, let menu = self.plan, let preview = self.reviewed {
                    progress = try await service.confirmSavedWeek(id: planID, plan: menu, week: week, review: preview)
                } else if action == .resume, let saved = self.series { progress = saved }
                else { return }
                guard current() else { return }
                series = progress; reviewed = nil; selected = []
                while current(), progress.next != nil, !progress.conflicted {
                    progress = try await service.advanceSavedWeek(shop: scope.shopID, series: progress)
                    guard current() else { return }
                    series = progress
                }
                try await refreshMenu(service, current: current)
            }
        } catch {
            guard current() else { return }
            // Clear any cached budget-free meal/basket details after a failed grant check.
            plan = nil; reviewed = nil; series = nil; selected = []
            recoveryMessage = savedWeekText("Refresh to check your access, saved progress and current food sources.")
            if case ClientError.service(_, let code, _, _) = error {
                if ["review_week_sources", "tracking_v2_required", "demand_review_required", "protected_meal"].contains(code) {
                    recoveryMessage = savedWeekText("Open the shared shop to review protected food, unlinked quantities or pack sizes. Then refresh this week.")
                } else if code == "membership_inactive" {
                    recoveryMessage = savedWeekText("An active Household planning seat is required. Check membership and refresh the week.")
                }
            }
        }
    }
    @MainActor private func refreshMenu(_ service: HouseholdService, current: () -> Bool) async throws {
        let fresh = try await service.mealPlan(shopID: scope.shopID, currentWeek: true)
        guard current() else { return }
        guard fresh.shopId == scope.shopID, fresh.phase == "draft" else { throw ClientError.configuration }
        plan = fresh
    }
}
