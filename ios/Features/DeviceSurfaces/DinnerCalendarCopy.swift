import SwiftUI
import EventKit
import EventKitUI
import CoreDomain

extension DinnerCalendarDraft {
    @MainActor func makeEvent(store: EKEventStore) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.timeZone = timeZone
        event.isAllDay = allDay
        event.startDate = start
        event.endDate = end
        return event
    }
}

private struct DinnerSystemEventEditor: UIViewControllerRepresentable {
    let draft: DinnerCalendarDraft
    let finish: (EKEventEditViewAction) -> Void

    @MainActor final class Coordinator: NSObject, EKEventEditViewDelegate {
        let store = EKEventStore()
        let finish: (EKEventEditViewAction) -> Void
        init(finish: @escaping (EKEventEditViewAction) -> Void) { self.finish = finish }
        nonisolated func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            Task { @MainActor in finish(action) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let editor = EKEventEditViewController()
        let coordinator = context.coordinator
        editor.eventStore = coordinator.store
        editor.event = draft.makeEvent(store: coordinator.store)
        editor.editViewDelegate = coordinator
        return editor
    }
    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}
}

struct DinnerCalendarCopyView: View {
    let day: MealDay
    let authorize: () -> Bool
    @State private var usePrepTime = false
    @State private var prepTime: Date
    @State private var editing = false
    @State private var saved = false
    @Environment(\.dismiss) private var dismiss

    init(day: MealDay, authorize: @escaping () -> Bool) {
        self.day = day; self.authorize = authorize
        _prepTime = State(initialValue: day.date ?? Date())
    }

    var body: some View {
        WorkingForm {
            Section {
                Text(applePlanningText("Dinner"))
                Text(dinnerDay(day))
                Toggle(applePlanningText("Set a prep time"), isOn: $usePrepTime)
                if usePrepTime {
                    DatePicker(applePlanningText("Start prep"), selection: $prepTime, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, TimeZone(identifier: day.timeZoneIdentifier) ?? .current)
                    Text(verbatim: day.timeZoneIdentifier)
                }
            }
            Section {
                Text(applePlanningText("In the Calendar editor, review the title, time and destination calendar. People sharing that calendar may see the event."))
                Text(applePlanningText("This is a one-time copy. Moving dinner in the meal plan will not move the calendar event."))
                if saved {
                    Text(applePlanningText("Copy saved to Calendar."))
                } else {
                    Button(applePlanningText("Open Calendar editor")) { if authorize() { editing = true } else { dismiss() } }
                }
            }
        }.navigationTitle(applePlanningText("Add dinner to Calendar"))
            .sheet(isPresented: $editing) {
                if authorize(), let draft = DinnerCalendarDraft(day: day, prepTime: usePrepTime ? prepTime : nil,
                                                                 title: applePlanningText("Dinner")) {
                    DinnerSystemEventEditor(draft: draft) { result in
                        saved = result == .saved
                        editing = false
                    }
                } else {
                    Text(applePlanningText("The dinner changed. Reopen it to make a calendar copy."))
                }
            }
    }
}
