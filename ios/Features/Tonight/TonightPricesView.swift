import SwiftUI
import CoreDomain

struct TonightPricesView: View {
    let estimate: TonightPurchaseEstimate?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let estimate, let subtotal = estimate.subtotal {
                LabeledContent(tonightText(estimate.complete ? "Estimated additional groceries" : "Priced groceries so far"),
                               value: dinnerMoney(subtotal))
                ForEach(estimate.packages) { line in
                    Text(verbatim: "\(line.package) × \(line.count.formatted()) · \(dinnerMoney(line.cost))")
                    Text(verbatim: "\(line.source) · \(line.observedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                }
                if estimate.packages.isEmpty {
                    Text(tonightText("Confirmed pantry food covers these recipe amounts."))
                } else {
                    Text(tonightText("Based on observed package prices. Check current prices, fees and taxes at checkout."))
                }
            }
            if estimate?.complete != true {
                Text(tonightText("Some amounts or package prices still need review."))
            }
        }
        .accessibilityIdentifier("tonight.purchaseEstimate")
    }
}
