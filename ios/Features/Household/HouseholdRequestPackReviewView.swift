import SwiftUI
import CoreDomain

private struct RequestPackDraft: Equatable {
    let id = UUID().uuidString
    var label = ""
    var usable = ""
    var unit: UnitOfMeasure = .count
    var price = ""
    var availability: RequestPackAvailability = .unknown
    var limit = ""
    var matched = false
    var feeEligible = true
    var source = ""
    var observedAt = Date()
    @MainActor func candidate() throws -> HouseholdRequestPackCandidate {
        let quantity = try requestPackQuantity(usable, unit: unit)
        let price = try HouseholdInboxModel.priceMinor(price).map { Money(minorUnits: Int64($0)) }
        let maximum: Int?
        if limit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { maximum = nil }
        else { guard let value = Int(limit), value >= 0 else { throw RequestPackError.invalid }; maximum = value }
        return HouseholdRequestPackCandidate(id: id, label: label.trimmingCharacters(in: .whitespacesAndNewlines), usable: quantity, price: price,
            availability: availability, availablePacks: maximum, matchesRequest: matched,
            feeEligible: feeEligible, source: source, observedAt: observedAt)
    }
}
private func requestPackQuantity(_ text: String, unit: UnitOfMeasure) throws -> Quantity? {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    return Quantity(amount: try Rational(decimal: cleaned.replacingOccurrences(of: ",", with: ".")), unit: unit, originalLiteral: text)
}

struct HouseholdRequestPackReviewView: View {
    @ObservedObject var model: HouseholdInboxModel
    @State private var expanded = false
    @State private var needed = ""
    @State private var unit: UnitOfMeasure = .count
    @State private var first = RequestPackDraft()
    @State private var second = RequestPackDraft()
    @State private var comparison: HouseholdRequestPackComparison?
    @State private var reviewedScope: HouseholdRequestPackScope?
    @State private var failure = false
    var body: some View {
        DisclosureGroup(ht("Compare available packs for this request"), isExpanded: $expanded) {
            Text(ht("Enter the usable amount needed for this request. Matching names do not prove that a product or yield is suitable."))
            Text(ht("Reviewed usable amount needed")).font(.caption)
            TextField(ht("Reviewed usable amount needed"), text: $needed).keyboardType(.decimalPad).accessibilityIdentifier("household.pack.need")
            Picker(ht("Need unit"), selection: $unit) { ForEach(UnitOfMeasure.allCases, id: \.self) { Text($0.displayName).tag($0) } }
            candidateFields($first, index: "a")
            candidateFields($second, index: "b")
            Button(ht("Review available pack comparison")) { compare() }.accessibilityIdentifier("household.pack.compare")
            if let comparison, let scope = reviewedScope {
                Text(ht("Item quantities and prices only. The household preview below checks the complete checkout separately."))
                Text("\(ht("Reviewed need")): \(pQuantity(comparison.needed))")
                if comparison.hasUnresolvedAlternatives { Text(ht("Some alternatives remain unresolved. A cheapest known option is not a cheapest overall claim.")) }
                ForEach(comparison.results) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.candidate.label).font(.headline)
                        Text("\(ht("Price source")): \(row.candidate.source)")
                        Text(row.candidate.observedAt.formatted())
                        Text("\(ht("Usable per pack")): \(row.candidate.usable.map { pQuantity($0) } ?? ht("Unknown"))")
                        LabeledContent(ht("Whole packs needed"), value: row.calculation.packsToBuy.map(String.init) ?? ht("Unknown"))
                        LabeledContent(ht("Price per pack"), value: householdMoney(row.candidate.price.map { Int($0.minorUnits) }, currency: "USD"))
                        LabeledContent(ht("Pack purchase total"), value: householdMoney(row.calculation.totalCost.map { Int($0.minorUnits) }, currency: "USD"))
                        if comparison.cheapestIDs.contains(row.id) { Text(ht("Cheapest sufficient option among reviewed available packs with known prices")).accessibilityIdentifier("household.pack.cheapest") }
                        if !row.candidate.matchesRequest { Text(ht("Product match has not been confirmed.")) }
                        if !row.available { Text(ht("Availability is unknown or insufficient for the required whole packs.")) }
                        if row.calculation.issues.contains(.usableQuantityUnknown) || row.calculation.issues.contains(.usableConversionUnknown) || row.calculation.issues.contains(.noUsableYield) { Text(ht("Usable yield or unit conversion is unresolved.")) }
                        Button(ht("Use this reviewed pack in the decision")) {
                            do {
                                let selection = try HouseholdRequestPackReview.select(row, needed: comparison.needed, scope: scope)
                                failure = !model.usePackSelection(selection)
                                if !failure { expanded = false }
                            } catch { failure = true }
                        }.disabled(!row.canSelect || model.busy || model.packReviewScope != scope)
                            .accessibilityIdentifier(row.id == first.id ? "household.pack.use.a" : "household.pack.use.b")
                    }
                }
            }
            if failure { Text(ht("Review the need, units, pack labels, source, availability, and prices. The decision has not changed.")) }
        }
        .onChange(of: needed) { _, _ in reset() }.onChange(of: unit) { _, _ in reset() }
        .onChange(of: first) { old, new in
            #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
            S24PackTrace.emit("change", pack: "a", oldID: old.id, newID: new.id, old: old.matched, new: new.matched)
            #endif
            reset()
        }.onChange(of: second) { old, new in
            #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
            S24PackTrace.emit("change", pack: "b", oldID: old.id, newID: new.id, old: old.matched, new: new.matched)
            #endif
            reset()
        }
        .onChange(of: model.packReviewScope) { _, _ in reset() }
        #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
        .onAppear { traceLifecycle("appear") }
        .onDisappear { traceLifecycle("disappear") }
        #endif
    }
    @ViewBuilder private func candidateFields(_ draft: Binding<RequestPackDraft>, index: String) -> some View {
        Text(ht(index == "a" ? "Pack A" : "Pack B")).font(.headline)
        Text(ht("Reviewed pack label")).font(.caption)
        TextField(ht("Reviewed pack label"), text: draft.label).accessibilityIdentifier("household.pack.\(index).label")
        Text(ht("Usable amount in one pack, blank if unknown")).font(.caption)
        TextField(ht("Usable amount in one pack, blank if unknown"), text: draft.usable).keyboardType(.decimalPad).accessibilityIdentifier("household.pack.\(index).usable")
        Picker(ht("Pack usable unit"), selection: draft.unit) { ForEach(UnitOfMeasure.allCases, id: \.self) { Text($0.displayName).tag($0) } }
        Text(ht("Price per pack in USD, blank if unknown")).font(.caption)
        TextField(ht("Price per pack in USD, blank if unknown"), text: draft.price).keyboardType(.decimalPad).accessibilityIdentifier("household.pack.\(index).price")
        Picker(ht("Reviewed availability"), selection: draft.availability) {
            Text(ht("Available")).tag(RequestPackAvailability.confirmed)
            Text(ht("Unavailable")).tag(RequestPackAvailability.unavailable)
            Text(ht("Unknown")).tag(RequestPackAvailability.unknown)
        }.accessibilityIdentifier("household.pack.\(index).availability")
        Text(ht("Available pack limit, blank if unlimited confirmed")).font(.caption)
        TextField(ht("Available pack limit, blank if unlimited confirmed"), text: draft.limit).keyboardType(.numberPad)
        Text(ht("Price source")).font(.caption)
        TextField(ht("Price source"), text: draft.source).accessibilityIdentifier("household.pack.\(index).source")
        DatePicker(ht("Price observed"), selection: draft.observedAt)
        Toggle(ht("I confirmed this pack matches the request and intended use"), isOn: matchedBinding(draft, index: index)).accessibilityIdentifier("household.pack.\(index).matched")
        Toggle(ht("Counts toward the retailer fee threshold"), isOn: draft.feeEligible)
    }
    private func matchedBinding(_ draft: Binding<RequestPackDraft>, index: String) -> Binding<Bool> {
        #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
        if S24PackTrace.enabled {
            let original = draft.matched
            return Binding(get: { original.wrappedValue }, set: { requested, transaction in
                let before = draft.wrappedValue
                S24PackTrace.emit("setter-enter", pack: index, oldID: before.id, newID: before.id, old: before.matched, new: requested)
                original.transaction(transaction).wrappedValue = requested
                let after = draft.wrappedValue
                S24PackTrace.emit("setter-return", pack: index, oldID: before.id, newID: after.id, old: before.matched, new: after.matched)
            })
        }
        #endif
        return draft.matched
    }
    #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
    private func traceLifecycle(_ event: String) {
        S24PackTrace.emit(event, pack: "a", oldID: first.id, newID: first.id, old: first.matched, new: first.matched)
        S24PackTrace.emit(event, pack: "b", oldID: second.id, newID: second.id, old: second.matched, new: second.matched)
    }
    #endif
    private func reset() { comparison = nil; reviewedScope = nil; failure = false }
    private func compare() {
        do {
            guard let scope = model.packReviewScope, let need = try requestPackQuantity(needed, unit: unit) else { throw RequestPackError.invalid }
            comparison = try HouseholdRequestPackReview.calculate(needed: need, candidates: [first.candidate(), second.candidate()])
            reviewedScope = scope; failure = false
        } catch { comparison = nil; reviewedScope = nil; failure = true }
    }
}

struct HouseholdChosenPackSummary: View {
    let selection: HouseholdRequestPackSelection
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ht("Reviewed pack used by this decision")).font(.headline)
            Text(selection.line.originalItem)
            Text("\(ht("Reviewed need")): \(pQuantity(selection.needed))")
            Text("\(ht("Usable per pack")): \(selection.candidate.usable.map { pQuantity($0) } ?? ht("Unknown"))")
            Text("\(ht("Price source")): \(selection.candidate.source) · \(selection.candidate.observedAt.formatted())")
            LabeledContent(ht("Whole packs"), value: selection.line.packs.formatted())
            LabeledContent(ht("Price per pack"), value: householdMoney(selection.line.unitPriceMinor, currency: "USD"))
            Text(ht("Selecting a pack only prepares the decision. Review and apply the household preview to change the plan."))
        }.accessibilityIdentifier("household.pack.selected")
    }
}
