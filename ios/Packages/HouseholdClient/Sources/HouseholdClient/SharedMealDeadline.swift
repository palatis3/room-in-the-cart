import Foundation

/// An explicitly reviewed instant and its scheduling zone, separate from the civil menu date.
public struct SharedMealDeadline: Codable, Equatable, Sendable {
    public let at: String
    public let zone: String

    public init(at: String, zone: String) {
        self.at = at
        self.zone = zone
    }

    public var timeZone: TimeZone? {
        guard zone.utf8.count <= 100,
              zone == "UTC" || zone == "GMT" || zone.range(of: #"^[A-Za-z][A-Za-z0-9_+.\-]*(/[A-Za-z0-9_+.\-]+)+$"#, options: .regularExpression) != nil else { return nil }
        return TimeZone(identifier: zone)
    }

    public var instant: Date? {
        guard at.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$"#, options: .regularExpression) != nil else { return nil }
        let civil = DateFormatter()
        civil.locale = Locale(identifier: "en_US_POSIX")
        civil.calendar = Calendar(identifier: .gregorian)
        civil.timeZone = TimeZone(secondsFromGMT: 0)
        civil.dateFormat = "yyyy-MM-dd"; civil.isLenient = false
        let prefix = String(at.prefix(10))
        guard let date = civil.date(from: prefix), civil.string(from: date) == prefix else { return nil }
        return householdTimestamp(at)
    }

    public func validate(day: String) throws {
        guard let instant, let timeZone else { throw ClientError.configuration }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: instant)
        guard let year = components.year, let month = components.month, let number = components.day,
              String(format: "%04d-%02d-%02d", year, month, number) == day else { throw ClientError.configuration }
    }

    public func display(locale: Locale) -> String? {
        guard let instant, let timeZone else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timeZone
        formatter.dateStyle = .long; formatter.timeStyle = .short
        let offset = timeZone.secondsFromGMT(for: instant)
        let hours = abs(offset) / 3600, minutes = abs(offset) % 3600 / 60
        let utcOffset = String(format: "UTC%@%02d:%02d", offset < 0 ? "−" : "+", hours, minutes)
        return formatter.string(from: instant) + " · " + zone + " (" + utcOffset + ")"
    }
}

extension SharedMeal {
    /// Date-only moves leave the time unknown until a shopper enters the new deadline.
    public mutating func move(to newDay: String) {
        if day != newDay { planning?.deadline = nil }
        day = newDay
    }

    public mutating func setDeadline(_ deadline: SharedMealDeadline?) throws {
        try deadline?.validate(day: day)
        if let deadline, planning == nil { planning = .init(groups: [], ingredients: [], deadline: deadline) }
        else { planning?.deadline = deadline }
    }
}
