import Foundation
import HouseholdClient

enum SharedDemandCopy {
    static func text(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "SharedDemand") }
    static func unit(_ value: SharedDemandUnit) -> String {
        switch value {
        case .count: text("count")
        case .gram: text("grams")
        case .kilogram: text("kilograms")
        case .ounce: text("ounces")
        case .pound: text("pounds")
        case .milliliter: text("milliliters")
        case .liter: text("liters")
        case .fluidOunce: text("fluid ounces")
        case .cup: text("cups")
        }
    }
    static func amount(_ value: SharedDemandAmount?) -> String {
        guard let value else { return text("Unknown") }
        return value.denominator == 1 ? String(value.numerator) : "\(value.numerator)/\(value.denominator)"
    }
    static func amount(_ value: SharedDemandAmount?, unit: SharedDemandUnit) -> String {
        guard let value else {
            return String(format: text("Unknown amount (%@)"), Self.unit(unit))
        }
        return "\(amount(value)) \(Self.unit(unit))"
    }
    static func quantity(_ value: SharedDemandQuantity?) -> String {
        guard let value else { return text("Unknown") }
        return "\(amount(value.amount)) \(unit(value.unit))"
    }
    static func source(_ value: SharedDemandSource) -> String {
        switch value {
        case .manual: text("Manual food")
        case .imported: text("Imported food")
        case .request: text("Family request")
        case .meal: text("Meal need")
        case .reservation: text("Protected food")
        }
    }
}
