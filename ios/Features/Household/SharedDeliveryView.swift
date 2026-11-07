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

private func deliveryQuantityText(_ value: SharedMealQuantity?) -> String {
    guard let value, let unit = UnitOfMeasure(rawValue: value.unit),
          let amount = try? Rational(Int64(value.amount.numerator), Int64(value.amount.denominator)) else { return dinnerText("Quantity unresolved") }
    return dinnerQuantity(.init(amount: amount, unit: unit, originalLiteral: value.originalLiteral))
}

struct SharedDeliveryView: View {
    @ObservedObject var model: HouseholdShopModel
    let shopID: String
    @State private var form: DeliveryForm?
    @State private var choosingLine = false

    var body: some View {
        Form {
            if model.canReadDelivery, model.scope.shopId == shopID {
                if let page = model.deliveryRecord, page.shopId == UUID(uuidString: shopID) {
                    if model.shop?.phase == "placed", model.pending == nil, !page.lines.isEmpty {
                        Button(ht("Add a delivery")) { choosingLine = true }
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
