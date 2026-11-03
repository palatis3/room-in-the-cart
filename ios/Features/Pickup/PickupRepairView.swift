import SwiftUI
import UIKit
import CoreDomain

struct UrgentRepairView: View {
    @ObservedObject var model: PickupModel
    @State private var food = ""
    @State private var meal = ""
    @State private var required = ""
    @State private var available = ""
    @State private var unit: UnitOfMeasure = .count
    @State private var hasDue = false
    @State private var due = Date()
    @State private var confirmed = false
    @State private var operationID = UUID()
    @State private var showRepair = false
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            Text(pTr("Make a private meal need from food you have checked. This does not create an order, delivery or charge."))
            TextField(pTr("Food that is short"), text: $food)
            TextField(pTr("Meal or purpose"), text: $meal)
            TextField(pTr("Required amount"), text: $required).keyboardType(.decimalPad)
            TextField(pTr("Usable amount available now"), text: $available).keyboardType(.decimalPad)
            Picker(pTr("Unit"), selection: $unit) { ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pTr($0.rawValue)).tag($0) } }
            Toggle(pTr("I checked this food’s identity and usable amount"), isOn: $confirmed)
            Toggle(pTr("Meal deadline is known"), isOn: $hasDue)
            if hasDue { DatePicker(pTr("Needed by"), selection: $due) }
            Button(pTr("Save need and repair meal")) { save() }.buttonStyle(.borderedProminent).disabled(!confirmed)
        }.navigationTitle(pTr("Something is missing"))
            .task { await model.load() }
            .navigationDestination(isPresented: $showRepair) { PickupRepairView(model: model) }
            .disabled(model.saving)
    }
    private func save() {
        do {
            guard !food.isEmpty, !meal.isEmpty, let needed = try ComparisonModel.quantity(required, unit), let stock = try ComparisonModel.quantity(available, unit) else { throw CocoaError(.validationMissingMandatoryProperty) }
            let need = UrgentMealNeed(id: operationID, food: food, meal: meal, required: needed, available: stock, due: hasDue ? due : nil, confirmedAt: Date())
            Task { if await model.addUrgent(need) { showRepair = true } }
        } catch { model.error = pTr("Enter the food, meal and valid required and available amounts.") }
    }
}

struct PickupRepairView: View {
    @ObservedObject var model: PickupModel
    @State private var lineID: UUID?
    @State private var purpose = ""
    @State private var amount = ""
    @State private var priority: AllocationPriority = .required
    @State private var needID: UUID?
    @State private var instruction = ""
    @State private var extraTrip = false
    @State private var repeatMeal = false
    @State private var minutes = ""
    @State private var knownDue = false
    @State private var due = Date()
    @State private var repairID = UUID()
    @State private var stockFoodID: UUID?
    @State private var stockAmount = ""
    @State private var stockName = ""
    @State private var stockUnit: UnitOfMeasure = .count
    @State private var stockSource: ConfirmedStockSource = .freezer
    @State private var stockConfirmed = false
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            if let pickup = model.journey?.pickup {
                Section(pTr("Meal needs and protected portions")) {
                    Text(pTr("Enter separate named needs within the food required. Protected portions allocate before dinner portions."))
                    Picker(pTr("Food"), selection: $lineID) {
                        Text(pTr("Choose a line")).tag(UUID?.none)
                        ForEach(pickup.orderLines) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextField(pTr("Meal or protected purpose"), text: $purpose)
                    TextField(pTr("Amount in original line units"), text: $amount).keyboardType(.decimalPad)
                    Picker(pTr("Priority"), selection: $priority) {
                        Text(pTr("Protected")) .tag(AllocationPriority.protected)
                        Text(pTr("Required")).tag(AllocationPriority.required)
                        Text(pTr("Flexible")).tag(AllocationPriority.flexible)
                    }
                    Button(pTr("Add reviewed need")) { addNeed() }
                    ForEach(model.journey?.needs ?? []) { need in
                        VStack(alignment: .leading) {
                            Text("\(need.name): \(pQuantity(need.amount))")
                            if let detail = model.journey?.needDetails.first(where: { $0.id == need.id }) {
                                if !detail.exclusions.isEmpty { Text("\(pTr("Keep these exclusions")): \(detail.exclusions.joined(separator: ", "))") }
                                if let day = detail.scheduledDay { Text("\(day.iso8601) · \(day.timeZoneIdentifier)") }
                                if let minutes = detail.leadTimeMinutes { Text("\(pTr("Saved elapsed preparation minutes")): \(minutes)") }
                            }
                            if let coverage = model.allocation?.demands.first(where: { $0.id == need.id }) {
                                Text("\(pTr("Allocated")): \(rationalText(coverage.allocated)) · \(pTr("Still short")): \(rationalText(coverage.shortfall))")
                                ForEach(coverage.issues, id: \.self) { Text(pTr($0.rawValue)).font(.caption) }
                            }
                        }
                    }
                }
            }
            ForEach(model.journey?.urgent ?? []) { need in
                Section(need.meal) {
                    Text(need.food)
                    Text("\(pTr("Required")): \(pQuantity(need.required))")
                    if need.carriedFromID == nil { Text("\(pTr("Confirmed available")): \(pQuantity(need.available))") }
                    else { Text(pTr("Previous stock is not assumed available for this shop. Confirm it again.")) }
                    Text(need.due.map { "\(pTr("Needed by")): \($0.formatted())" } ?? pTr("Deadline unknown · timing remains conditional"))
                    if let coverage = model.stockAllocation?.demands.first(where: { $0.id == need.id }) {
                        Text("\(pTr("Allocated")): \(rationalText(coverage.allocated)) · \(pTr("Still short")): \(rationalText(coverage.shortfall))")
                    }
                    Text(pTr(need.resolved ? "Manually marked handled" : "Open meal need"))
                    Button(pTr("Mark handled after reviewing the meal")) { Task { await model.change { value in if let index = value.urgent.firstIndex(where: { $0.id == need.id }) { value.urgent[index].resolved = true } } } }
                }
            }
            ForEach(model.journey?.carriedMeals ?? []) { need in
                Section(pTr("Carried meal need · review before accepting")) {
                    Text("\(need.name): \(pQuantity(need.amount))")
                    Text(pTr("No current stock or purchase is assumed for this carried need."))
                }
            }
            Section(pTr("Confirm pantry or freezer food")) {
                Picker(pTr("Reviewed matching food need"), selection: $stockFoodID) {
                    Text(pTr("Choose a need")).tag(UUID?.none)
                    ForEach(model.journey?.stockNeeds ?? []) { Text($0.name).tag(Optional($0.foodID)) }
                    ForEach(model.journey?.pickup?.orderLines ?? []) { Text($0.name).tag(Optional($0.id)) }
                }
                TextField(pTr("Actual food or freezer batch"), text: $stockName)
                TextField(pTr("Confirmed usable amount"), text: $stockAmount).keyboardType(.decimalPad)
                Picker(pTr("Unit"), selection: $stockUnit) { ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pTr($0.rawValue)).tag($0) } }
                Picker(pTr("Stock source"), selection: $stockSource) {
                    Text(pTr("Freezer")).tag(ConfirmedStockSource.freezer)
                    Text(pTr("Pantry")).tag(ConfirmedStockSource.pantry)
                }
                Toggle(pTr("I reviewed identity, exclusions and usable quantity"), isOn: $stockConfirmed)
                Button(pTr("Confirm this separate stock lot")) { addStock() }.disabled(!stockConfirmed)
                Text(pTr("Only confirmed matching food enters allocation. Do not enter the same batch twice."))
            }
            Section(pTr("Free manual meal repair")) {
                Picker(pTr("Affected meal need"), selection: $needID) {
                    Text(pTr("Choose a need")).tag(UUID?.none)
                    ForEach(model.journey?.needs ?? []) { Text($0.name).tag(Optional($0.id)) }
                    ForEach(model.journey?.urgent ?? []) { Text($0.meal).tag(Optional($0.id)) }
                }
                TextField(pTr("Exact food, portions, exclusions and instructions"), text: $instruction, axis: .vertical)
                Toggle(pTr("I agree to an extra top-up trip for this repair"), isOn: $extraTrip)
                Toggle(pTr("I agree to repeat a meal for this repair"), isOn: $repeatMeal)
                TextField(pTr("Remaining elapsed preparation minutes (optional)"), text: $minutes).keyboardType(.numberPad)
                Toggle(pTr("Meal deadline is known"), isOn: $knownDue)
                if knownDue { DatePicker(pTr("Meal deadline"), selection: $due) }
                Text(pTr("Include thawing, soaking and marinating time unless those steps are already complete. A note does not confirm new stock or settle a shortage."))
                Button(pTr("Save reviewed repair instructions")) { saveRepair() }
            }
            ForEach(model.journey?.repairs ?? []) { repair in
                Section(pTr("Saved meal instruction")) {
                    Text(repair.instruction)
                    Text(pTr(repair.timingConfirmed ? "Entered preparation time fits the deadline" : "Timing conditional or deadline missed · review before cooking"))
                    Text(repair.createdAt.formatted()).font(.caption)
                }
            }
            NavigationLink(pTr("Preview a dated cook instruction")) { PickupCookView(model: model) }
        }.navigationTitle(pTr("Repair the meal"))
    }
    private func rationalText(_ value: Rational?) -> String { value.map { "\($0.numerator)/\($0.denominator)" } ?? pTr("Unresolved") }
    private func addStock() {
        do {
            guard let foodID = stockFoodID, !stockName.isEmpty, let quantity = try ComparisonModel.quantity(stockAmount, stockUnit) else { throw CocoaError(.validationMissingMandatoryProperty) }
            let lot = ConfirmedStockLot(id: UUID(), foodID: foodID, name: stockName, usable: quantity, confirmedAt: Date(), source: stockSource)
            Task { if await model.change({ value in
                value.stockLots.append(lot)
                _ = try ConfirmedStockAllocator.allocate(lots: value.stockLots, needs: value.stockNeeds)
            }) { stockName = ""; stockAmount = ""; stockConfirmed = false } }
        } catch { model.error = pTr("Check the confirmed food amounts and matching units.") }
    }
    private func addNeed() {
        do {
            guard let line = model.journey?.pickup?.orderLines.first(where: { $0.id == lineID }), !purpose.isEmpty, let quantity = try ComparisonModel.quantity(amount, line.ordered.unit) else { throw CocoaError(.validationMissingMandatoryProperty) }
            let need = AllocationNeed(id: UUID(), orderLineID: line.id, name: purpose, amount: quantity, priority: priority)
            Task { if await model.change({ value in value.needs.append(need); _ = try value.pickup?.allocate(value.needs) }) { purpose = ""; amount = "" } }
        } catch { model.error = pTr("Choose the food, purpose and a valid quantity.") }
    }
    private func saveRepair() {
        guard let needID, !instruction.isEmpty, minutes.isEmpty || (Int(minutes).map { $0 >= 0 && $0 <= 10080 } ?? false) else { model.error = pTr("Choose a need and enter instructions and valid preparation minutes."); return }
        let repair = PickupRepair(id: repairID, needID: needID, instruction: instruction, createdAt: Date(), extraTripAgreed: extraTrip, repeatMealAgreed: repeatMeal, elapsedMinutes: Int(minutes), due: knownDue ? due : nil)
        Task { if await model.change({ value in if !value.repairs.contains(where: { $0.id == repair.id }) { value.repairs.append(repair) } }) { repairID = UUID(); instruction = "" } }
    }
}

struct PickupCookView: View {
    @ObservedObject var model: PickupModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var readback: PickupCookReadbackBinding?
    @State private var language = "en-US"
    @State private var includeBudget = false
    @State private var text = ""
    @State private var recipient = ""
    @State private var noteID: UUID?
    @State private var sharing = false
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            Picker(pTr("Recipient language"), selection: $language) {
                Text(pTr("English (US)")).tag("en-US")
                Text(pTr("Español (EE. UU.)")).tag("es-US")
            }
            Toggle(pTr("Include private budget in this copy"), isOn: $includeBudget)
            Button(pTr("Prepare complete dated instruction")) { prepare() }
            TextEditor(text: $text).frame(minHeight: 220).accessibilityLabel(pTr("Editable cook instruction"))
            if let readback {
                Section {
                    CookReadbackView(instruction: instruction(for: readback), authorize: authorizeReadback)
                        .id(readback.authorityBindingID)
                }
            }
            Button(pTr("Save dated copy")) { Task { await saveNote() } }.disabled(text.isEmpty)
            if noteID != nil {
                Button(pTr("Share saved dated copy")) { Task {
                    if await recordShare(.shareOpened, destination: nil) { sharing = true }
                } }
                TextField(pTr("Recipient (for explicit sent history)"), text: $recipient)
                Button(pTr("I sent this version to this recipient")) { Task {
                    await model.change { value in
                        guard let index = value.notes.firstIndex(where: { $0.id == noteID }), !recipient.isEmpty else { return }
                        value.notes[index].sentTo = recipient; value.notes[index].sentAt = Date()
                    }
                } }.disabled(recipient.isEmpty)
                Text(pTr("A sent version does not prove receipt or acknowledgment. Cancelling share does not mark it sent."))
            }
            Section(pTr("Saved cook notes")) {
                ForEach(model.journey?.notes ?? []) { note in
                    Text(note.text).textSelection(.enabled)
                    if let sent = note.sentTo { Text("\(pTr("Reported sent to")): \(sent)") }
                }
            }
        }.navigationTitle(pTr("Tell the cook"))
            .onAppear { includeBudget = false; readback = nil }
            .onDisappear { readback = nil }
            .onChange(of: text) { _, value in if value != readback?.text { readback = nil } }
            .onChange(of: language) { _, _ in readback = nil }
            .onChange(of: includeBudget) { _, _ in readback = nil }
            .onChange(of: model.journey?.id) { _, _ in readback = nil }
            .onChange(of: model.journey?.revision) { _, _ in readback = nil }
            .onChange(of: readbackContext) { _, _ in readback = nil }
            .onChange(of: scenePhase) { _, phase in if phase != .active { readback = nil } }
            .sheet(isPresented: $sharing) {
                PickupActivitySheet(text: model.journey?.notes.first(where: { $0.id == noteID })?.text ?? "") { completed, destination in
                    Task { await recordShare(completed ? .intentionallySent : .shareCancelled, destination: destination) }
                }
            }
    }
    private var readbackContext: PickupCookReadbackContext {
        .init(scope: .init(localActorID: access.localActorID, accountSubject: household.identity?.subject,
            householdID: household.projection?.household.id, memberID: household.projection?.memberId, role: household.projection?.role),
            workspaceUnlocked: access.unlocked, householdLocked: household.locked,
            saving: model.saving, pendingSave: model.hasPendingSave)
    }
    private func instruction(for binding: PickupCookReadbackBinding) -> CookReadbackInstruction {
        .init(authorityBindingID: binding.authorityBindingID, sourceID: binding.sourceID,
            sourceRevision: binding.sourceRevision, createdAt: binding.createdAt, text: binding.text,
            localeIdentifier: binding.localeIdentifier, excludesPrivateBudget: true)
    }
    private func authorizeReadback(_ requested: CookReadbackInstruction, at: Date) -> Bool {
        guard let readback, requested == instruction(for: readback) else { return false }
        return readback.isCurrent(journey: model.journey, allocation: model.allocation, result: model.result,
            language: language, includeBudget: includeBudget, text: text, context: readbackContext, at: at)
    }
    private func prepare() {
        readback = nil
        guard let value = model.journey, !model.saving, !model.hasPendingSave else { return }
        let at = Date(), timeZone = TimeZone.current
        text = PickupCookProjection.text(journey: value, allocation: model.allocation, result: model.result,
            language: language, includeBudget: includeBudget, at: at, timeZone: timeZone)
        noteID = nil
        readback = PickupCookReadbackBinding(journey: value, allocation: model.allocation, result: model.result,
            language: language, includeBudget: includeBudget, text: text, context: readbackContext, at: at, timeZone: timeZone)
    }
    @discardableResult private func recordShare(_ action: HandoffActionKind, destination: String?) async -> Bool {
        guard let noteID else { return false }
        return await model.change { value in value.cookShareEvents.append(PickupCookShareEvent(id: UUID(), noteID: noteID, occurredAt: Date(), action: action, destination: destination)) }
    }
    @discardableResult private func saveNote() async -> Bool {
        readback = nil
        guard let value = model.journey else { return false }
        let id = UUID()
        let note = PickupCookNote(id: id, text: text, language: language, createdAt: Date(), revision: value.revision)
        if await model.change({ $0.notes.append(note) }) { noteID = id; includeBudget = false; return true }
        return false
    }
}
