import SwiftUI
import CoreDomain

/// This entry owns a live private-workspace lease. Shared recovery requires the
/// server command described by the recovery contract and is not routed here.
struct PickupMealRecoveryEntry: View {
    @ObservedObject var model: PickupModel
    @ObservedObject var ledger: LedgerModel
    let pickupID: UUID
    var occurrenceID: UUID? = nil
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @EnvironmentObject private var membership: MembershipCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.guardianChildCoordinator) private var guardianChild
    @State private var session = PickupStockReviewSession()
    @State private var leaseID = UUID()

    var body: some View {
        WorkingForm {
            PickupSaveStatus(model: model)
            Section {
                Text(recoveryText("Private pickup · Free manual recovery"))
                if model.journey?.closedAt != nil {
                    Text(recoveryText("This pickup is closed. You can read its saved dinner instructions."))
                } else {
                    Text(recoveryText("Review a whole dinner replacement. The purchased basket, receipts and charges stay as recorded. Shared meal recovery is not available here."))
                }
            }
            if currentAuthority() != nil {
                switch definitions {
                case .success(let values):
                    if values.isEmpty || (occurrenceID != nil && !values.contains(where: { $0.meal.id == occurrenceID })) { Text(recoveryText("No exactly linked dinner is available for replacement.")) }
                    ForEach(values.filter { occurrenceID == nil || $0.meal.id == occurrenceID }, id: \.meal.id) { value in
                        Section(value.meal.title) {
                            PickupRecoveryMealSummary(definition: value, allocation: model.stockAllocation)
                            if model.journey?.closedAt == nil {
                                if model.journey?.mealRecovery?.domain.events.contains(where: { $0.request.target.id == value.meal.id }) == true {
                                    NavigationLink(dinnerText("Move this dinner")) {
                                        PickupRecoveryCalendarView(model: model, original: value, currentAuthority: currentAuthority)
                                            .id(leaseID)
                                    }.accessibilityIdentifier("mealRecovery.move." + value.meal.id.uuidString)
                                }
                                NavigationLink(recoveryText("Replace this whole dinner")) {
                                    PickupMealRecoveryEditor(model: model, original: value,
                                        currentAuthority: currentAuthority)
                                        .id(leaseID)
                                }.accessibilityIdentifier("mealRecovery.target." + value.meal.id.uuidString)
                                if membership.model?.hasPaidAccess == true {
                                    NavigationLink(dinnerText("Recover with an accepted dinner")) {
                                        acceptedDinners(for: value)
                                    }.accessibilityIdentifier("mealRecovery.accepted." + value.meal.id.uuidString)
                                }
                            }
                        }
                    }
                case .failure:
                    if model.journey?.mealSource == nil {
                        Text(recoveryText("This pickup was saved without the original dinner links. In Shop, open Repair a meal to review portions and save manual instructions."))
                    } else {
                        Text(recoveryText("The original meal links cannot be verified. Review the source pickup before replacing a dinner."))
                    }
                }
            } else {
                Text(recoveryText("Return to the same unlocked private pickup to review its dinners."))
            }
        }
        .navigationTitle(recoveryText("Current dinners after arrival"))
        .onAppear { refreshBoundary() }
        .onChange(of: presentation) { _, _ in refreshBoundary() }
        .onChange(of: membership.model?.hasPaidAccess) { _, _ in rotateLease() }
        .onChange(of: model.selectedID) { _, _ in rotateLease() }
        .onChange(of: ledger.shop?.revisionID) { _, _ in rotateLease() }
        .onChange(of: ledger.sourceWorkspaceID) { _, _ in rotateLease() }
    }
    private func acceptedDinners(for original: PickupRecoveryMealDefinition) -> some View {
        let library = ledger.workspace.dinnerPlanning.acceptedDinners.filter(\.acceptedFallback)
        return WorkingForm {
            if acceptedAuthority() != nil {
                if library.isEmpty { Text(dinnerText("No household dinner is marked as an accepted fallback.")) }
                ForEach(library) { dinner in
                    NavigationLink(dinner.template.title) {
                        if let draft = try? PickupRecoveryDraft(original, using: dinner.template) {
                            PickupMealRecoveryEditor(model: model, original: original, initialDraft: draft,
                                currentAuthority: acceptedAuthority)
                                .id("\(leaseID)/\(dinner.id)/\(dinner.template.revision)")
                        } else {
                            Text(recoveryText("Review the saved recipe’s quantities, serving groups and exclusions before using it for this dinner."))
                        }
                    }
                }
            } else { Text(dinnerText("This assisted tool requires paid access. Manual dinner editing remains available.")) }
        }.navigationTitle(dinnerText("Accepted fallbacks"))
    }
    private func acceptedAuthority() -> PickupRecoveryAuthority? {
        guard membership.model?.hasPaidAccess == true, var authority = currentAuthority() else { return nil }
        authority.permitsAcceptedDinner = true
        return authority
    }
    private var definitions: Result<[PickupRecoveryMealDefinition], Error> {
        Result { try model.recoveryDefinitions() }
    }
    private var presentation: PickupStockReviewPresentation {
        .current(workspaceID: model.sourceWorkspaceID, localActorID: access.localActorID,
            workspaceUnlocked: access.unlocked, sceneActive: scenePhase == .active,
            childPresented: guardianChild?.presented == true, household: household)
    }
    private func currentAuthority() -> PickupRecoveryAuthority? {
        guard session.scope(for: presentation) != nil, ledger.ready, !ledger.saving,
              !ledger.hasPendingSave, model.ready, model.selectedID == pickupID,
              model.journey?.id == pickupID, ledger.shop?.id == pickupID,
              let workspace = ledger.sourceWorkspaceID, let revision = ledger.shop?.revisionID else { return nil }
        return .init(presentation: presentation, ledgerWorkspaceID: workspace,
            ledgerRevisionID: revision, selectedPickupID: pickupID, leaseID: leaseID)
    }
    private func refreshBoundary() {
        if session.refresh(presentation) { rotateLease() }
    }
    private func rotateLease() { leaseID = UUID() }
}

private struct PickupRecoveryMealSummary: View {
    let definition: PickupRecoveryMealDefinition
    let allocation: StockAllocationResult?
    var body: some View {
        let meal = definition.meal
        LabeledContent(recoveryText("Servings"), value: meal.servings.description)
        if let day = meal.scheduledDay { Text(day.iso8601) }
        Text(meal.timeZoneID)
        Text(meal.due.map { recoveryText("Needed by") + ": " + recoveryDate($0, zone: meal.timeZoneID) }
            ?? recoveryText("Deadline unknown · timing remains conditional"))
        ForEach(definition.groups) { group in
            Text(group.name + ": " + group.servings.description +
                (group.isProtected ? " · " + recoveryText("Protected") : ""))
        }
        if !meal.exclusions.isEmpty { Text(recoveryText("Keep these exclusions") + ": " + meal.exclusions.joined(separator: ", ")) }
        ForEach(meal.ingredients, id: \.need.id) { item in
            VStack(alignment: .leading, spacing: 6) {
                Text(item.foodName + " · " + pQuantity(item.need.amount))
                if item.need.priority == .protected { Text(recoveryText("Protected · unchanged")) }
                if let rule = definition.ingredientRules.first(where: { $0.needID == item.need.id }) {
                    if !rule.notes.isEmpty { Text(rule.notes) }
                    if !rule.exclusions.isEmpty { Text(recoveryText("Keep these exclusions") + ": " + rule.exclusions.joined(separator: ", ")) }
                }
                Text(recoveryCoverage(allocation?.demands.first { $0.id == item.need.id }))
            }.accessibilityElement(children: .combine)
                .accessibilityIdentifier("mealRecovery.need." + item.need.id.uuidString)
        }
        if let minutes = meal.remainingElapsedMinutes {
            Text(pTr("Saved elapsed preparation minutes") + ": " + String(minutes))
        } else { Text(pTr("Remaining preparation time unknown")) }
        if let minutes = meal.requiredLeadMinutes {
            Text(pTr("Required advance preparation (minutes)") + ": " + String(minutes))
        }
        if meal.advanceStepsCompleted { Text(pTr("Advance preparation confirmed complete")) }
        if !definition.notes.isEmpty { Text(definition.notes) }
        if let source = definition.sourceURL { Text(source).textSelection(.enabled) }
    }
}

private func recoveryDate(_ date: Date, zone: String) -> String {
    date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened,
        timeZone: TimeZone(identifier: zone) ?? .current))
}

private func recoveryCoverage(_ value: StockDemandCoverage?) -> String {
    let allocated = value.flatMap { row in row.allocated.map { pQuantity($0, unit: row.unit) } } ?? recoveryText("Unresolved")
    let shortfall = value.flatMap { row in row.shortfall.map { pQuantity($0, unit: row.unit) } } ?? recoveryText("Unresolved")
    return recoveryText("Allocated") + ": " + allocated + " · " + recoveryText("Still short") + ": " + shortfall
}

/// The editor captures metadata and explicit matching; the adapter owns stock
/// evidence, validation, allocations, authority, persistence and exact replay.
private struct PickupMealRecoveryEditor: View {
    @ObservedObject var model: PickupModel
    let original: PickupRecoveryMealDefinition
    let currentAuthority: () -> PickupRecoveryAuthority?
    @State private var draftAuthority: PickupRecoveryAuthority?
    @State private var draft: PickupRecoveryDraft
    @State private var review: PickupMealRecoveryReview?
    @State private var error: String?
    @State private var agreesTrip = false
    @State private var agreesRepeat = false
    @State private var acceptsUnresolved = false
    @State private var effectsReviewed = false
    @State private var applied = false
    @FocusState private var focused: String?
    @AccessibilityFocusState private var resultFocused: Bool

    init(model: PickupModel, original: PickupRecoveryMealDefinition, initialDraft: PickupRecoveryDraft? = nil,
         currentAuthority: @escaping () -> PickupRecoveryAuthority?) {
        self.model = model; self.original = original; self.currentAuthority = currentAuthority
        _draft = State(initialValue: initialDraft ?? PickupRecoveryDraft(original))
        _draftAuthority = State(initialValue: currentAuthority())
    }
    var body: some View {
        WorkingForm {
            PickupSaveStatus(model: model)
            if liveAuthority() == nil {
                Text(recoveryText("Return to the same unlocked private pickup to review its dinners."))
            } else if applied {
                Section {
                    Text(recoveryText("Dinner replacement saved. The original purchase is unchanged."))
                        .accessibilityFocused($resultFocused).accessibilityIdentifier("mealRecovery.saved")
                    if let current = try? model.recoveryDefinitions().first(where: { $0.meal.id == original.meal.id }) {
                        PickupRecoveryMealSummary(definition: current, allocation: model.stockAllocation)
                    }
                }
            } else if let review {
                reviewSections(review)
            } else {
                editorSections
            }
            if let error {
                Text(error).foregroundStyle(Theme.error).listRowBackground(Color("error_surface"))
                    .accessibilityIdentifier("mealRecovery.error")
            }
        }
        .navigationTitle(recoveryText("Replace a whole dinner"))
        .environment(\.timeZone, TimeZone(identifier: original.meal.timeZoneID) ?? .current)
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: focused != nil, title: tr("Done")) { focused = nil }
        .disabled(model.saving)
        .onChange(of: model.journey?.revision) { _, _ in
            guard liveAuthority() != nil, let review, let history = model.journey?.mealRecovery,
                  history.domain.events.contains(where: { $0.request == confirmed(review).domain.request }),
                  history.definitions.contains(where: { $0.operationID == review.id && $0.definition == review.definition }) else { return }
            applied = true
            self.review = nil
            resultFocused = true
        }
        .onChange(of: draft.rows) { _, _ in draft.identityReviewed = false }
    }
    @ViewBuilder private var editorSections: some View {
        Section(recoveryText("Original current dinner")) {
            PickupRecoveryMealSummary(definition: original, allocation: model.stockAllocation)
        }
        Section(draft.template == nil ? recoveryText("Manual replacement") : dinnerText("Accepted fallbacks")) {
            if let template = draft.template {
                Text(template.title).font(.headline)
                if !template.notes.isEmpty { Text(template.notes) }
                if let url = template.sourceURL { Text(url).textSelection(.enabled) }
                if !template.exclusions.isEmpty { Text(recoveryText("Keep these exclusions") + ": " + template.exclusions.joined(separator: ", ")) }
                if let minutes = template.leadTimeMinutes { Text(pTr("Saved elapsed preparation minutes") + ": " + String(minutes)) }
            } else {
                field("Dinner title", text: $draft.title, id: "title")
                field("Notes and preparation instructions", text: $draft.notes, id: "notes", multiline: true)
                field("Recipe source URL (optional)", text: $draft.sourceURL, id: "source")
                Text(recoveryText("This is a new manual dinner version. It does not edit the reusable recipe. Serving groups, protected portions and saved exclusions remain in force."))
            }
            ForEach(Array(draft.rows.indices), id: \.self) { index in
                ingredient(index)
            }
            ForEach(draft.template == nil ? draft.editableGroups : [], id: \.self) { groupID in
                Button(recoveryText("Add ingredient") + " · " + draft.groupName(groupID)) { draft.add(groupID: groupID) }
                    .foregroundStyle(Theme.action)
            }
        }
        Section(recoveryText("Timing and explicit agreements")) {
            field("Remaining elapsed preparation minutes (optional)", text: $draft.minutes, id: "minutes")
                .keyboardType(.numberPad)
            Text(recoveryText("Include thawing, soaking and marinating in the remaining elapsed time. Unknown preparation or deadline stays conditional."))
            Toggle(recoveryText("Required advance preparation is already complete"), isOn: $draft.advanceComplete)
            if original.meal.due == nil {
                Toggle(recoveryText("I can confirm this previously unknown deadline"), isOn: $draft.confirmsDeadline)
                if draft.confirmsDeadline { DatePicker(recoveryText("Needed by"), selection: $draft.deadline) }
            }
            Toggle(recoveryText("I reviewed every food identity, usable unit and inherited exclusion"), isOn: $draft.identityReviewed)
            Toggle(recoveryText("This replacement proposes an extra trip"), isOn: $draft.proposesTrip)
            Text(recoveryText("Agreeing to a trip does not add stock or confirm a delivery."))
            Button(recoveryText("Preview whole-dinner replacement")) { preview() }
                .buttonStyle(PrimaryAction()).disabled(!draft.identityReviewed || model.hasPendingSave)
                .accessibilityIdentifier("mealRecovery.preview")
        }
    }
    @ViewBuilder private func ingredient(_ index: Int) -> some View {
        let row = draft.rows[index]
        VStack(alignment: .leading, spacing: 10) {
            Text(draft.groupName(row.groupID)).font(.headline)
            if draft.template != nil {
                Text(row.name)
                if let quantity = try? DinnerEntry.quantity(row.amount, unit: row.unit) { Text(pQuantity(quantity)) }
                if !row.notes.isEmpty { Text(row.notes) }
            } else {
                field("Food name", text: $draft.rows[index].name, id: row.id.uuidString + ".name")
            }
            Picker(recoveryText("Reviewed matching food"), selection: $draft.rows[index].foodID) {
                Text(recoveryText("No confirmed matching food · unresolved")).tag(UUID?.none)
                ForEach(model.recoveryStockMatches) { Text($0.name).tag(Optional($0.id)) }
            }
            if draft.template == nil {
                field("Required usable amount", text: $draft.rows[index].amount, id: row.id.uuidString + ".amount")
                    .keyboardType(.decimalPad)
                Picker(recoveryText("Usable unit"), selection: $draft.rows[index].unit) {
                    ForEach(UnitOfMeasure.allCases, id: \.self) { Text(pTr($0.rawValue)).tag($0) }
                }
                field("Ingredient notes", text: $draft.rows[index].notes, id: row.id.uuidString + ".notes", multiline: true)
            }
            Text(recoveryText("Keep these exclusions") + ": " + row.requiredExclusions.joined(separator: ", "))
            field("Additional exclusions, one per line", text: $draft.rows[index].extraExclusions,
                  id: row.id.uuidString + ".exclusions", multiline: true)
            if draft.template == nil {
                Button(recoveryText("Remove ingredient"), role: .destructive) { draft.rows.remove(at: index) }
                    .foregroundStyle(Theme.error)
            }
        }
    }
    @ViewBuilder private func reviewSections(_ value: PickupMealRecoveryReview) -> some View {
        Section(recoveryText("Before replacement")) {
            Text(original.meal.title).font(.headline)
            PickupRecoveryMealSummary(definition: original, allocation: value.domain.beforeAllocation)
        }
        Section(recoveryText("Review every current meal")) {
            Text(recoveryText(value.domain.feasible ? "Confirmed food and entered preparation fit this deadline" : "Conditional replacement · unresolved food or timing stays open"))
                .accessibilityFocused($resultFocused)
            Text(value.domain.request.reviewedAt.formatted())
            ForEach(value.domain.after.meals) { meal in
                VStack(alignment: .leading, spacing: 8) {
                    Text(meal.title).font(.headline)
                    ForEach(meal.ingredients, id: \.need.id) { item in
                        Text(item.foodName + " · " + pQuantity(item.need.amount))
                        if item.need.priority == .protected { Text(recoveryText("Protected · unchanged")) }
                        if let before = value.domain.beforeAllocation.demands.first(where: { $0.id == item.need.id }) {
                            Text(recoveryText("Before") + ": " + recoveryCoverage(before))
                        }
                        Text(recoveryText("After") + ": " + recoveryCoverage(value.domain.afterAllocation.demands.first { $0.id == item.need.id }))
                    }
                }.accessibilityElement(children: .combine).accessibilityIdentifier("mealRecovery.previewMeal." + meal.id.uuidString)
            }
            ForEach(value.domain.after.outsideDemands, id: \.id) { need in
                VStack(alignment: .leading) {
                    Text(need.name + " · " + pQuantity(need.amount))
                    if need.priority == .protected { Text(recoveryText("Protected · unchanged")) }
                    Text(recoveryText("Before") + ": " + recoveryCoverage(value.domain.beforeAllocation.demands.first { $0.id == need.id }))
                    Text(recoveryText("After") + ": " + recoveryCoverage(value.domain.afterAllocation.demands.first { $0.id == need.id }))
                }
            }
        }
        Section(recoveryText("Reviewed stock evidence")) {
            Text(recoveryText("Only confirmed stock available at the review time can cover a need. Future observations and planned trips do not add available food."))
            ForEach(value.domain.stockEvidence, id: \.lot.id) { item in
                VStack(alignment: .leading) {
                    Text(item.lot.name + " · " + pQuantity(item.lot.usable))
                    Text(pTr(item.lot.source.rawValue))
                    Text(recoveryText("Available from") + ": " + item.availableAt.formatted())
                }
            }
        }
        Section(recoveryText("Complete replacement instructions")) {
            Text(value.definition.meal.title).font(.headline)
            PickupRecoveryMealSummary(definition: value.definition, allocation: value.domain.afterAllocation)
            Group {
                if value.domain.repeatRequired {
                    Toggle(recoveryText("I agree if this replacement repeats an accepted meal"), isOn: $agreesRepeat)
                }
                if value.domain.request.proposesExtraTrip {
                    Toggle(recoveryText("I agree to this extra trip"), isOn: $agreesTrip)
                }
                if !value.domain.feasible {
                    Toggle(recoveryText("I accept that unresolved food or timing remains open"), isOn: $acceptsUnresolved)
                }
                Toggle(recoveryText("I reviewed the replacement and every other meal’s remaining shortage"), isOn: $effectsReviewed)
            }.disabled(model.hasPendingSave)
            Button(recoveryText("Apply reviewed dinner replacement")) {
                let approved = confirmed(value)
                Task {
                    if await model.applyMealRecovery(approved, currentAuthority: liveAuthority) {
                        applied = true; review = nil; resultFocused = true
                    }
                }
            }.buttonStyle(PrimaryAction())
                .disabled(!effectsReviewed || (value.domain.repeatRequired && !agreesRepeat) ||
                    (value.domain.request.proposesExtraTrip && !agreesTrip) || (!value.domain.feasible && !acceptsUnresolved) ||
                    liveAuthority() == nil)
                .accessibilityIdentifier("mealRecovery.apply")
            Button(recoveryText("Continue editing")) { review = nil; effectsReviewed = false }
                .foregroundStyle(Theme.action).disabled(model.hasPendingSave)
        }
    }
    private func field(_ key: String, text: Binding<String>, id: String, multiline: Bool = false) -> some View {
        workingTextField(recoveryText(key), text: text, axis: multiline ? .vertical : .horizontal)
            .accessibilityLabel(recoveryText(key)).accessibilityIdentifier("mealRecovery." + id)
            .focused($focused, equals: id)
    }
    private func confirmed(_ value: PickupMealRecoveryReview) -> PickupMealRecoveryReview {
        var approved = value
        approved.domain = value.domain.confirming(repeatMeal: agreesRepeat, extraTrip: agreesTrip, unresolved: acceptsUnresolved)
        return approved
    }
    private func liveAuthority() -> PickupRecoveryAuthority? {
        guard let authority = currentAuthority(), authority == draftAuthority else { return nil }
        return authority
    }
    private func preview() {
        do {
            guard let authority = liveAuthority() else { throw PickupMealRecoveryError.stale }
            focused = nil
            review = try model.prepareMealRecovery(definition: draft.definition(), operationID: draft.operationID,
                confirmedUnknownDeadline: draft.confirmsDeadline ? draft.deadline : nil,
                agreesToRepeat: false, proposesExtraTrip: draft.proposesTrip,
                agreesToExtraTrip: false, acceptsUnresolved: false, authority: authority)
            error = nil; effectsReviewed = false; resultFocused = true
            agreesRepeat = false; agreesTrip = false; acceptsUnresolved = false
        } catch {
            self.error = recoveryText("Review the complete dinner, amounts, food matches, preserved exclusions and agreements. If the pickup changed, return and open the current dinner again.")
        }
    }
}
