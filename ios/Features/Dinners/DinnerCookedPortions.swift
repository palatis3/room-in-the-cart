import CoreDomain
import SwiftUI

extension DinnerFeatureModel {
    func cookedDinners(pickup: PickupModel) throws -> [InventoryReservation] {
        guard basketPrepAccess(), let ledgerID = localIdeaWorkspaceID, let shop,
              pickup.pantryIsActive else { return [] }
        guard pickup.pantryRouteAvailable, pickup.pantryReadIsCurrent, let pantry = pickup.pantrySnapshot,
              pickup.sourceWorkspaceID == pantry.state.workspaceID else { throw PantryCookPort.Failure.unavailable }
        let rows = pantry.reservations.compactMap { claim -> (date: String, reservation: InventoryReservation)? in
            guard let dinner = claim.cookedDinner, dinner.shopID == shop.id, dinner.ledgerID == ledgerID,
                  claim.state == .active || dinner.servedAt != nil else { return nil }
            return (dinner.day.iso8601, claim)
        }
        return rows.sorted {
            ($0.date, $0.reservation.name, $0.reservation.id.uuidString) < ($1.date, $1.reservation.name, $1.reservation.id.uuidString)
        }.map(\.reservation)
    }
}

struct DinnerCookedPortionsLabel: View {
    let claim: InventoryReservation
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: claim.name).font(.headline)
            Text(cookCompletionText(claim.cookedDinner?.servedAt == nil ? "Reserved cooked portions" : "Cooked portions served") +
                " · " + (claim.amount?.amount.description ?? "—"))
                .foregroundStyle(Theme.secondary)
        }.accessibilityElement(children: .combine)
    }
}

struct DinnerCookedPortionsView: View {
    @ObservedObject var model: DinnerFeatureModel
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    let id: UUID
    @State private var date = Date()
    private struct Pending {
        let change: CookedDinnerChange
        let actor: CapturePrivateIdentity
        let generation: UUID
    }
    @State private var pending: Pending?
    @State private var saving = false
    @State private var failed = false
    @State private var cancelled = false

    private var actor: CapturePrivateIdentity? {
        guard scene == .active, UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable, model.basketPrepAccess() else { return nil }
        return CapturePrivateIdentity.current(access: access, household: household)
    }
    private var claim: InventoryReservation? { try? model.cookedDinners(pickup: pickup).first { $0.id == id } }
    var body: some View {
        WorkingForm {
            if actor != nil, let claim, let dinner = claim.cookedDinner {
                Section {
                    Text(verbatim: claim.name).font(.system(.title2, design: .serif, weight: .semibold))
                    LabeledContent(cookCompletionText("Dinner day"), value: dinnerDay(dinner.day))
                    LabeledContent(cookCompletionText("Portions for dinner"), value: claim.amount?.amount.description ?? "—")
                    if let served = dinner.servedAt {
                        LabeledContent(cookCompletionText("Served"), value: served.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Button(cookCompletionText("Confirm portions served")) { begin(.serve, claim: claim) }
                            .buttonStyle(PrimaryAction()).disabled(saving || pending != nil)
                            .accessibilityIdentifier("leftover.serve")
                    }
                }
                if dinner.servedAt == nil {
                    Section(cookCompletionText("Change this dinner")) {
                        DatePicker(cookCompletionText("New dinner day"), selection: $date, displayedComponents: .date)
                            .environment(\.timeZone, TimeZone(identifier: dinner.day.timeZoneIdentifier) ?? .current)
                        Button(cookCompletionText("Move dinner")) {
                            if let day = try? MealDay(date: date, timeZoneIdentifier: dinner.day.timeZoneIdentifier) {
                                begin(.move(day), claim: claim)
                            }
                        }.disabled((try? MealDay(date: date, timeZoneIdentifier: dinner.day.timeZoneIdentifier)) == dinner.day)
                            .accessibilityIdentifier("leftover.move")
                        Button(cookCompletionText("Cancel dinner and release portions"), role: .destructive) { begin(.cancel, claim: claim) }
                            .accessibilityIdentifier("leftover.cancel")
                    }.disabled(saving || pending != nil)
                }
            } else if cancelled {
                Text(cookCompletionText("Dinner cancelled. Its portions are available again."))
            } else {
                Text(cookCompletionText("Current cooked portions are unavailable. Reopen this dinner or refresh the pantry."))
            }
            if failed {
                Section {
                    Text(cookCompletionText("Check the current reservation and pantry count before trying again."))
                    if let pending {
                        Button(cookCompletionText("Retry the same confirmation")) { Task { await save(pending) } }
                    }
                    Button(cookCompletionText("Refresh cooked portions")) {
                        Task {
                            if await pickup.refreshPantryStock() { pending = nil; failed = false }
                        }
                    }
                }.disabled(saving)
            }
        }.privacySensitive()
        .navigationTitle(cookCompletionText("Leftover dinner"))
        .onChange(of: claim?.cookedDinner?.day, initial: true) { _, day in
            if let day, let saved = day.date { date = saved }
        }
        .onChange(of: actor) { _, _ in pending = nil; failed = false; cancelled = false }
        .onChange(of: pickup.privatePantryGeneration) { _, _ in pending = nil; failed = false; cancelled = false }
        .dinnerAccess(model)
    }

    private func begin(_ action: CookedDinnerReservation.Action, claim: InventoryReservation) {
        guard !saving, pending == nil, let actor, let change = CookedDinnerChange(claim, action: action) else { return }
        let attempt = Pending(change: change, actor: actor, generation: pickup.privatePantryGeneration)
        pending = attempt
        Task { await save(attempt) }
    }

    @MainActor private func save(_ attempt: Pending) async {
        let change = attempt.change
        guard !saving, let ledger = model.store as? LedgerModel else { return }
        saving = true
        defer { saving = false }
        let allowed = {
            actor == attempt.actor && pickup.privatePantryGeneration == attempt.generation &&
                model.localIdeaWorkspaceID == change.ledgerID && model.shop?.id == change.shopID
        }
        do {
            try await pickup.cookCompletionPort(ledger: ledger, authorize: allowed).changeDinner(change)
            guard allowed() else { return }
            let refreshed = await pickup.refreshPantryStock()
            guard refreshed else { failed = true; return }
            cancelled = change.action == .cancel
            pending = nil
            failed = false
        } catch { failed = true }
    }
}
