import SwiftUI
import CoreDomain

struct WholePackTripExample: View {
    let currency: Currency
    private static let otherID = UUID(), oilID = UUID()
    private enum Stock: Hashable { case buy, available, unknown }
    @State private var stock = Stock.buy

    var body: some View {
        WorkingForm {
            Section(dinnerText("Fictional sample prices")) {
                let oil = Money(minorUnits: currency == .usd ? 800 : 14000, currency: currency)
                let others = Money(minorUnits: currency == .usd ? 3100 : 62000, currency: currency)
                LabeledContent(dinnerText("Other priced groceries"), value: dinnerMoney(others))
                LabeledContent(dinnerText("One 500 mL bottle of oil"), value: dinnerMoney(oil))
                Text(dinnerText("This recipe needs 15 mL of oil. Buying the bottle leaves 485 mL after cooking."))
                Picker(dinnerText("Usable oil at home"), selection: $stock) {
                    Text(dinnerText("None available")).tag(Stock.buy)
                    Text(dinnerText("At least 15 mL confirmed and free")).tag(Stock.available)
                    Text(dinnerText("Quantity unknown")).tag(Stock.unknown)
                }
                .accessibilityIdentifier("wholePack.example.stock")
                let includedOil: Money? = switch stock {
                case .buy: oil
                case .available: Money(minorUnits: 0, currency: currency)
                case .unknown: nil
                }
                let amounts = try? GroceryCostReview(lines: [(Self.otherID, others), (Self.oilID, includedOil)],
                                                     currency: currency, inventoryComplete: true)
                LabeledContent(dinnerText("Known grocery subtotal"), value: dinnerMoney(amounts?.known))
                    .accessibilityIdentifier("wholePack.example.subtotal")
                if stock == .unknown {
                    Text(dinnerText("Oil is unpriced in this subtotal until you confirm stock or choose to buy the bottle."))
                } else if stock == .available {
                    Text(dinnerText("Confirmed stock covers this recipe. No bottle is added."))
                }
                Text(dinnerText("Taxes and fees are separate."))
            }
        }.navigationTitle(dinnerText("First shop with a whole bottle"))
    }
}
