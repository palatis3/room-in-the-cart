import CoreDomain
import SwiftUI

struct GroceryCurrencyPicker: View {
    @Binding var selection: Currency

    var body: some View {
        let title = tr("Currency")
        journalStackedMenu(title, value: name(for: selection), id: "grocery.currency") {
            Picker(title, selection: $selection) {
                ForEach(Currency.allCases, id: \.self) { currency in
                    Text(name(for: currency))
                        .tag(currency)
                        .accessibilityIdentifier("grocery.currency." + currency.rawValue)
                }
            }
            .pickerStyle(.inline)
        }
    }

    private func name(for currency: Currency) -> String {
        switch currency {
        case .usd: tr("US dollars (USD)")
        case .mxn: tr("Mexican pesos (MXN)")
        }
    }
}
