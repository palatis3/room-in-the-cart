import Foundation
import CoreDomain

struct ReminderCopyRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String

    init?(id: String, title: String?, completed: Bool) {
        guard !completed, let title else { return nil }
        let clean = title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return nil }
        self.id = id
        self.title = clean
    }

    static func pastedTitles(_ values: [String]) throws -> [Self] {
        let text = values.joined(separator: "\n")
        try StagedListImport.validateSourceText(text, maximumLines: StagedListImport.maximumLines)
        return text.components(separatedBy: .newlines).enumerated().compactMap {
            Self(id: String($0.offset), title: $0.element, completed: false)
        }
    }

    static func selectedText(rows: [Self], selected: Set<String>, appendingTo draft: String) throws -> String {
        let titles = rows.filter { selected.contains($0.id) }.map(\.title)
        guard !titles.isEmpty else { throw LedgerError.invalid("reminderSelection") }
        let text = ([draft].filter { !$0.isEmpty } + titles).joined(separator: "\n")
        try StagedListImport.validateSourceText(text, maximumLines: StagedListImport.maximumLines)
        return text
    }
}

/// Calendar receives only this generic, one-time event. The meal identifier is used solely to verify the app route.
struct DinnerCalendarDraft: Equatable {
    let title: String
    let start: Date
    let end: Date
    let timeZone: TimeZone
    let allDay: Bool

    init?(day: MealDay, prepTime: Date?, title: String) {
        guard let noon = day.date, let zone = TimeZone(identifier: day.timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        self.timeZone = zone
        self.title = title
        if let prepTime {
            guard calendar.isDate(prepTime, inSameDayAs: noon) else { return nil }
            start = prepTime
            end = prepTime.addingTimeInterval(30 * 60)
            allDay = false
        } else {
            start = calendar.startOfDay(for: noon)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            end = nextDay
            allDay = true
        }
    }

}
