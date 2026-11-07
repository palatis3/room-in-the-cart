import CoreDomain
import HouseholdClient
import SwiftUI

private enum DeliveryForm: Identifiable {
    case register(SharedDeliveryPage.Line)
    case arrival(SharedDeliveryPage.Source)
    case usable(SharedDeliveryPage.Source)

    var id: String {
        switch self {
        case .register(let line): return "line." + line.id.uuidString
        case .arrival(let source): return "arrival." + source.id.uuidString
        case .usable(let source): return "usable." + source.id.uuidString
        }
    }
    var title: String {
        switch self {
        case .register: return ht("Add a delivery")
        case .arrival: return ht("Record arrival")
        case .usable: return ht("Record usable quantity")
        }
    }
}

func deliveryQuantityText(_ value: SharedMealQuantity?) -> String {
    guard let value, let unit = UnitOfMeasure(rawValue: value.unit),
          let amount = try? Rational(Int64(value.amount.numerator), Int64(value.amount.denominator)) else { return dinnerText("Quantity unresolved") }
    return dinnerQuantity(.init(amount: amount, unit: unit, originalLiteral: value.originalLiteral))
}

struct SharedDeliveryView: View {
    @ObservedObject var model: HouseholdShopModel
    let shopID: String
    @State private var form: DeliveryForm?
    @State private var choosingLine = false
    @State private var showingCoverage = false
    @State private var matchingSource: SharedDeliveryPage.Source?

    var body: some View {
        Form {
            if model.canReadDelivery, model.scope.shopId == shopID {
                if let page = model.deliveryRecord, page.shopId == UUID(uuidString: shopID) {
                    if model.shop?.phase == "placed", model.pending == nil, !page.lines.isEmpty {
                        Button(ht("Add a delivery")) { choosingLine = true }
                    }
                    if page.coverageAvailable == true, page.meals?.isEmpty == false {
                        Button(ht("Delivered food by meal")) { showingCoverage = true }
                    }
                    if page.sources.isEmpty { Text(ht("No deliveries recorded yet.")) }
                    ForEach(page.sources) { source in
                        Section {
                            if let line = page.lines.first(where: { $0.id == source.lineId }) {
                                LabeledContent(ht("Ordered item"), value: line.name)
                            }
                            LabeledContent(ht("Delivery reference"), value: String(source.segmentKey.uuidString.prefix(8)))
                            if !source.exclusionTags.isEmpty { Text(source.exclusionTags.joined(separator: ", ")) }
                            LabeledContent(ht("Arrival time"), value: source.arrival?.arrivedAt.flatMap(serviceDate)?.formatted() ?? ht("Unknown"))
                            LabeledContent(ht("Received quantity"), value: deliveryQuantityText(source.arrival?.received))
                            LabeledContent(ht("Confirmed usable quantity"), value: deliveryQuantityText(source.confirmed?.quantity))
                                .accessibilityIdentifier("delivery.confirmed." + source.id.uuidString)
                            if source.usable != nil, source.usable?.arrivalObservationId != source.arrival?.observationId {
                                Text(ht("The arrival changed. Check the usable quantity again."))
                            }
                            if model.shop?.phase == "placed", model.pending == nil {
                                Button(ht("Record arrival")) { form = .arrival(source) }
                                if source.arrival != nil {
                                    Button(ht("Record usable quantity")) { form = .usable(source) }
                                }
                            }
                            if source.matches != nil, page.meals?.contains(where: { $0.meal.planning?.ingredients.isEmpty == false }) == true {
                                Button(ht("Meal ingredient matches")) { matchingSource = source }
                            }
                        } header: { Text(source.foodName) }
                    }
                }
                Button(ht("Refresh deliveries")) { Task { await refresh() } }
                if let message = model.notice { Text(message) }
                if model.busy { ProgressView() }
            } else { Text(ht("Shared shop access has ended. Return to household settings.")) }
        }
        .navigationTitle(ht("What came home"))
        .disabled(model.busy)
        .task { await model.loadDelivery() }
        .sheet(isPresented: $choosingLine) {
            if model.canReadDelivery, model.scope.shopId == shopID, let page = model.deliveryRecord {
                SharedDeliveryRegistration(model: model, page: page)
            }
        }
        .sheet(isPresented: $showingCoverage) {
            if model.canReadDelivery, model.scope.shopId == shopID, let page = model.deliveryRecord {
                SharedDeliveryCoverageView(model: model, page: page)
            }
        }
        .sheet(item: $matchingSource) { source in
            if model.canReadDelivery, model.scope.shopId == shopID, let page = model.deliveryRecord {
                DeliveryMealMatches(model: model, source: source, page: page)
            }
        }
        .sheet(item: $form) { action in
            if model.canReadDelivery, model.scope.shopId == shopID, let page = model.deliveryRecord {
                SharedDeliveryEditor(model: model, action: action, page: page)
            }
        }
    }

    private func refresh() async {
        await model.load()
        await model.loadDelivery()
    }
}

private struct DeliveryMealMatches: View {
    @ObservedObject var model: HouseholdShopModel
    let source: SharedDeliveryPage.Source
    @State private var reviewed: SharedDeliveryPage
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    init(model: HouseholdShopModel, source: SharedDeliveryPage.Source, page: SharedDeliveryPage) {
        self.model = model
        self.source = source
        _reviewed = State(initialValue: page)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(reviewed.meals ?? []) { occurrence in
                    if let plan = occurrence.meal.planning, !plan.ingredients.isEmpty {
                        Section {
                            ForEach(plan.ingredients) { ingredient in
                                let target = SharedDeliveryPage.IngredientMatch(occurrence: occurrence, ingredient: ingredient)
                                let matched = source.matches?.contains(target) == true
                                NavigationLink {
                                    Form {
                                        LabeledContent(ht("Food that came home"), value: source.foodName)
                                        LabeledContent(ht("Confirmed usable quantity"), value: deliveryQuantityText(source.confirmed?.quantity))
                                        if !source.exclusionTags.isEmpty {
                                            LabeledContent(ht("Delivery exclusions"), value: source.exclusionTags.joined(separator: ", "))
                                        }
                                        Section(occurrence.meal.title) {
                                            Text(verbatim: occurrence.meal.day)
                                            LabeledContent(ht("Ingredient quantity"), value: deliveryQuantityText(ingredient.quantity))
                                            if !ingredient.exclusions.isEmpty {
                                                LabeledContent(ht("Ingredient exclusions"), value: ingredient.exclusions.joined(separator: ", "))
                                            }
                                            ForEach(plan.groups.filter { ingredient.groupIds.contains($0.id) }) { group in
                                                if group.protected || occurrence.meal.protected {
                                                    Label(group.name, systemImage: "lock").accessibilityLabel(group.name + ", " + ht("Protected portions"))
                                                } else { Text(group.name) }
                                                let binding = plan.bindings?.first { $0.ingredientId == ingredient.id && $0.groupId == group.id }
                                                let quantity = binding?.quantity ?? (ingredient.groupIds.count == 1 ? ingredient.quantity : nil)
                                                LabeledContent(ht("Reserved for group"), value: deliveryQuantityText(quantity))
                                            }
                                        }
                                        if model.shop?.phase == "placed", model.pending == nil {
                                            Section {
                                                Button(matched ? ht("Remove ingredient match") : ht("Match this ingredient")) {
                                                    Task { await save(target, matched: !matched) }
                                                }
                                                .disabled(model.busy)
                                            } footer: { Text(ht("Matching identifies the food. Portions are reserved separately.")) }
                                        }
                                        if let error { Text(error) }
                                    }
                                    .navigationTitle(ingredient.name)
                                } label: {
                                    if matched { Label(ingredient.name, systemImage: "checkmark.circle").accessibilityValue(ht("Matched")) }
                                    else { Text(ingredient.name) }
                                }
                            }
                        } header: { Text(occurrence.meal.title + " · " + occurrence.meal.day) }
                    }
                }
            }
            .navigationTitle(ht("Meal ingredient matches"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() } } }
        }
        .interactiveDismissDisabled(model.busy)
    }

    private func save(_ target: SharedDeliveryPage.IngredientMatch, matched: Bool) async {
        if await model.saveDelivery(.match(source: source.id, ingredient: target, matched: matched), reviewed: reviewed) {
            dismiss()
            if model.pending == nil { await model.loadDelivery() }
        } else { error = model.notice ?? ht("Refresh deliveries and review the current record.") }
    }
}

private struct SharedDeliveryRegistration: View {
    @ObservedObject var model: HouseholdShopModel
    let page: SharedDeliveryPage
    @State private var line: SharedDeliveryPage.Line?
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if let line {
            SharedDeliveryEditor(model: model, action: .register(line), page: page)
        } else {
            NavigationStack {
                List(page.lines.filter { search.isEmpty || $0.name.localizedStandardContains(search) }) { line in
                    Button(line.name) { self.line = line }.accessibilityIdentifier("delivery.line." + line.id.uuidString)
                }
                .navigationTitle(ht("Ordered item"))
                .searchable(text: $search, prompt: ht("Search ordered items"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() } } }
            }
        }
    }
}

private struct SharedDeliveryEditor: View {
    @ObservedObject var model: HouseholdShopModel
    let action: DeliveryForm
    // Keep all revisions and heads from the moment the editor was opened.
    @State private var reviewed: SharedDeliveryPage
    @State private var name = ""
    @State private var exclusions = ""
    @State private var literal = ""
    @State private var unit = UnitOfMeasure.count
    @State private var hasTime = false
    @State private var time = Date()
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(model: HouseholdShopModel, action: DeliveryForm, page: SharedDeliveryPage) {
        self.model = model; self.action = action; _reviewed = State(initialValue: page)
        let quantity: SharedMealQuantity?
        switch action {
        case .register: quantity = nil
        case .arrival(let source):
            quantity = source.arrival?.received
            if let arrived = source.arrival?.arrivedAt.flatMap(serviceDate) {
                _time = State(initialValue: arrived); _hasTime = State(initialValue: true)
            }
        case .usable(let source):
            quantity = source.confirmed?.quantity
            if let raw = source.arrival?.received?.unit, let receivedUnit = UnitOfMeasure(rawValue: raw) { _unit = State(initialValue: receivedUnit) }
        }
        if let quantity, let savedUnit = UnitOfMeasure(rawValue: quantity.unit),
           let amount = try? Rational(Int64(quantity.amount.numerator), Int64(quantity.amount.denominator)) {
            _unit = State(initialValue: savedUnit); _literal = State(initialValue: amount.description)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch action {
                case .register(let line):
                    LabeledContent(ht("Ordered item"), value: line.name)
                    TextField(ht("Food that came home"), text: $name)
                    TextField(ht("Exclusions, separated by commas"), text: $exclusions, axis: .vertical)
                case .arrival(let source):
                    Text(source.foodName)
                    LabeledContent(ht("Delivery reference"), value: String(source.segmentKey.uuidString.prefix(8)))
                    Toggle(ht("Arrival time known"), isOn: $hasTime)
                    if hasTime { DatePicker(ht("Arrival time"), selection: $time) }
                    amountFields(ht("Received quantity"))
                case .usable(let source):
                    Text(source.foodName)
                    LabeledContent(ht("Delivery reference"), value: String(source.segmentKey.uuidString.prefix(8)))
                    LabeledContent(ht("Received quantity"), value: deliveryQuantityText(source.arrival?.received))
                    amountFields(ht("Usable quantity"))
                }
                if let error { Text(error) }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ht("Save")) { Task { await save() } }
                        .accessibilityLabel(ht("Save to shared shop"))
                        .disabled(model.busy)
                }
            }
            .interactiveDismissDisabled(model.busy)
        }
    }

    @ViewBuilder private func amountFields(_ label: String) -> some View {
        Section {
            TextField(label, text: $literal).accessibilityIdentifier("delivery.amount")
            Picker(ht("Unit"), selection: $unit) {
                ForEach(UnitOfMeasure.allCases, id: \.self) { Text(dinnerUnit($0)).tag($0) }
            }
        } header: { Text(label) } footer: { Text(ht("Leave the quantity blank if it is unknown. Enter 0 for a confirmed zero.")) }
    }
    private func quantity() throws -> SharedMealQuantity? {
        guard let value = try DinnerEntry.quantity(literal, unit: unit) else { return nil }
        return .init(amount: .init(numerator: Int(value.amount.numerator), denominator: Int(value.amount.denominator)),
                     unit: unit.rawValue, originalLiteral: value.originalLiteral)
    }
    private func save() async {
        let edit: SharedDeliveryEdit
        do {
            switch action {
            case .register(let line):
                let tags = exclusions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                edit = .register(lineID: line.id, segment: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), exclusions: tags)
            case .arrival(let source):
                edit = .arrival(source: source.id, previous: source.arrival?.observationId, observation: UUID(),
                                date: hasTime ? time : nil, received: try quantity())
            case .usable(let source):
                guard let arrival = source.arrival else { throw ClientError.configuration }
                let value = try quantity(), now = Date()
                if value != nil {
                    guard let when = arrival.arrivedAt.flatMap(serviceDate), when <= now, let received = arrival.received,
                          let receivedUnit = UnitOfMeasure(rawValue: received.unit), receivedUnit.dimension == unit.dimension,
                          let converted = try DinnerEntry.quantity(literal, unit: unit)?.converted(to: receivedUnit),
                          converted <= (try Rational(Int64(received.amount.numerator), Int64(received.amount.denominator))) else {
                        error = pTr("Usable amount must be valid and no larger than the received amount."); return
                    }
                }
                edit = .usable(source: source.id, previous: source.usable?.observationId, arrival: arrival.observationId,
                               observation: UUID(), date: now, quantity: value)
            }
            _ = try edit.body(reviewed: reviewed)
        } catch { self.error = ht("Check the food name, exclusions and quantity before saving."); return }
        if await model.saveDelivery(edit, reviewed: reviewed) {
            dismiss()
            if model.pending == nil { await model.loadDelivery() }
        } else { error = model.notice ?? ht("Refresh deliveries and review the current record.") }
    }
}
