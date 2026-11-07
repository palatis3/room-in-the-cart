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
            .sheet(isPresented: $editing) {
                NavigationStack {
                    SharedMealDeadlinePicker(meal: meal) { deadline in save(deadline); editing = false }
                }
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
    @State private var search = ""

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
        Form {
            LabeledContent(sharedRecoveryText("Scheduled day"), value: sharedMealDayText(meal.day, locale: locale) ?? meal.day)
            NavigationLink {
                List(zones, id: \.self) { zone in
                    ZoneRow(zone: zone, selected: zone == zoneID) { changeZone(zone) }
                }
                .searchable(text: $search)
                .navigationTitle(sharedRecoveryText("Scheduled time zone"))
            } label: {
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
        .navigationTitle(sharedRecoveryText("Meal deadline"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() } } }
    }

    private var zones: [String] {
        Set(TimeZone.knownTimeZoneIdentifiers.filter { $0.contains("/") } + ["UTC",zoneID]).sorted().filter {
            search.isEmpty || $0.localizedCaseInsensitiveContains(search)
        }
    }

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

    private struct ZoneRow: View {
        let zone: String
        let selected: Bool
        let choose: () -> Void
        @Environment(\.dismiss) private var dismiss
        var body: some View {
            Button { choose(); dismiss() } label: {
                if selected { Label(zone, systemImage: "checkmark") } else { Text(verbatim: zone) }
            }
        }
    }
}
