import Foundation

/// The dinner day is a civil date. Subtract calendar days before applying the
/// requested local clock time so an evening reminder stays in the same hour at DST.
public struct DinnerPrepTask: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let shopID: UUID
    public let occurrenceID: UUID
    public let instruction: String
    public let daysBefore: Int
    public let hour: Int
    public let dinnerDay: MealDay
    public var completedAt: Date?

    public init(id: UUID = UUID(), shopID: UUID, occurrenceID: UUID, instruction: String,
                daysBefore: Int, hour: Int, dinnerDay: MealDay) {
        self.id = id; self.shopID = shopID; self.occurrenceID = occurrenceID
        self.instruction = instruction; self.daysBefore = daysBefore; self.hour = hour; self.dinnerDay = dinnerDay
    }

    public func dueDate() throws -> Date {
        try dinnerDay.validate()
        guard (0...7).contains(daysBefore), (0...23).contains(hour),
              let zone = TimeZone(identifier: dinnerDay.timeZoneIdentifier), let noon = dinnerDay.date
        else { throw DinnerPlanningError.invalid("prepTime") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let date = calendar.date(byAdding: .day, value: -daysBefore, to: noon),
              let first = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date, matchingPolicy: .strict, repeatedTimePolicy: .first),
              let last = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date, matchingPolicy: .strict, repeatedTimePolicy: .last),
              first == last, calendar.isDate(first, inSameDayAs: date), calendar.component(.hour, from: first) == hour
        else { throw DinnerPlanningError.reviewRequired("prepTime") }
        return first
    }
    func validate() throws {
        guard !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, instruction.utf8.count <= 512,
              completedAt?.timeIntervalSinceReferenceDate.isFinite != false else { throw DinnerPlanningError.invalid("prepInstruction") }
        _ = try dueDate()
    }
    public func moved(to day: MealDay) -> Self {
        guard completedAt == nil else { return self }
        return .init(id: id, shopID: shopID, occurrenceID: occurrenceID, instruction: instruction,
                     daysBefore: daysBefore, hour: hour, dinnerDay: day)
    }
    public func alertDate(for meal: MealOccurrence, now: Date) -> Date? {
        guard meal.id == occurrenceID, meal.removedAt == nil, meal.scheduledDay == dinnerDay,
              completedAt == nil, let date = try? dueDate(), date > now else { return nil }
        return date
    }
}
