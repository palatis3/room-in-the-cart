import Foundation
import CoreDomain

func dinnerText(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "Dinners") }
func dinnerFormat(_ key: String, _ arguments: CVarArg...) -> String { String(format: dinnerText(key), locale: .current, arguments: arguments) }
func dinnerQuantity(_ quantity: Quantity?) -> String {
    guard let quantity else { return dinnerText("Quantity unresolved") }
    let unit = quantity.unit == .count && quantity.amount != .one ? dinnerText("units") : dinnerUnit(quantity.unit, singular: quantity.amount == .one)
    return "\(quantity.amount.description) \(unit)"
}
func dinnerUnit(_ unit: UnitOfMeasure, singular: Bool = false) -> String {
    switch unit {
    case .count: return singular ? dinnerText("unit") : dinnerText("count")
    case .gram: return singular ? dinnerText("gram") : dinnerText("grams")
    case .kilogram: return singular ? dinnerText("kilogram") : dinnerText("kilograms")
    case .ounce: return singular ? dinnerText("ounce by weight") : dinnerText("ounces by weight")
    case .pound: return singular ? dinnerText("pound") : dinnerText("pounds")
    case .milliliter: return singular ? dinnerText("milliliter") : dinnerText("milliliters")
    case .liter: return singular ? dinnerText("liter") : dinnerText("liters")
    case .fluidOunce: return singular ? dinnerText("fluid ounce") : dinnerText("fluid ounces")
    case .cup: return singular ? dinnerText("cup") : dinnerText("cups")
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

func dinnerCap(_ assessment: CheckoutCapAssessment) -> String {
    switch assessment {
    case .notProvided: return dinnerText("No cap supplied")
    case .scopeMismatch: return dinnerText("The cap covers a different scope; no whole-shop headroom is claimed.")
    case .unresolved: return dinnerText("Cap headroom is unresolved")
    case .within(_, let headroom): return dinnerFormat("Minimum cap headroom: %@", dinnerMoney(headroom))
    case .over(_, let overage): return dinnerFormat("Minimum amount over cap: %@", dinnerMoney(overage))
    }
}

func dinnerBudgetScope(_ scope: BudgetScope) -> String {
    switch scope {
    case .wholeShop: return dinnerText("Whole pickup")
    case .dinnersOnly: return dinnerText("Dinners only")
    case .selectedItems: return dinnerText("Selected items only")
    }
}
