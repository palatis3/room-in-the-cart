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
        Form {
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
