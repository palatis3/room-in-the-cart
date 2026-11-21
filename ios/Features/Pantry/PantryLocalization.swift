import UIKit
import Foundation
import CoreDomain

@MainActor let pantryReceiptSymbol = UIImage(systemName: "receipt") == nil ? "doc.text" : "receipt"

func pantryText(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "Pantry") }
func pantryFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: pantryText(key), locale: .current, arguments: arguments)
}
func pantryLocationName(_ location: InventoryLocation) -> String {
    switch location { case .cupboard: return pantryText("Cupboard"); case .fridge: return pantryText("Fridge"); case .freezer: return pantryText("Freezer") }
}
func pantryUnit(_ unit: UnitOfMeasure, singular: Bool = false) -> String {
    switch unit {
    case .count: return pantryText(singular ? "unit" : "units")
    case .gram: return pantryText(singular ? "gram" : "grams")
    case .kilogram: return pantryText(singular ? "kilogram" : "kilograms")
    case .ounce: return pantryText(singular ? "ounce by weight" : "ounces by weight")
    case .pound: return pantryText(singular ? "pound" : "pounds")
    case .milliliter: return pantryText(singular ? "milliliter" : "milliliters")
    case .liter: return pantryText(singular ? "liter" : "liters")
    case .fluidOunce: return pantryText(singular ? "fluid ounce" : "fluid ounces")
    case .cup: return pantryText(singular ? "cup" : "cups")
    }
}
private func pantryUnit(_ unit: UnitOfMeasure, amount: Rational?) -> String {
    // A fraction of one unit reads as “1/2 cup” or “1/2 taza” in the supported languages.
    pantryUnit(unit, singular: amount.map { $0 > .zero && $0 <= .one } ?? false)
}
func pantryQuantity(_ quantity: Quantity?) -> String {
    guard let quantity else { return pantryText("Unknown") }
    // The exact fraction and original unit stay intact; no floating-point stock math.
    return "\(quantity.amount.description) \(pantryUnit(quantity.unit, amount: quantity.amount))"
}
func pantryPrintedQuantity(_ literal: String, unit: UnitOfMeasure) -> String {
    let measured = try? ComparisonModel.quantity(literal, unit)
    return literal + " " + pantryUnit(unit, amount: measured?.amount)
}
func pantryCount(_ count: InventoryCount, estimate: String? = nil) -> String {
    if count == .someLeft, let estimate { return pantryFormat("%@ (estimate)", estimate) }
    switch count {
    case .exact(let quantity): return pantryQuantity(quantity)
    case .unknown: return pantryText("Amount unknown")
    case .someLeft: return pantryText("Some left — amount unknown")
    case .haveEnough: return pantryText("Have enough — amount unknown")
    }
}
func pantryPhase(_ phase: PantryModel.Phase) -> String {
    switch phase {
    case .idle: return pantryText("Loading pantry…")
    case .ready: return pantryText("Pantry is ready.")
    case .migrationRequired: return pantryText("Pantry setup needs a review of existing food records. No inventory has been activated here.")
    case .accessDenied: return pantryText("Unlock the authorized private workspace to view pantry food.")
    case .unavailable: return pantryText("Pantry could not be loaded. Refresh to retry; saved records have not been replaced.")
    }
}
func pantryNotice(_ notice: PantryModel.Notice) -> String {
    switch notice {
    case .saved: return pantryText("Food saved on this device.")
    case .saveFailed: return pantryText("Could not confirm the save. Retry the exact reviewed change.")
    case .stale: return pantryText("Food or reservations changed. Refresh and review again before saving.")
    case .loadFailed: return pantryText("Could not load a complete pantry. No partial availability is shown.")
    case .invalidEntry: return pantryText("Check the food name, amount and unit before reviewing.")
    case .insufficientFree: return pantryText("Enter an amount available in this batch after existing reservations.")
    case .partialReleaseInvalid: return pantryText("Enter less than the reserved amount, or choose to release the entire reservation.")
    case .reservationReviewRequired: return pantryText("Review the affected reservations before confirming.")
    case .changeTooLarge: return pantryText("This change is too large to save. Your pantry is unchanged.")
    }
}
