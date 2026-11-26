import CoreDomain
import LocalStore
import SwiftUI

struct PantryStaplesView: View {
    @ObservedObject var model: PantryModel
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @Environment(\.guardianChildCoordinator) private var child
    @State private var review: PantryModel.StapleReview?
    @State private var shown: Input?
    @State private var failed = false
    @State private var working = false
    @State private var refreshID = UUID()
    @State private var day = Date()

    private struct Input: Equatable {
        let adult: CapturePrivateIdentity
        let inventory: InventoryState
        let openNames: [String]
        let openFoods: Set<UUID>
        let today: Date
    }

    private var input: Input? {
        guard scene == .active, UIApplication.shared.isProtectedDataAvailable, child?.presented != true,
              household.projection?.grantId == nil, model.canEdit, ledger.ready, pickup.ready,
              let adult = CapturePrivateIdentity.current(access: access, household: household),
              let state = model.snapshot?.state, state.workspaceID == pickup.sourceWorkspaceID else { return nil }
        let closed = Set(pickup.journeys.filter { $0.closedAt != nil }.map(\.id))
        let shops = ledger.workspace.shops.filter { !closed.contains($0.id) }
        let lines = shops.flatMap(\.lines).filter { !$0.isTrashed && !$0.isChecked && !$0.isHandled }
        let requests = household.requests.filter { request in
            guard ["pending", "clarified", "added", "deferred"].contains(request.status), request.purchaseOutcome == nil else { return false }
            return UUID(uuidString: request.shopId).map { !closed.contains($0) } ?? true
        }
        let needs = pickup.journeys.filter { $0.closedAt == nil }.flatMap(\.stockNeeds)
        return Input(adult: adult, inventory: state,
            openNames: (lines.map(\.name) + requests.map(\.originalItem)).sorted(),
            openFoods: Set(needs.filter { $0.amount.amount > .zero }.map(\.foodID)), today: Calendar.current.startOfDay(for: day))
    }

    var body: some View {
        JournalList {
            if let input, input == shown, let review {
                Toggle(pantryText("Ask about regularly purchased staples"), isOn: Binding(
                    get: { review.preferences.enabled },
                    set: { enabled in Task { await update(input) { try await model.setStaplePrompts(enabled, review: review) } } }
                )).disabled(working)
                if review.preferences.enabled {
                    if review.prompts.isEmpty {
                        Text(pantryText("No staples are due for a check. A suggestion needs at least three comparable purchase days."))
                    }
                    ForEach(review.prompts) { prompt in
                        Section(pantryFormat("Need %@ this week?", prompt.name)) {
                            if prompt.reason == .confirmedEmpty {
                                Text(pantryText("Your confirmed counts show none left in the recorded batches."))
                            }
                            Text(pantryFormat("Usually purchased about every %@ days.", prompt.intervalDays.formatted()))
                            if let lot = model.snapshot?.lots.first(where: { $0.foodID == prompt.id && $0.name == prompt.name }) {
                                PantryRestockActions(model: model, lot: lot, sourceCurrent: {
                                    self.input == input && shown == input && self.review?.prompts.contains(prompt) == true
                                }, showCheckDates: false)
                            }
                            Button(pantryText("Still have it")) { answer(.stillHave, prompt: prompt, review: review, input: input) }
                            Button(pantryText("Snooze one week")) {
                                if let next = Calendar.current.date(byAdding: .day, value: 7, to: input.today) {
                                    answer(.snooze(until: next), prompt: prompt, review: review, input: input)
                                }
                            }
                            Button(pantryText("Dismiss this suggestion")) { answer(.dismiss, prompt: prompt, review: review, input: input) }
                        }.disabled(working)
                    }
                } else {
                    Text(pantryText("Use confirmed purchases on this device to suggest when to check a staple. You decide what to buy."))
                }
                NavigationLink(pantryText("Open shopping list")) { LedgerHomeView(model: ledger) }
            } else if input == nil {
                Text(pantryText("Unlock the authorized private workspace to view pantry food."))
            } else if !failed {
                ProgressView()
            }
            if failed && input != nil {
                Button(pantryText("Couldn’t read staple reminders. Refresh to try again.")) { Task { await load(input) } }
            }
        }
        .navigationTitle(pantryText("Running-low staples"))
        .privacySensitive()
        .task(id: input) { await load(input) }
        .refreshable { await load(input) }
        .onReceive(NotificationCenter.default.pantryClockChanges(for: .NSCalendarDayChanged)) { _ in day = Date() }
        .onChange(of: scene) { _, value in if value == .active { day = Date() } }
    }

    private func answer(_ answer: StaplePromptAnswer, prompt: StaplePrompt, review: PantryModel.StapleReview, input: Input) {
        Task { await update(input) { try await model.answerStaple(answer, prompt: prompt, review: review) } }
    }

    @MainActor private func update(_ original: Input, action: () async throws -> Void) async {
        guard !working, shown == original, input == original else { return }
        working = true
        defer { working = false }
        do { try await action() }
        catch {
            if input == original { review = nil; shown = nil; failed = true }
            return
        }
        await load(input)
    }

    @MainActor private func load(_ original: Input?) async {
        let token = UUID()
        refreshID = token
        review = nil; shown = nil; failed = false
        guard let original else { return }
        do {
            let next = try await model.reviewStaples(openFoodIDs: original.openFoods, openLineNames: original.openNames, calendar: .current)
            guard token == refreshID, input == original, !Task.isCancelled else { return }
            review = next; shown = original
        } catch {
            if token == refreshID && input == original && !Task.isCancelled { failed = true }
        }
    }
}
