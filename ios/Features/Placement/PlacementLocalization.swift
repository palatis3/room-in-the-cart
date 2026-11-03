import Foundation

enum PlacementCopy {
    static func text(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "Placement") }
    static func money(_ minor: Int?) -> String {
        guard let minor else { return PlacementCopy.text("Unknown") }
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(minor) / 100)) ?? "USD " + NSDecimalNumber(decimal: Decimal(minor) / 100).stringValue
    }
    static func date(_ source: String) -> String {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var value = parser.date(from: source)
        if value == nil { parser.formatOptions = [.withInternetDateTime]; value = parser.date(from: source) }
        return value?.formatted(date: .abbreviated, time: .shortened) ?? source
    }
    static func phase(_ source: String) -> String {
        switch source {
        case "draft": return PlacementCopy.text("Draft")
        case "frozen": return PlacementCopy.text("Frozen for checkout")
        case "placed": return PlacementCopy.text("Reported placed")
        case "closed": return PlacementCopy.text("Closed in the app")
        default: return PlacementCopy.text("Current app state")
        }
    }
    static func scope(_ source: String) -> String {
        switch source {
        case "wholeCheckout": return PlacementCopy.text("Whole checkout")
        case "item": return PlacementCopy.text("Item only")
        case "dinner": return PlacementCopy.text("Dinner only")
        default: return PlacementCopy.text("Unknown scope")
        }
    }
    static func mealKind(_ value: String) -> String {
        switch value {
        case "dinner": return PlacementCopy.text("Dinner")
        case "lunch": return PlacementCopy.text("Lunch")
        case "side": return PlacementCopy.text("Side dish")
        default: return value
        }
    }
    static func outcome(_ source: String) -> String {
        switch source {
        case "placed", "applied": return PlacementCopy.text("Reported placed")
        case "pending_reconciliation": return PlacementCopy.text("Pending shopper reconciliation")
        case "report_rejected", "rejected": return PlacementCopy.text("Report not applied to the app shop")
        default: return PlacementCopy.text("Result needs review")
        }
    }
}
