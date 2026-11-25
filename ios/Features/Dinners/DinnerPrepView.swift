import SwiftUI
import CoreDomain

func dinnerPlanText(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "DinnerBasketAndPrep") }
func dinnerPlanFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: dinnerPlanText(key), locale: .current, arguments: arguments)
}

struct DinnerPrepSection: View {
    @ObservedObject var model: DinnerFeatureModel
    let meal: MealOccurrence
    let canScheduleAlerts: Bool
    @ObservedObject private var alerts = DinnerPrepAlerts.shared
    @State private var instruction = ""
    @State private var days = 1
    @State private var hour = 18
    @State private var denied = false
    private var saved: DinnerPrepTask? {
        model.state.prepTasks.first { $0.shopID == model.shop?.id && $0.occurrenceID == meal.id }
    }
    var body: some View {
        if let editor = model.editorIdentity, let workspace = model.localIdeaWorkspaceID, let revision = model.shop?.revisionID {
            Section(dinnerPlanText("Dinner prep")) {
                if let saved {
                    let key = DinnerPrepAlerts.key(workspace: workspace, task: saved.id)
                    Text(saved.instruction)
                    if let date = try? saved.dueDate() {
                        Text(dinnerStoreSlot(date, zoneID: saved.dinnerDay.timeZoneIdentifier))
                    }
                    if let completed = saved.completedAt {
                        Text(dinnerPlanFormat("Completed %@", dinnerStoreSlot(completed, zoneID: saved.dinnerDay.timeZoneIdentifier)))
                    } else {
                        if saved.dinnerDay != meal.scheduledDay {
                            Text(dinnerPlanText("Dinner moved. The original alert is paused."))
                            if let day = meal.scheduledDay {
                                Button(dinnerPlanText("Move prep to the new dinner date")) {
                                    Task { await model.savePrep(saved.moved(to: day), previous: saved, mealID: meal.id, revision: revision, editor: editor) }
                                }
                            }
                        } else if canScheduleAlerts {
                            Button(dinnerPlanText(alerts.enabled.contains(key) ? "Turn off prep alert" : "Enable prep alert on this device")) {
                                if alerts.enabled.contains(key) { alerts.setEnabled(false, key: key); denied = false }
                                else {
                                    Task {
                                        let granted = await alerts.permission()
                                        guard model.editorIdentity == editor, self.saved == saved else { return }
                                        denied = !granted
                                        if granted { alerts.setEnabled(true, key: key) }
                                    }
                                }
                            }
                            if denied || alerts.failed.contains(key) {
                                Text(dinnerPlanText("The alert is unavailable. Your prep task is saved here."))
                            }
                        }
                        Button(dinnerPlanText("Mark prep complete")) {
                            Task {
                                if await model.savePrep(saved, previous: saved, mealID: meal.id, revision: revision, editor: editor, completing: true) {
                                    alerts.setEnabled(false, key: key)
                                }
                            }
                        }
                        Button(dinnerPlanText("Remove prep task"), role: .destructive) {
                            Task {
                                if await model.savePrep(nil, previous: saved, mealID: meal.id, revision: revision, editor: editor) {
                                    alerts.setEnabled(false, key: key)
                                }
                            }
                        }
                    }
                } else if let day = meal.scheduledDay {
                    TextField(dinnerPlanText("Prep instruction"), text: $instruction, axis: .vertical)
                    Stepper(dinnerPlanFormat("Days before dinner: %lld", Int64(days)), value: $days, in: 0...7)
                    Picker(dinnerPlanText("Local prep time"), selection: $hour) {
                        ForEach(0..<24, id: \.self) { number in
                            Text(verbatim: String(format: "%02d:00", number)).tag(number)
                        }
                    }
                    let draft = DinnerPrepTask(shopID: editor.shopID, occurrenceID: meal.id, instruction: instruction,
                                               daysBefore: days, hour: hour, dinnerDay: day)
                    if let date = try? draft.dueDate() {
                        Text(dinnerStoreSlot(date, zoneID: day.timeZoneIdentifier))
                        Button(dinnerPlanText("Save prep task")) {
                            Task { await model.savePrep(draft, previous: nil, mealID: meal.id, revision: revision, editor: editor) }
                        }.disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || instruction.utf8.count > 512)
                    } else { Text(dinnerPlanText("Choose another hour for this local clock change.")) }
                } else { Text(dinnerPlanText("Date this dinner to add a prep task.")) }
            }.disabled(!model.editable)
            if let day = meal.scheduledDay {
                DinnerServeScheduleSection(model: model, meal: meal, day: day, editor: editor, workspace: workspace,
                                          revision: revision, canScheduleAlerts: canScheduleAlerts)
            }
        }
    }
}

struct DinnerPrepAgenda: View {
    @ObservedObject var model: DinnerFeatureModel
    @EnvironmentObject private var pickup: PickupModel

    private var activeMealIDs: Set<UUID> {
        guard let shop = model.shop, let current = try? model.currentMeals(pickup: pickup) else { return [] }
        let journey = pickup.journeys.first { $0.id == shop.id }
        guard journey?.closedAt == nil else { return [] }
        let meals = Set(current.all.compactMap { row -> UUID? in
            guard case .original(let meal) = row, meal.carryover == nil else { return nil }
            return meal.id
        })
        let cooked = Set((journey?.cookedMeals ?? []).filter(\.isActive).map(\.draft.meal.id))
        return meals.subtracting(cooked)
    }
    var body: some View {
        let meals = activeMealIDs
        let tasks = model.state.prepTasks.filter {
            $0.shopID == model.shop?.id && $0.completedAt == nil && meals.contains($0.occurrenceID)
        }.sorted { ($0.dueDateOrPast, $0.id.uuidString) < ($1.dueDateOrPast, $1.id.uuidString) }
        let schedules = model.state.serveSchedules.filter {
            $0.shopID == model.shop?.id && meals.contains($0.occurrenceID) && $0.serveAt > model.clock()
        }.sorted { $0.serveAt < $1.serveAt }
        if !tasks.isEmpty || !schedules.isEmpty {
            Section(dinnerPlanText("Dinner prep")) {
                ForEach(schedules) { schedule in
                    if let meal = model.shop?.mealOccurrences.first(where: { $0.id == schedule.occurrenceID }) {
                        NavigationLink {
                            DinnerOccurrenceView(model: model, occurrenceID: meal.id)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(verbatim: meal.title).font(.headline)
                                if meal.scheduledDay != schedule.dinnerDay {
                                    Text(dinnerPlanText("Dinner moved. Review the schedule for its new date."))
                                } else if let next = (try? schedule.sequence())?.first(where: { $0.end > model.clock() }) {
                                    Text(verbatim: next.dish + " · " + next.step.instruction)
                                    Text(dinnerStoreSlot(next.start, zoneID: schedule.dinnerDay.timeZoneIdentifier))
                                }
                            }
                        }
                    }
                }
                ForEach(tasks) { task in
                    if let meal = model.shop?.mealOccurrences.first(where: { $0.id == task.occurrenceID }) {
                        NavigationLink {
                            DinnerOccurrenceView(model: model, occurrenceID: meal.id)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(meal.title).font(.headline)
                                Text(task.instruction)
                                if meal.scheduledDay != task.dinnerDay {
                                    Text(dinnerPlanText("Dinner moved. The original alert is paused."))
                                } else if let date = try? task.dueDate() {
                                    Text(dinnerStoreSlot(date, zoneID: task.dinnerDay.timeZoneIdentifier))
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private extension DinnerPrepTask {
    var dueDateOrPast: Date { (try? dueDate()) ?? .distantPast }
}

private extension DinnerServeSchedule.Equipment {
    var label: String {
        switch self {
        case .none: return dinnerPlanText("No shared equipment")
        case .oven: return dinnerPlanText("One oven")
        case .burner: return dinnerPlanText("One burner")
        case .microwave: return dinnerPlanText("One microwave")
        }
    }
}

private struct DinnerServeScheduleSection: View {
    @ObservedObject var model: DinnerFeatureModel
    let meal: MealOccurrence
    let day: MealDay
    let editor: DinnerFeatureModel.EditorIdentity
    let workspace: UUID
    let revision: UUID
    let canScheduleAlerts: Bool
    @ObservedObject private var alerts = DinnerPrepAlerts.shared
    @EnvironmentObject private var pickup: PickupModel
    @State private var denied = false
    @State private var removing = false
    private struct SavedEdit {
        let previous: DinnerServeSchedule?
        let value: DinnerServeSchedule
        let editor: DinnerFeatureModel.EditorIdentity
    }
    @State private var lastEdit: SavedEdit?

    private var saved: DinnerServeSchedule? {
        model.state.serveSchedules.first { $0.shopID == editor.shopID && $0.occurrenceID == meal.id }
    }

    var body: some View {
        if model.paid || saved != nil {
            Section(dinnerPlanText("Serve-time schedule")) {
                if let saved {
                    let key = DinnerPrepAlerts.scheduleKey(workspace: workspace, schedule: saved.id)
                    if saved.dinnerDay != day {
                        Label(dinnerPlanText("Dinner moved. Review the schedule for its new date."), systemImage: "calendar.badge.exclamationmark")
                    } else if let sequence = try? saved.sequence() {
                        Text(dinnerPlanFormat("Serve at %@", dinnerStoreSlot(saved.serveAt, zoneID: day.timeZoneIdentifier)))
                        ServeScheduleRows(schedule: saved, sequence: sequence)
                    }
                    if canScheduleAlerts && (saved.dinnerDay == day || alerts.enabled.contains(key)) {
                        Button(dinnerPlanText(alerts.enabled.contains(key) ? "Turn off schedule alerts" : "Enable schedule alerts on this device")) {
                            if alerts.enabled.contains(key) {
                                alerts.setEnabled(false, key: key)
                                denied = false
                            } else {
                                Task {
                                    let granted = await alerts.permission()
                                    guard model.basketPrepAccess(), model.editorIdentity == editor, self.saved == saved else { return }
                                    denied = !granted
                                    if granted { alerts.setEnabled(true, key: key) }
                                }
                            }
                        }
                        if denied || alerts.failed.contains(where: { $0.hasPrefix(key + ".") }) {
                            Text(dinnerPlanText("Some alerts are unavailable. Your schedule is saved here."))
                        }
                    }
                }
                if model.paid {
                    DinnerDecisionButton(model: model, title: dinnerPlanText(saved == nil ? "Plan backward from serving time" : "Edit serve-time schedule"),
                                         identifier: "dinner.prep.serveSchedule") {
                        DinnerServeScheduleEditor(model: model, meal: meal, day: day, editor: editor, revision: revision, saved: saved) { previous, value in
                            lastEdit = SavedEdit(previous: previous, value: value, editor: editor)
                        }
                    }
                }
                if let lastEdit, lastEdit.editor == editor, lastEdit.value == saved {
                    Text(dinnerPlanText("Cooking schedule saved."))
                    if lastEdit.previous == nil || (model.paid && lastEdit.previous?.dinnerDay == day) {
                        Button(dinnerPlanText("Undo schedule change")) {
                            Task {
                                if await model.saveServeSchedule(lastEdit.previous, previous: lastEdit.value, mealID: meal.id,
                                                                 revision: revision, editor: editor, pickup: pickup) {
                                    if lastEdit.previous == nil {
                                        alerts.setEnabled(false, key: DinnerPrepAlerts.scheduleKey(workspace: workspace, schedule: lastEdit.value.id))
                                    }
                                    self.lastEdit = nil
                                }
                            }
                        }
                    }
                }
                if let saved {
                    Button(dinnerPlanText("Remove serve-time schedule"), role: .destructive) { removing = true }
                        .confirmationDialog(dinnerPlanText("Remove this schedule and its alerts?"), isPresented: $removing) {
                            Button(dinnerPlanText("Remove serve-time schedule"), role: .destructive) {
                                Task {
                                    if await model.saveServeSchedule(nil, previous: saved, mealID: meal.id, revision: revision, editor: editor, pickup: pickup) {
                                        alerts.setEnabled(false, key: DinnerPrepAlerts.scheduleKey(workspace: workspace, schedule: saved.id))
                                    }
                                }
                            }
                        }
                }
            }.disabled(!model.editable)
        }
    }
}

private struct ServeScheduleRows: View {
    let schedule: DinnerServeSchedule
    let sequence: [DinnerServeSchedule.Slot]
    var previous: [DinnerServeSchedule.Slot] = []

    private func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: TimeZone(identifier: schedule.dinnerDay.timeZoneIdentifier) ?? .current))
    }

    var body: some View {
        if let first = sequence.first, first.start < schedule.earliestStart {
            Label(dinnerPlanFormat("This sequence needs %lld more minutes than you have.", Int64(ceil(schedule.earliestStart.timeIntervalSince(first.start) / 60))),
                  systemImage: "exclamationmark.triangle")
        }
        ForEach(sequence) { slot in
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: slot.dish + " · " + slot.step.instruction).font(.headline)
                Text(dinnerPlanFormat("%@ to %@", time(slot.start), time(slot.end)))
                if slot.step.equipment != .none { Text(slot.step.equipment.label) }
                if let old = previous.first(where: { $0.id == slot.id }), old.start != slot.start {
                    Text(dinnerPlanFormat("Previously started at %@", time(old.start)))
                }
            }.accessibilityElement(children: .combine)
        }
    }
}

private struct DinnerServeScheduleEditor: View {
    @ObservedObject var model: DinnerFeatureModel
    @EnvironmentObject private var pickup: PickupModel
    @Environment(\.closeDinnerDecision) private var close
    @State private var draft: DinnerServeSchedule
    @State private var original: DinnerServeSchedule?
    @State private var originalRevision: UUID
    @State private var owner: DinnerFeatureModel.EditorIdentity
    let didSave: (DinnerServeSchedule?, DinnerServeSchedule) -> Void
    let recipeStepCount: Int
    let hasLongRecipeTimer: Bool
    @State private var reviewing = false
    @AccessibilityFocusState private var reviewFocus: Bool

    init(model: DinnerFeatureModel, meal: MealOccurrence, day: MealDay, editor: DinnerFeatureModel.EditorIdentity,
         revision: UUID, saved: DinnerServeSchedule?, didSave: @escaping (DinnerServeSchedule?, DinnerServeSchedule) -> Void) {
        self.model = model
        self.didSave = didSave
        _original = State(initialValue: saved)
        _originalRevision = State(initialValue: revision)
        _owner = State(initialValue: editor)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: day.timeZoneIdentifier) ?? .current
        let oldClock = saved.map { calendar.dateComponents([.hour, .minute], from: $0.serveAt) }
        let serveAt = calendar.date(bySettingHour: oldClock?.hour ?? 19, minute: oldClock?.minute ?? 0, second: 0, of: day.date ?? Date()) ?? day.date ?? Date()
        let recipeSteps = meal.recipeSteps ?? []
        recipeStepCount = recipeSteps.count
        hasLongRecipeTimer = recipeSteps.prefix(12).contains { ($0.suggestedTimerMinutes ?? 0) > 720 }
        let initialSteps = recipeSteps.prefix(12).map {
            DinnerServeSchedule.Step(instruction: $0.instruction, minutes: min($0.suggestedTimerMinutes ?? 10, 720))
        }
        let dish = DinnerServeSchedule.Dish(name: meal.title, steps: initialSteps.isEmpty ? [.init()] : initialSteps)
        var schedule = saved ?? .init(shopID: editor.shopID, occurrenceID: meal.id, dinnerDay: day, serveAt: serveAt, dishes: [dish])
        if schedule.dinnerDay != day {
            schedule.dinnerDay = day
            schedule.serveAt = serveAt
        }
        _draft = State(initialValue: schedule)
    }

    private var current: Bool {
        guard model.editorIdentity == owner, model.basketPrepAccess(), model.paid,
              model.shop?.revisionID == originalRevision,
              let meal = model.shop?.mealOccurrences.first(where: { $0.id == draft.occurrenceID }),
              meal.scheduledDay == draft.dinnerDay, !meal.isHidden, meal.removedAt == nil else { return false }
        return model.state.serveSchedules.first { $0.shopID == owner.shopID && $0.occurrenceID == draft.occurrenceID } == original
    }

    var body: some View {
        Form {
            if current, original == nil {
                if recipeStepCount > 12 {
                    Text(dinnerPlanFormat("This schedule starts with the first 12 of %lld recipe steps. Review the remaining steps in the recipe before you save.", Int64(recipeStepCount)))
                }
                if hasLongRecipeTimer {
                    Text(dinnerPlanText("A recipe timer exceeds 12 hours. Its schedule step starts at 720 minutes. Review the duration before saving."))
                }
            }
            if !current {
                Text(dinnerText("The pickup or dinner plan changed. Make a new preview before applying."))
            } else if reviewing, let sequence = try? draft.sequence() {
                Section(dinnerPlanText("Review cooking times")) {
                    Text(dinnerPlanFormat("Serve at %@", dinnerStoreSlot(draft.serveAt, zoneID: draft.dinnerDay.timeZoneIdentifier)))
                        .accessibilityFocused($reviewFocus)
                    ServeScheduleRows(schedule: draft, sequence: sequence, previous: (try? original?.sequence()) ?? [])
                }
                Button(dinnerPlanText("Save serve-time schedule")) {
                    Task {
                        if await model.saveServeSchedule(draft, previous: original, mealID: draft.occurrenceID,
                                                        revision: originalRevision, editor: owner, pickup: pickup) {
                            didSave(original, draft)
                            close?()
                        }
                    }
                }.disabled(!model.editable).accessibilityIdentifier("dinner.prep.saveSchedule")
                Button(dinnerPlanText("Keep editing")) { reviewing = false }
                if let error = model.error { Text(error) }
            } else {
                Section {
                    DatePicker(dinnerPlanText("Serving time"), selection: $draft.serveAt, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, TimeZone(identifier: draft.dinnerDay.timeZoneIdentifier) ?? .current)
                    Stepper(dinnerPlanFormat("Time available: %lld min", Int64(draft.availableMinutes)), value: $draft.availableMinutes, in: 5...1440, step: 5)
                    Text(dinnerPlanText("Check each step’s duration and cooking order. Steps using the same appliance take turns."))
                }
                ForEach($draft.dishes) { $dish in
                    Section {
                        TextField(dinnerPlanText("Dish name"), text: $dish.name, axis: .vertical)
                            .lineLimit(1...3)
                        if dish.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(dinnerPlanText("Enter a dish name to review cooking times.")).font(.footnote)
                        } else if dish.name.utf8.count > 256 {
                            Text(dinnerPlanText("Shorten this dish name to review cooking times.")).font(.footnote)
                        }
                        ForEach($dish.steps) { $step in
                            VStack(alignment: .leading, spacing: 8) {
                                TextField(dinnerPlanText("What needs doing?"), text: $step.instruction, axis: .vertical)
                                    .lineLimit(1...4)
                                if step.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(dinnerPlanText("Describe this step to review cooking times.")).font(.footnote)
                                } else if step.instruction.utf8.count > 512 {
                                    Text(dinnerPlanText("Shorten this instruction or divide it into steps to review cooking times.")).font(.footnote)
                                }
                                Stepper(dinnerPlanFormat("Duration: %lld min", Int64(step.minutes)), value: $step.minutes, in: 1...720)
                                Picker(dinnerPlanText("Equipment"), selection: $step.equipment) {
                                    ForEach(DinnerServeSchedule.Equipment.allCases, id: \.self) { item in Text(item.label).tag(item) }
                                }
                                if dish.steps.count > 1, let position = dish.steps.firstIndex(where: { $0.id == step.id }) {
                                    Menu(dinnerPlanText("Step options")) {
                                        if position > 0 {
                                            Button(dinnerPlanText("Move step earlier")) { dish.steps.swapAt(position, position - 1) }
                                        }
                                        if position + 1 < dish.steps.count {
                                            Button(dinnerPlanText("Move step later")) { dish.steps.swapAt(position, position + 1) }
                                        }
                                        Button(dinnerPlanText("Remove step"), role: .destructive) { dish.steps.remove(at: position) }
                                    }
                                }
                            }
                        }
                        if dish.steps.count < 12 { Button(dinnerPlanText("Add cooking step")) { dish.steps.append(.init()) } }
                        if draft.dishes.count > 1 {
                            let dishID = dish.id
                            Button(dinnerPlanText("Remove dish"), role: .destructive) { draft.dishes.removeAll { $0.id == dishID } }
                        }
                    }
                }
                if draft.dishes.count < 12 { Button(dinnerPlanText("Add another dish")) { draft.dishes.append(.init()) } }
                Button(dinnerPlanText("Review cooking times")) { reviewing = true; reviewFocus = true }
                    .disabled((try? draft.sequence()) == nil)
                    .accessibilityIdentifier("dinner.prep.reviewSchedule")
            }
        }.navigationTitle(dinnerPlanText("Serve-time schedule"))
    }
}
