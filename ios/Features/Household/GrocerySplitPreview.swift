import SwiftUI
import CoreDomain
import HouseholdClient

/// Built exclusively from a current pair returned to this reader by the quote service.
struct GrocerySplitPreview: View {
    struct Item: Identifiable {
        let id: UUID
        let label: String
    }
    let items: [Item]
    let options: EnteredStoreQuoteOptions
    let currency: Currency
    @State private var firstPrices: [UUID: String] = [:]
    @State private var secondPrices: [UUID: String] = [:]
    @State private var secondPicks: Set<UUID> = []
    @State private var travel = ""
    @State private var confirmed = false

    init(pair: StoreQuotePage.Pair, currency: Currency) {
        self.currency = currency
        options = pair.options
        items = pair.commitments.map { Item(id: $0.id, label: $0.label) }
    }
    init(sample currency: Currency) {
        self.currency = currency
        let tortillas = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1))
        let beans = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,2))
        let items = [Item(id: tortillas, label: dinnerText("Tortillas")), Item(id: beans, label: dinnerText("Beans"))]
        self.items = items
        func stop(_ name: String) -> EnteredStoreQuote {
            let supplies = items.map { EnteredCommitmentSupply(commitmentId: $0.id, unit: "count",
                requiredUnits: $0.id == tortillas ? 6 : 1, usableUnitsPerPackage: $0.id == tortillas ? 4 : 1,
                packages: $0.id == tortillas ? 2 : 1) }
            return EnteredStoreQuote(label: name, store: name, branch: name, mode: "inStore", slot: "2026-11-25T12:00:00Z",
                observedAt: "2026-11-25T12:00:00Z", source: dinnerText("Fictional sample prices"), currency: currency.rawValue,
                itemsMinor: nil, checkoutMinor: nil, allChargesIncluded: false, available: true, quantitiesMatched: true,
                singleStore: true, tripAlreadyPlanned: false, tripMinor: nil, extraMinutes: nil, eligibilityConfirmed: true,
                orderMinimum: .init(kind: .noneRequired), supplies: supplies)
        }
        options = .init(first: stop(dinnerText("First store")), second: stop(dinnerText("Second store")))
        _firstPrices = State(initialValue: [tortillas: currency == .usd ? "3" : "55", beans: currency == .usd ? "4" : "70"])
        _secondPrices = State(initialValue: [tortillas: currency == .usd ? "2" : "40", beans: currency == .usd ? "5" : "80"])
        _secondPicks = State(initialValue: [tortillas])
    }
    private func pack(_ item: UUID, _ quote: EnteredStoreQuote) -> StoreCommitmentSupply? {
        let rows = quote.supplies?.filter { $0.commitmentId == item } ?? []
        guard rows.count == 1, let row = rows.first, let value = try? row.reviewedSupply(),
              (try? value.surplus()).map({ $0 >= 0 }) == true else { return nil }
        return value
    }
    private func supplies(_ item: UUID) -> (StoreCommitmentSupply?, StoreCommitmentSupply?) {
        let a = pack(item, options.first), b = pack(item, options.second)
        return (a, a?.unit == b?.unit && a?.requiredUnits == b?.requiredUnits ? b : nil)
    }
    private func applicable(_ quote: EnteredStoreQuote) -> Bool {
        quote.available == true && quote.quantitiesMatched && quote.singleStore &&
            quote.eligibilityConfirmed && quote.orderMinimum?.kind == .noneRequired
    }
    private var result: GroceryStoreSplit? {
        let rows = items.map { item in
            let (a,b) = supplies(item.id)
            func cost(_ pack: StoreCommitmentSupply?, _ value: String?) -> Money? {
                guard let pack, let price = try? DinnerEntry.money(value ?? "", currency: currency),
                      price.minorUnits >= 0 else { return nil }
                return try? price.multiplied(by: pack.packages)
            }
            return GroceryStoreSplit.Line(id: item.id, first: cost(a, firstPrices[item.id]),
                second: cost(b, secondPrices[item.id]), secondStop: secondPicks.contains(item.id))
        }
        return try? GroceryStoreSplit(lines: rows, currency: currency,
            travel: try DinnerEntry.money(travel, currency: currency),
            conditionsConfirmed: confirmed && applicable(options.first) && applicable(options.second))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(dinnerText("Choose each stop and enter its observed price per pack. Travel is the extra cost of adding the second stop."))
            ForEach(items) { item in
                let (a,b) = supplies(item.id)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.label).font(.headline)
                    stopRow(a, quote: options.first, text: priceField($firstPrices, item.id))
                    stopRow(b, quote: options.second, text: priceField($secondPrices, item.id))
                    Toggle(dinnerFormat("Buy at %@", options.second.label), isOn: Binding(get: { secondPicks.contains(item.id) }, set: {
                        if $0 { secondPicks.insert(item.id) } else { secondPicks.remove(item.id) }
                        confirmed = false
                    }))
                }
            }
            TextField(dinnerFormat("Extra travel cost in %@", currency.rawValue), text: $travel).keyboardType(.decimalPad)
            Toggle(dinnerText("I checked the prices and promotion conditions for this exact allocation."), isOn: $confirmed)
            if !applicable(options.first) || !applicable(options.second) {
                Text(dinnerText("Store availability, minimums or price conditions still need review."))
            }
            if let result {
                amount(dinnerText("All groceries at the first store"), result.single)
                amount(options.first.label, result.firstStop)
                amount(options.second.label, result.secondStop)
                amount(dinnerText("Groceries across both stores"), result.split)
                LabeledContent(dinnerText("Change including extra travel"), value: dinnerMoney(result.changeWithTravel))
                Text(dinnerText("Grocery and travel estimates exclude checkout taxes and fees."))
            } else { Text(dinnerText("Review the entered prices and travel cost.")) }
        }
        .onChange(of: firstPrices) { _, _ in confirmed = false }
        .onChange(of: secondPrices) { _, _ in confirmed = false }
        .privacySensitive()
    }
    private func priceField(_ prices: Binding<[UUID: String]>, _ id: UUID) -> Binding<String> {
        Binding(get: { prices.wrappedValue[id] ?? "" }, set: { prices.wrappedValue[id] = $0 })
    }

    @ViewBuilder private func stopRow(_ pack: StoreCommitmentSupply?, quote: EnteredStoreQuote, text: Binding<String>) -> some View {
        let date = serviceDate(quote.observedAt)?.formatted(date: .abbreviated, time: .shortened) ?? quote.observedAt
        Text(verbatim: [quote.store, quote.branch, quote.source, date, quote.terms].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline)
        if let pack, let surplus = try? pack.surplus() {
            Text(dinnerFormat("%lld packs × %lld %@ · %lld left", pack.packages, pack.usableUnitsPerPackage, dinnerUnit(pack.unit), surplus))
            TextField(dinnerFormat("Price per pack in %@", currency.rawValue), text: text).keyboardType(.decimalPad)
        } else { Text(dinnerText("No matching whole-pack observation for this requirement.")) }
    }
    private func amount(_ title: String, _ cost: GroceryCostReview) -> some View {
        LabeledContent(title, value: dinnerMoney(cost.known) + " · " + dinnerFormat("%d unpriced", cost.unpriced.count))
    }
}
