import HouseholdClient
import SwiftUI

struct SharedCookFeedbackView: View {
    @ObservedObject var model: HouseholdShopModel
    let occurrence: UUID
    let cook: UUID
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.guardianChildCoordinator) private var child
    @State private var page: SharedMealFeedback?
    @State private var loadedScope: HouseholdBootstrap?
    @State private var selected: Set<SharedMealReaction> = []
    @State private var busy = false
    @State private var failed = false
    @State private var lifetime = UUID()
    @Environment(\.dismiss) private var dismiss
    private var allowed: Bool {
        scene == .active && UIApplication.shared.isProtectedDataAvailable && !household.locked &&
        child?.presented != true && household.sharedShop === model && model.canShareMealFeedback
    }
    var body: some View {
        WorkingForm {
            if allowed, let page, loadedScope == model.scope {
                Section(cookingText("My household reactions")) {
                    Text(cookingText("Only the reactions you share here are visible to adults authorized for this cooking record."))
                    ForEach(SharedMealReaction.allCases, id: \.self) { reaction in
                        Toggle(name(reaction), isOn: Binding(get: { selected.contains(reaction) }, set: { value in
                            if value { selected.insert(reaction) } else { selected.remove(reaction) }
                        })).accessibilityIdentifier("sharedFeedback." + reaction.rawValue)
                    }
                    Button(cookingText("Share selected reactions")) { Task { await save(selected, reviewed: page) } }
                        .disabled(selected.isEmpty || selected == Set(page.own))
                    if !page.own.isEmpty {
                        Button(cookingText("Remove my shared reactions"), role: .destructive) { Task { await save([], reviewed: page) } }
                    }
                }
                if !page.shared.isEmpty {
                    Section(cookingText("Shared for this meal in the last 90 days")) {
                        ForEach(page.shared, id: \.self) { Text(name($0)) }
                    }
                }
            } else if failed || !allowed {
                Text(cookingText("Reload this cooking record to check the current shared reactions."))
                if allowed { Button(cookingText("Refresh")) { Task { await load() } } }
            } else { ProgressView() }
        }
        .disabled(busy).privacySensitive()
        .navigationTitle(cookingText("Household meal feedback"))
        .task(id: allowed ? model.scope : nil) { await load() }
        .onDisappear { lifetime = UUID(); page = nil; selected = [] }
    }

    private func load() async {
        let token = UUID()
        lifetime = token
        page = nil; loadedScope = nil; selected = []; failed = false; busy = false
        guard allowed else { return }
        let original = model.scope
        do {
            let next = try await model.sharedMealFeedback(occurrence: occurrence, cook: cook)
            guard lifetime == token, allowed, original == model.scope else { return }
            page = next; loadedScope = original; selected = Set(next.own)
        } catch { if lifetime == token && allowed { failed = true } }
    }

    private func save(_ reactions: Set<SharedMealReaction>, reviewed: SharedMealFeedback) async {
        guard allowed, !busy, page == reviewed else { return }
        let token = lifetime
        busy = true
        do {
            _ = try await model.setSharedMealFeedback(reactions, reviewed: reviewed)
            guard allowed, lifetime == token else { return }
            busy = false; dismiss()
        } catch {
            guard lifetime == token else { return }
            page = nil; selected = []; failed = true; busy = false
        }
    }

    private func name(_ reaction: SharedMealReaction) -> String {
        switch reaction {
        case .makeAgain: cookingText("Make again")
        case .tooMuchEffort: cookingText("Too much effort")
        case .childrenLikedIt: cookingText("Children liked it")
        case .tooManyLeftovers: cookingText("Too many leftovers")
        }
    }
}

struct SharedFeedbackWithdrawalView: View {
    @ObservedObject var household: HouseholdModel
    let scope: HouseholdPantryRuntime
    let service: HouseholdService
    @Environment(\.scenePhase) private var scene
    @Environment(\.guardianChildCoordinator) private var child
    @State private var page: SharedMealFeedbackWithdrawal?
    @State private var lifetime = UUID()
    @State private var failed = false
    @State private var busy = false

    private var allowed: Bool {
        scene == .active && UIApplication.shared.isProtectedDataAvailable && child?.presented != true &&
            household.householdPantryScope == scope && household.projection?.capabilities.contains("my_feedback_withdrawal") == true
    }
    var body: some View {
        WorkingForm {
            if allowed, let page {
                LabeledContent(cookingText("Meals with my shared feedback"), value: page.count.formatted())
                if page.count > 0 {
                    Text(cookingText("Withdrawing removes your reactions from all of these household meals."))
                    Button(cookingText("Withdraw all my shared meal feedback"), role: .destructive) { Task { await reload(withdrawing: page) } }
                        .accessibilityIdentifier("sharedFeedback.withdrawAll")
                }
            } else if failed || !allowed {
                Text(cookingText("Current feedback could not be verified."))
                if allowed { Button(cookingText("Refresh")) { Task { await reload() } } }
            } else { ProgressView() }
        }.navigationTitle(cookingText("Review my shared meal feedback")).privacySensitive()
        .disabled(busy)
        .task(id: allowed) { await reload() }
        .onDisappear { lifetime = UUID(); page = nil }
    }
    private func reload(withdrawing reviewed: SharedMealFeedbackWithdrawal? = nil) async {
        let token = UUID()
        lifetime = token
        page = nil; failed = false; busy = false
        guard allowed else { return }
        busy = true
        defer { if lifetime == token { busy = false } }
        do {
            let next: SharedMealFeedbackWithdrawal
            if let reviewed { next = try await service.withdrawMyMealFeedback(reviewed) }
            else { next = try await service.reviewMyMealFeedbackWithdrawal() }
            guard allowed, lifetime == token else { return }
            page = next
        } catch { if allowed && lifetime == token { failed = true } }
    }
}
