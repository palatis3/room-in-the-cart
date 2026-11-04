import SwiftUI
import UIKit
import CoreDomain

struct UrgentRepairView: View {
    @ObservedObject var model: PickupModel
    private enum Field { case food, meal, required, available }
    @FocusState private var field: Field?
    @State private var food = ""
    @State private var meal = ""
    @State private var required = ""
    @State private var available = ""
    @State private var unit: UnitOfMeasure = .count
    @State private var hasDue = false
    @State private var due = Date()
    @State private var confirmedAt: Date?
    @State private var operationID = UUID()
    @State private var showRepair = false
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            Text(pTr("Make a private meal need from food you have checked. This does not create an order, delivery or charge."))
            TextField(pTr("Food that is short"), text: $food).focused($field, equals: .food)
            TextField(pTr("Meal or purpose"), text: $meal).focused($field, equals: .meal)
            TextField(pTr("Required amount"), text: $required).focused($field, equals: .required).keyboardType(.decimalPad)
            TextField(pTr("Usable amount available now"), text: $available).focused($field, equals: .available).keyboardType(.decimalPad)
            Picker(pTr("Unit"), selection: $unit) { ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pTr($0.rawValue)).tag($0) } }
            Toggle(pTr("I checked this food’s identity and usable amount"), isOn: Binding(
                get: { confirmedAt != nil }, set: { confirmedAt = $0 ? Date() : nil }
            ))
            Toggle(pTr("Meal deadline is known"), isOn: $hasDue)
            if hasDue { DatePicker(pTr("Needed by"), selection: $due) }
            Button(pTr("Save need and repair meal")) { save() }.buttonStyle(.borderedProminent).disabled(confirmedAt == nil)
        }.navigationTitle(pTr("Something is missing"))
            .onChange(of: [food, meal, required, available, unit.rawValue]) { _, _ in confirmedAt = nil }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(tr("Done")) { field = nil }
                }
            }
            .task { await model.load() }
            .navigationDestination(isPresented: $showRepair) { PickupRepairView(model: model) }
            .disabled(model.saving)
    }
    private func save() {
        do {
            guard let confirmedAt, !food.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !meal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let needed = try ComparisonModel.quantity(required, unit), let stock = try ComparisonModel.quantity(available, unit) else { throw CocoaError(.validationMissingMandatoryProperty) }
            let need = UrgentMealNeed(id: operationID, food: food, meal: meal, required: needed, available: stock, due: hasDue ? due : nil, confirmedAt: confirmedAt)
            Task {
                guard await model.addUrgent(need) else { return }
                operationID = UUID()
                food = ""; meal = ""; required = ""; available = ""
                unit = .count; hasDue = false; due = Date(); self.confirmedAt = nil
                showRepair = true
            }
        } catch { model.error = pTr("Enter the food, meal and valid required and available amounts.") }
    }
}

struct PickupRepairView: View {
    @Environment(\.pickupLedger) private var fallbackLedger
    @ObservedObject var model: PickupModel
    private enum Field { case purpose, amount, instruction, minutes }
    @FocusState private var field: Field?
    @FocusState private var stockField: PickupNewStockSection.Field?
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
                    TextField(pTr("Meal or protected purpose"), text: $purpose).focused($field, equals: .purpose)
                    TextField(pTr("Amount in original line units"), text: $amount).keyboardType(.decimalPad).focused($field, equals: .amount)
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
            if model.journey?.closedAt == nil { PickupNewStockSection(model: model, field: $stockField).id(model.selectedID) }
            if let journey = model.journey { PickupSavedStockSection(model: model, journey: journey) }
            if let ledger = fallbackLedger {
                NavigationLink(dinnerText("Recover with an accepted dinner")) {
                    PickupFallbackReviewEntry(model: model, ledger: ledger) { option, target, deadline in
                        needID = target; instruction = option.instruction
                        minutes = String(option.minutes); due = deadline; knownDue = true
                        extraTrip = option.requiresTrip; repeatMeal = option.repeatRequired
                    }
                }
            }
            Section(pTr("Free manual meal repair")) {
                Picker(pTr("Affected meal need"), selection: $needID) {
                    Text(pTr("Choose a need")).tag(UUID?.none)
                    ForEach(model.journey?.needs ?? []) { Text($0.name).tag(Optional($0.id)) }
                    ForEach(model.journey?.urgent ?? []) { Text($0.meal).tag(Optional($0.id)) }
                }
                TextField(pTr("Exact food, portions, exclusions and instructions"), text: $instruction, axis: .vertical).focused($field, equals: .instruction)
                Toggle(pTr("I agree to an extra top-up trip for this repair"), isOn: $extraTrip)
                Toggle(pTr("I agree to repeat a meal for this repair"), isOn: $repeatMeal)
                TextField(pTr("Remaining elapsed preparation minutes (optional)"), text: $minutes).keyboardType(.numberPad).focused($field, equals: .minutes)
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
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneAction(visible: stockField != nil, title: tr("Done")) { stockField = nil }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if field != nil {
                        Spacer()
                        Button(tr("Done")) { field = nil }
                    }
                }
            }
    }
    private func rationalText(_ value: Rational?) -> String { value?.description ?? pTr("Unresolved") }
    private func addNeed() {
        do {
            guard let line = model.journey?.pickup?.orderLines.first(where: { $0.id == lineID }), !purpose.isEmpty, let quantity = try ComparisonModel.quantity(amount, line.ordered.unit) else { throw CocoaError(.validationMissingMandatoryProperty) }
            let need = AllocationNeed(id: UUID(), orderLineID: line.id, name: purpose, amount: quantity, priority: priority)
            Task {
                if await model.change({ value in
                    value.needs.append(need)
                    if let pickup = value.pickup {
                        // Stock-only commitments remain in physicalStockNeeds; receipt
                        // allocation checks only food that was actually ordered.
                        let actualLineIDs = Set(pickup.orderLines.map(\.id))
                        _ = try pickup.allocate(value.needs.filter { actualLineIDs.contains($0.orderLineID) })
                    }
                }) { purpose = ""; amount = "" }
            }
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
    @State private var prepared: CookHandoffReview?
    @State private var preparedRevision: Int64?
    @State private var preparedText = ""
    @State private var preparedShopID: UUID?
    @State private var noteID: UUID?
    @State private var draftID = UUID()
    @State private var editingSavedID: UUID?
    @State private var sharing: HandoffCopy?
    var body: some View {
        Form {
            PickupSaveStatus(model: model)
            CookLiveViewContextLink()
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
            if let noteID {
                Button(pTr("Share saved dated copy")) { Task {
                    guard let copy = model.handoffCopy(channel: .cook, versionID: noteID, language: language),
                          await model.recordCookShare(.shareOpened, copy: copy), access.unlocked,
                          model.journey?.id == copy.shopID, self.noteID == copy.versionID else { return }
                    sharing = copy
                } }
                PickupRecipientSection(model: model, channel: .cook, versionID: noteID, language: language)
                    .id(noteID)
            }
            Section(pTr("Saved cook notes")) {
                ForEach(model.journey?.notes ?? []) { note in
                    Text(note.text).textSelection(.enabled)
                    Button(pTr("Review this saved copy")) {
                        readback = nil; prepared = nil; preparedRevision = nil
                        language = note.language; text = note.text; noteID = note.id; editingSavedID = note.id
                    }
                    if let sent = note.sentTo { Text("\(pTr("Reported sent to")): \(sent)") }
                }
            }
        }.navigationTitle(pTr("Tell the cook"))
            .onAppear { includeBudget = false; readback = nil }
            .onDisappear { readback = nil }
            .onChange(of: text) { _, value in
                draftID = UUID()
                if value != readback?.text { readback = nil }
                if let noteID, model.journey?.notes.first(where: { $0.id == noteID })?.text != value { self.noteID = nil }
            }
            .onChange(of: language) { _, _ in readback = nil }
            .onChange(of: includeBudget) { _, _ in readback = nil }
            .onChange(of: model.journey?.id) { _, _ in readback = nil; noteID = nil; prepared = nil; text = "" }
            .onChange(of: model.journey?.revision) { _, _ in readback = nil }
            .onChange(of: readbackContext) { _, _ in readback = nil }
            .onChange(of: scenePhase) { _, phase in if phase != .active { readback = nil } }
            .sheet(item: $sharing) { copy in
                PickupActivitySheet(text: copy.fullText) { completed, destination in
                    Task { await model.recordCookShare(completed ? .shareCompleted : .shareCancelled, copy: copy, destination: destination) }
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
        prepared = sourceReview(value, zone: timeZone, custom: false)
        preparedText = text; preparedShopID = value.id; preparedRevision = value.revision; editingSavedID = nil
        noteID = nil
        readback = PickupCookReadbackBinding(journey: value, allocation: model.allocation, result: model.result,
            language: language, includeBudget: includeBudget, text: text, context: readbackContext, at: at, timeZone: timeZone)
    }
    private func sourceReview(_ value: PickupJourney, zone: TimeZone, custom: Bool) -> CookHandoffReview {
        CookHandoffReview(pieces: PickupCookProjection.pieces(journey: value, allocation: model.allocation, language: language, timeZone: zone),
                          timeZoneID: zone.identifier, includesBudget: includeBudget, customWording: custom,
                          budget: includeBudget ? model.result.map { PickupCookProjection.budgetText($0, language: language) } : nil)
    }
    @discardableResult private func saveNote() async -> Bool {
        readback = nil
        guard let value = model.journey, !text.isEmpty else { return false }
        if let saved = value.notes.first(where: { $0.id == (noteID ?? draftID) && $0.text == text && $0.language == language }) {
            noteID = saved.id
            return true
        }
        if let editingSavedID {
            guard let source = model.handoffCopy(channel: .cook, versionID: editingSavedID, language: language), model.isCurrent(source) else {
                model.error = pTr("The source changed. Prepare and review the current instruction.")
                return false
            }
        }
        let zone = prepared.flatMap { TimeZone(identifier: $0.timeZoneID) } ?? .current
        if let prepared, (preparedShopID != value.id || preparedRevision != value.revision || prepared != sourceReview(value, zone: zone, custom: false)) {
            model.error = pTr("The source changed. Prepare and review the current instruction.")
            return false
        }
        // Keep the source ID while a failed store write is retried from PickupSaveStatus.
        let id = value.notes.contains(where: { $0.id == draftID }) ? UUID() : draftID
        draftID = id
        var note = PickupCookNote(id: id, text: text, language: language, createdAt: Date(), revision: value.revision)
        note.reviewedHandoff = sourceReview(value, zone: zone, custom: prepared == nil || text != preparedText)
        if await model.change({ $0.notes.append(note) }) {
            noteID = id; editingSavedID = id; prepared = nil; includeBudget = false; return true
        }
        return false
    }
}
