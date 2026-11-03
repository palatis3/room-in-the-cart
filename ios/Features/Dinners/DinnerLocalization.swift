import Foundation
import CoreDomain

func dinnerText(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "Dinners") }
func dinnerFormat(_ key: String, _ arguments: CVarArg...) -> String { String(format: dinnerText(key), locale: .current, arguments: arguments) }
func dinnerQuantity(_ quantity: Quantity?) -> String {
    guard let quantity else { return dinnerText("Quantity unresolved") }
    return "\(quantity.amount.description) \(dinnerUnit(quantity.unit))"
}
func dinnerUnit(_ unit: UnitOfMeasure) -> String {
    switch unit {
    case .count: return dinnerText("count")
    case .gram: return dinnerText("grams")
    case .kilogram: return dinnerText("kilograms")
    case .ounce: return dinnerText("ounces by weight")
    case .pound: return dinnerText("pounds")
    case .milliliter: return dinnerText("milliliters")
    case .liter: return dinnerText("liters")
    case .fluidOunce: return dinnerText("fluid ounces")
    case .cup: return dinnerText("cups")
    }
}
func dinnerDay(_ day: MealDay) -> String {
    guard let date = day.date else { return day.iso8601 }
    let formatter = DateFormatter(); formatter.locale = .current; formatter.timeZone = TimeZone(identifier: day.timeZoneIdentifier)
    formatter.dateStyle = .full; formatter.timeStyle = .none
    return "\(formatter.string(from: date)) · \(day.timeZoneIdentifier)"
}
func dinnerMoney(_ money: Money?) -> String {
    guard let money else { return dinnerText("Unresolved") }
    let formatter = NumberFormatter(); formatter.numberStyle = .currency; formatter.currencyCode = money.currency.rawValue
    return formatter.string(from: NSDecimalNumber(value: money.minorUnits).dividing(by: 100)) ?? "\(money.minorUnits) USD cents"
}
func dinnerIssue(_ issue: String) -> String {
    // Domain issues are closed product strings. Unknown internal diagnostics are
    // deliberately not surfaced as untranslated or privacy-sensitive text.
    switch issue {
    case "Correct invalid or excluded ingredients", "Review ingredients", "Review unknown ingredient quantities",
         "Usable yield is unconfirmed", "Availability is unconfirmed", "Compare complete single-store plans for the same commitments and scope",
         "Required product availability is unknown or unavailable", "Checkout terms are incomplete", "Total trip cash is unresolved": return dinnerText(issue)
    default: return dinnerText("Review the entered evidence before continuing.")
    }
}
