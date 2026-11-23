import CoreDomain
import SwiftUI

struct GroceryCurrencyPicker: View {
    @Binding var selection: Currency

    var body: some View {
        Picker(tr("Currency"), selection: $selection) {
            Text(tr("US dollars (USD)"))
                .tag(Currency.usd)
                .accessibilityIdentifier("grocery.currency.USD")
            Text(tr("Mexican pesos (MXN)"))
                .tag(Currency.mxn)
                .accessibilityIdentifier("grocery.currency.MXN")
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("grocery.currency")
    }
}
