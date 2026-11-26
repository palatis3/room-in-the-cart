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
    var suggestedDay: MealDay? = nil
    @State private var date = Date()
    private struct Pending {
        let change: CookedDinnerChange
        let actor: CapturePrivateIdentity
        let generation: UUID
    }
    @State private var pending: Pending?
    private enum Feedback {
        case moved(MealDay), served, cancelled, shortfall, changed, unconfirmed, needsRefresh

        var text: String {
            switch self {
            case .moved(let day): return String(format: cookCompletionText("Dinner moved to %@."), locale: .current, dinnerDay(day))
            case .served: return cookCompletionText("Dinner served. The pantry count has been updated.")
            case .cancelled: return cookCompletionText("Dinner cancelled. Its reservation has been released.")
            case .shortfall: return cookCompletionText("There are too few confirmed portions. Check the batch and its other reservations.")
            case .changed: return cookCompletionText("The reservation changed. Refresh it before choosing another action.")
            case .unconfirmed: return cookCompletionText("The dinner change could not be confirmed. Refresh the reservation or retry the same confirmation.")
            case .needsRefresh: return cookCompletionText("The dinner change was saved. Refresh the pantry to see it.")
            }
        }
        var needsRecovery: Bool {
            switch self { case .shortfall, .changed, .unconfirmed, .needsRefresh: true; default: false }
        }
    }
    @State private var workingID: UUID?
    @State private var result: (attempt: Pending, feedback: Feedback)?
    private var saving: Bool { workingID != nil }
    private var feedback: Feedback? {
        guard let result, inScope(result.attempt) else { return nil }
        return result.feedback
    }

    private var actor: CapturePrivateIdentity? {
        guard scene == .active, UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable, model.basketPrepAccess() else { return nil }
        return CapturePrivateIdentity.current(access: access, household: household)
    }
    private var claim: InventoryReservation? { try? model.cookedDinners(pickup: pickup).first { $0.id == id } }
    var body: some View {
        WorkingForm {
            if let feedback {
                Text(feedback.text).foregroundStyle(feedback.needsRecovery ? Theme.error : Theme.ink)
                    .accessibilityIdentifier("leftover.result")
            }
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
            } else if feedback == nil {
                Text(cookCompletionText("Current cooked portions are unavailable. Reopen this dinner or refresh the pantry."))
            }
            if feedback?.needsRecovery == true, let pending {
                Section {
                    if case .unconfirmed = feedback {
                        Button(cookCompletionText("Retry the same confirmation")) { Task { await save(pending) } }
                    }
                    Button(cookCompletionText("Refresh cooked portions")) { Task { await refresh(pending) } }
                }.disabled(saving)
            }
        }.privacySensitive()
        .navigationTitle(cookCompletionText("Leftover dinner"))
        .onChange(of: claim?.cookedDinner?.day, initial: true) { _, day in
            if let day, let saved = day.date {
                if let suggestedDay, suggestedDay.timeZoneIdentifier == day.timeZoneIdentifier,
                   suggestedDay.iso8601 > day.iso8601, let target = suggestedDay.date { date = target }
                else { date = saved }
            }
        }
        .dinnerAccess(model)
        .onChange(of: actor) { _, _ in clearResult() }
        .onChange(of: pickup.privatePantryGeneration) { _, _ in clearResult() }
        .onChange(of: model.shop?.id) { _, _ in clearResult() }
        .onDisappear { clearResult() }
    }

    private func begin(_ action: CookedDinnerReservation.Action, claim: InventoryReservation) {
        guard !saving, pending == nil, let actor, let change = CookedDinnerChange(claim, action: action) else { return }
        let attempt = Pending(change: change, actor: actor, generation: pickup.privatePantryGeneration)
        result = nil
        pending = attempt
        Task { await save(attempt) }
    }

    private func clearResult() {
        pending = nil
        result = nil
        workingID = nil
    }

    private func inScope(_ attempt: Pending) -> Bool {
        actor == attempt.actor && pickup.privatePantryGeneration == attempt.generation &&
            model.store.sourceWorkspaceID == attempt.change.ledgerID && model.shop?.id == attempt.change.shopID
    }

    private func permits(_ attempt: Pending) -> Bool {
        pending?.change.id == attempt.change.id && inScope(attempt) && model.localIdeaWorkspaceID == attempt.change.ledgerID
    }

    private func report(_ feedback: Feedback, for attempt: Pending) {
        guard permits(attempt) else { return }
        result = (attempt, feedback)
        if !feedback.needsRecovery { pending = nil }
        UIAccessibility.post(notification: .announcement, argument: feedback.text)
    }

    private func reportSaved(_ attempt: Pending) {
        switch attempt.change.action {
        case .move(let day): report(.moved(day), for: attempt)
        case .serve: report(.served, for: attempt)
        case .cancel: report(.cancelled, for: attempt)
        }
    }

    @MainActor private func refresh(_ attempt: Pending) async {
        guard !saving, permits(attempt) else { return }
        workingID = attempt.change.id
        defer { if workingID == attempt.change.id { workingID = nil } }
        let refreshed = await pickup.refreshPantryStock()
        guard permits(attempt) else { return }
        if case .needsRefresh = feedback {
            if refreshed { reportSaved(attempt) } else { report(.needsRefresh, for: attempt) }
        } else if refreshed {
            clearResult()
        } else {
            report(.unconfirmed, for: attempt)
        }
    }

    @MainActor private func save(_ attempt: Pending) async {
        guard !saving, permits(attempt), let ledger = model.store as? LedgerModel else { return }
        workingID = attempt.change.id
        defer { if workingID == attempt.change.id { workingID = nil } }
        do {
            try await pickup.cookCompletionPort(ledger: ledger, authorize: { permits(attempt) }).changeDinner(attempt.change)
            guard permits(attempt) else { return }
            let refreshed = await pickup.refreshPantryStock()
            guard permits(attempt) else { return }
            if refreshed { reportSaved(attempt) } else { report(.needsRefresh, for: attempt) }
        } catch InventoryError.invalid("cookedPortionHolds") {
            report(.shortfall, for: attempt)
        } catch PantryCookPort.Failure.changed {
            report(.changed, for: attempt)
        } catch {
            report(.unconfirmed, for: attempt)
        }
    }
}
