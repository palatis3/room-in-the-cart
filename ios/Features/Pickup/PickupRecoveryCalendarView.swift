import SwiftUI
import CoreDomain

func currentDinnerText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "DinnerRecoveryRoutes")
}

/// Date-only recovery command. The draft is bound to the displayed full meal,
/// live lease and pickup revision; Apply never edits the original ledger row.
struct PickupRecoveryCalendarView: View {
    @ObservedObject var model: PickupModel
    let original: PickupRecoveryMealDefinition
    let currentAuthority: () -> PickupRecoveryAuthority?
    @State private var draftAuthority: PickupRecoveryAuthority?
    @State private var scheduled: Bool
    @State private var date: Date
    @State private var review: PickupMealContextReview?
    @State private var error: String?
    @State private var applied = false

    init(model: PickupModel, original: PickupRecoveryMealDefinition,
         currentAuthority: @escaping () -> PickupRecoveryAuthority?) {
        self.model = model; self.original = original; self.currentAuthority = currentAuthority
        _draftAuthority = State(initialValue: currentAuthority())
        _scheduled = State(initialValue: original.meal.scheduledDay != nil)
        _date = State(initialValue: original.meal.scheduledDay?.date ?? model.stockReviewDate)
    }
    var body: some View {
        WorkingForm {
            PickupSaveStatus(model: model)
            if !authorized {
                Text(recoveryText("Return to the same unlocked private pickup to review its dinners."))
            } else if applied {
                Text(currentDinnerText("Dinner date saved. Its food, portions, deadline and original purchase are unchanged."))
                    .accessibilityIdentifier("mealRecovery.calendarSaved")
            } else if let review {
                Section(dinnerText("Preview calendar change")) {
                    Text(original.meal.title).font(.headline)
                    Text(dinnerFormat("Before: %@", original.meal.scheduledDay.map(dinnerDay) ?? dinnerText("Unscheduled")))
                    if let current = review.domain.after.meals.first(where: { $0.id == original.meal.id }) {
                        Text(dinnerFormat("After: %@", current.scheduledDay.map(dinnerDay) ?? dinnerText("Unscheduled")))
                    }
                    preservedDeadline
                    Text(currentDinnerText("Only the current dinner date changes. Review any cook instructions already shared."))
                    Button(dinnerText("Cancel")) { self.review = nil; error = nil }
                        .disabled(model.hasPendingSave).accessibilityIdentifier("mealRecovery.calendarCancel")
                    Button(currentDinnerText("Apply dinner date")) {
                        Task {
                            if await model.applyRecoveryMove(review, currentAuthority: currentAuthority) {
                                applied = true; error = nil
                            } else { error = model.error ?? currentDinnerText("The dinner or access changed. Reopen it and review the date again.") }
                        }
                    }.buttonStyle(PrimaryAction()).accessibilityIdentifier("mealRecovery.calendarApply")
                }
            } else {
                Section(original.meal.title) {
                    Toggle(dinnerText("Assign a date"), isOn: $scheduled)
                    if scheduled {
                        DatePicker(dinnerText("Dinner date"), selection: $date, displayedComponents: .date)
                            .accessibilityIdentifier("mealRecovery.calendarDate")
                    }
                    Text(original.meal.timeZoneID)
                    preservedDeadline
                    Button(dinnerText("Preview calendar change"), action: prepare)
                        .disabled(model.hasPendingSave).accessibilityIdentifier("mealRecovery.calendarPreview")
                }
            }
            if let error { Text(error).foregroundStyle(Theme.error).accessibilityIdentifier("mealRecovery.calendarError") }
        }
        .navigationTitle(dinnerText("Move this dinner"))
        .environment(\.timeZone, TimeZone(identifier: original.meal.timeZoneID) ?? .current)
        .disabled(model.saving)
    }
    private var authorized: Bool {
        guard let draftAuthority, let current = currentAuthority() else { return false }
        return current == draftAuthority
    }
    @ViewBuilder private var preservedDeadline: some View {
        if let due = original.meal.due {
            Text(recoveryText("Needed by") + ": " + due.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened,
                timeZone: TimeZone(identifier: original.meal.timeZoneID) ?? .current)))
        } else { Text(recoveryText("Deadline unknown · timing remains conditional")) }
    }
    private func prepare() {
        do {
            guard authorized, let authority = currentAuthority(),
                  try model.recoveryDefinitions().first(where: { $0.meal.id == original.meal.id }) == original else {
                throw PickupMealRecoveryError.stale
            }
            let day = try DinnerEntry.date(date, zone: original.meal.timeZoneID, scheduled: scheduled)
            guard day != original.meal.scheduledDay else { return }
            review = try model.prepareRecoveryMove(occurrenceID: original.meal.id, to: day, operationID: UUID(), authority: authority)
            error = nil
        } catch { self.error = currentDinnerText("The dinner or access changed. Reopen it and review the date again.") }
    }
}
