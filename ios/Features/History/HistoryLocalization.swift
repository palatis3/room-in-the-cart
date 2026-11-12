import Foundation
import HouseholdClient

enum HistoryCopy {
    static func text(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "History") }
    static func money(_ minor: Int) -> String {
        let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: Decimal(minor) / 100)) ?? "USD " + NSDecimalNumber(decimal: Decimal(minor) / 100).stringValue
    }
    static func date(_ source: String, timeZoneID: String? = nil) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var value = formatter.date(from: source)
        if value == nil { formatter.formatOptions = [.withInternetDateTime]; value = formatter.date(from: source) }
        guard let value else { return source }
        let display = DateFormatter(); display.dateStyle = .medium; display.timeStyle = .short
        if let timeZoneID, let zone = TimeZone(identifier: timeZoneID) { display.timeZone = zone }
        return display.string(from: value)
    }
    static func range(_ value: HistoryMoneyRange) -> String {
        money(value.lowerMinor) + " – " + (value.upperMinor.map(money) ?? HistoryCopy.text("Unknown upper bound"))
    }
    static func shop(_ value: HistoryOwnedShop) -> String {
        HistoryCopy.text("Assigned shop") + " · " + date(value.createdAt) + " · " + phase(value.phase) + " · " + String(value.shopId.suffix(8))
    }
    static func phase(_ value: String, bundle: Bundle = .main) -> String {
        let key = switch value {
        case "draft": "Draft"
        case "frozen": "Frozen"
        case "closed": "Closed"
        case "placed": "Placed"
        default: "Assigned shop"
        }
        return bundle.localizedString(forKey: key, value: key, table: "History")
    }
    static func channel(_ value: String, bundle: Bundle = .main) -> String {
        let key = switch value {
        case "storeShelf": "Store shelf"
        case "warehouse": "Warehouse"
        case "retailerWebsite": "Retailer website"
        case "retailerApp": "Retailer app"
        case "other": "Other channel"
        default: "Unspecified channel"
        }
        return bundle.localizedString(forKey: key, value: key, table: "History")
    }
    static func mode(_ value: String, bundle: Bundle = .main) -> String {
        let key = switch value {
        case "pickup": "Pickup"
        case "delivery": "Delivery"
        default: "In store"
        }
        return bundle.localizedString(forKey: key, value: key, table: "History")
    }
    static func unit(_ value: String) -> String {
        switch value {
        case "count": return HistoryCopy.text("Count")
        case "gram": return HistoryCopy.text("Gram")
        case "kilogram": return HistoryCopy.text("Kilogram")
        case "ounce": return HistoryCopy.text("Mass ounce")
        case "pound": return HistoryCopy.text("Pound")
        case "milliliter": return HistoryCopy.text("Milliliter")
        case "liter": return HistoryCopy.text("Liter")
        case "fluidOunce": return HistoryCopy.text("Fluid ounce")
        case "cup": return HistoryCopy.text("Cup")
        default: return value
        }
    }
    static func reservationState(_ value: String) -> String {
        switch value {
        case "applied": return HistoryCopy.text("Applied to an assigned shop")
        case "released": return HistoryCopy.text("Released from this plan")
        default: return HistoryCopy.text("Reserved for a future shop")
        }
    }
}
