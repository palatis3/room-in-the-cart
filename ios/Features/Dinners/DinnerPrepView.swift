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
        }
    }
}

struct DinnerPrepAgenda: View {
    @ObservedObject var model: DinnerFeatureModel
    @EnvironmentObject private var pickup: PickupModel

    private var pending: [DinnerPrepTask] {
        guard let shop = model.shop, let current = try? model.currentMeals(pickup: pickup) else { return [] }
        let journey = pickup.journeys.first { $0.id == shop.id }
        guard journey?.closedAt == nil else { return [] }
        let meals = Set(current.all.compactMap { row -> UUID? in
            guard case .original(let meal) = row, meal.carryover == nil else { return nil }
            return meal.id
        })
        let cooked = Set((journey?.cookedMeals ?? []).filter(\.isActive).map(\.draft.meal.id))
        return model.state.prepTasks.filter {
            $0.shopID == shop.id && $0.completedAt == nil && meals.contains($0.occurrenceID) && !cooked.contains($0.occurrenceID)
        }.sorted { ($0.dueDateOrPast, $0.id.uuidString) < ($1.dueDateOrPast, $1.id.uuidString) }
    }
    var body: some View {
        let tasks = pending
        if !tasks.isEmpty {
            Section(dinnerPlanText("Dinner prep")) {
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
