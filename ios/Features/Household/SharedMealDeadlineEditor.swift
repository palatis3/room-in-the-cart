import HouseholdClient
import SwiftUI

struct SharedMealDeadlineEditor: View {
    let meal: SharedMeal
    let save: (SharedMealDeadline?) -> Void
    @Environment(\.locale) private var locale
    @State private var editing = false

    var body: some View {
        LabeledContent(sharedRecoveryText("Meal deadline"), value: meal.planning?.deadline?.display(locale: locale) ?? ht("Unknown"))
        Button(sharedRecoveryText("Set meal deadline")) { editing = true }
            .accessibilityIdentifier("sharedMeal.editDeadline")
            .disabled(meal.day == nil)
            .sheet(isPresented: $editing) {
                SharedMealDeadlinePicker(meal: meal) { deadline in save(deadline); editing = false }
            }
        if meal.planning?.deadline != nil {
            Button(sharedRecoveryText("Clear meal deadline")) { save(nil) }
                .accessibilityIdentifier("sharedMeal.clearDeadline")
        }
    }
}

private struct SharedMealDeadlinePicker: View {
    let meal: SharedMeal
    let save: (SharedMealDeadline) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var zoneID: String
    @State private var selected: Date?
    @State private var path: [Destination] = []

    init(meal: SharedMeal, save: @escaping (SharedMealDeadline) -> Void) {
        self.meal = meal; self.save = save
        let recorded = meal.planning?.deadline
        let deviceZone = TimeZone.current.identifier
        _zoneID = State(initialValue: recorded?.zone ?? (SharedMealDeadline(at: "", zone: deviceZone).timeZone != nil ? deviceZone : "UTC"))
        _selected = State(initialValue: recorded?.instant)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zoneID) ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var interval: DateInterval? {
        guard let civil = sharedMealDate(meal.day) else { return nil }
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = utc.dateComponents([.year,.month,.day], from: civil)
        components.hour = 12
        guard let noon = calendar.date(from: components),
              (try? SharedMealDeadline(at: noon.ISO8601Format(), zone: zoneID).validate(day: meal.day)) != nil else { return nil }
        return calendar.dateInterval(of: .day, for: noon)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                // On iOS 17, retaining the repeated-time controls during this push can keep layout running.
                // The civil time and selected occurrence stay in this view's state while the list is open.
                if path.isEmpty { editor }
                else { Color.clear.accessibilityHidden(true) }
            }
            .navigationTitle(sharedRecoveryText("Meal deadline"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() } } }
            .navigationDestination(for: Destination.self) { _ in
                ScheduledTimeZoneList(selected: zoneID, choose: changeZone)
            }
        }
    }

    private var editor: some View {
        WorkingForm {
            LabeledContent(sharedRecoveryText("Scheduled day"), value: sharedMealScheduleText(meal.day, locale: locale))
            NavigationLink(value: Destination.timeZone) {
                LabeledContent(sharedRecoveryText("Scheduled time zone"), value: zoneID)
            }.accessibilityIdentifier("sharedMeal.deadlineZone")
            if let interval {
                let fallback = interval.start.addingTimeInterval(interval.duration / 2)
                let instant = selected.flatMap { $0 >= interval.start && $0 < interval.end ? $0 : nil } ?? fallback
                let recorded = meal.planning?.deadline
                let value = recorded.flatMap { $0.zone == zoneID && $0.instant == instant ? $0 : nil }
                    ?? SharedMealDeadline(at: instant.ISO8601Format(), zone: zoneID)
                DatePicker(sharedRecoveryText("Meal deadline"), selection: Binding(get: { instant }, set: { selected = $0 }),
                           in: interval.start...interval.end.addingTimeInterval(-1), displayedComponents: .hourAndMinute)
                    .environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
                    .accessibilityIdentifier("sharedMeal.deadlineTime")
                let times = repeatedTimes(for: instant, interval: interval)
                if times.count == 2 {
                    Picker(sharedRecoveryText("Repeated clock time"), selection: Binding(get: { instant }, set: { selected = $0 })) {
                        ForEach(times, id: \.self) { time in
                            Text(verbatim: SharedMealDeadline(at: time.ISO8601Format(), zone: zoneID).display(locale: locale) ?? zoneID).tag(time)
                        }
                    }
                }
                if let text = value.display(locale: locale) { Text(verbatim: text).accessibilityIdentifier("sharedMeal.deadlinePreview") }
                Button(sharedRecoveryText("Use this deadline")) { save(value) }
                    .accessibilityIdentifier("sharedMeal.useDeadline")
            } else { Text(sharedRecoveryText("This date does not occur in the selected time zone.")) }
        }
    }

    private enum Destination: Hashable { case timeZone }

    private func changeZone(_ zone: String) {
        guard zoneID != zone else { return }
        zoneID = zone
        selected = nil
    }

    private func repeatedTimes(for value: Date, interval: DateInterval) -> [Date] {
        let clock = calendar.dateComponents([.hour,.minute,.second], from: value)
        let times = [Calendar.RepeatedTimePolicy.first, .last].compactMap { policy in
            calendar.nextDate(after: interval.start.addingTimeInterval(-1), matching: clock,
                              matchingPolicy: .strict, repeatedTimePolicy: policy)
        }.filter { $0 < interval.end }
        return Array(Set(times)).sorted()
    }
}

private struct ScheduledTimeZoneList: View {
    let selected: String
    let choose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private static let standardZones = Set(TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") } + ["UTC"]).sorted()

    private var zones: [String] {
        let standard = Self.standardZones
        let available = standard.contains(selected) ? standard : (standard + [selected]).sorted()
        return search.isEmpty ? available : available.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        List(zones, id: \.self) { zone in
            Button {
                choose(zone)
                dismiss()
            } label: {
                if selected == zone { Label(zone, systemImage: "checkmark") }
                else { Text(verbatim: zone) }
            }
            .listRowBackground(Theme.surface)
            .listRowSeparatorTint(contrast == .increased ? Theme.controlEdge : Theme.divider)
        }
        .workingSurface()
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(sharedRecoveryText("Scheduled time zone"))
    }
}
