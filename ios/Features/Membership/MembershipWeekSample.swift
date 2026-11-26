import CoreDomain
import SwiftUI

struct MembershipWeekSample: View {
    let currency: Currency
    @State private var keepTuesday = true
    @State private var keepThursday = true

    var body: some View {
        WorkingForm {
            Section {
                Text(mtr("Try changing a sample week. Wednesday needs 400 g of rice. Tuesday and Thursday each need 300 g."))
                Toggle(mtr("Cook on Tuesday"), isOn: $keepTuesday)
                Toggle(mtr("Cook on Thursday"), isOn: $keepThursday)
            }
            Section {
                Text(mtr("Of the 500 g at home, 200 g are saved for lunch."))
                if let basket = try? DinnerBasketSample.changedWeek(currency: currency, keepTuesday: keepTuesday, keepThursday: keepThursday) {
                    LabeledContent(mtr("500 g rice packs to buy"), value: basket.packs.formatted())
                        .accessibilityIdentifier("membership.weekSample.packs")
                    LabeledContent(mtr("Known grocery subtotal"), value: moneyText(basket.riceCost))
                    Text(mtr("The coffee you added stays on the list. Its price is still unknown."))
                        .foregroundStyle(Theme.secondary)
                } else {
                    Text(mtr("The sample could not be calculated."))
                }
            }
        }
        .navigationTitle(mtr("Change a sample week"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
