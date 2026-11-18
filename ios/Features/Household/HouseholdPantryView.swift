import CoreDomain
import HouseholdClient
import SwiftUI

struct HouseholdPantryLink: View {
    @ObservedObject var household: HouseholdModel
    var body: some View {
        if let scope = household.householdPantryScope, let service = household.service {
            NavigationLink(householdPantryText("Household pantry")) {
                HouseholdPantryView(household: household, scope: scope, service: service)
            }.accessibilityIdentifier("household.pantry")
        }
    }
}

private struct HouseholdPantryView: View {
    @ObservedObject var household: HouseholdModel
    @StateObject private var model: HouseholdPantryModel
    @State private var sheet: Sheet?
    @State private var clearingRetry = false
    private enum Sheet: Identifiable {
        case receipt(HouseholdPantryPage), addition(HouseholdPantryPage), correction(HouseholdPantryPage, HouseholdPantryPage.Lot), grants, staples
        var id: Int {
            switch self { case .addition: 0; case .grants: 1; case .correction: 2; case .staples: 3; case .receipt: 4 }
        }
    }
    init(household: HouseholdModel, scope: HouseholdPantryRuntime, service: HouseholdService) {
        self.household = household
        _model = StateObject(wrappedValue: HouseholdPantryModel(scope: scope, service: service, store: household.pantryPendingStore,
            projection: { [weak household] in household?.householdPantryScope == scope ? household?.projection : nil },
            recheckAccess: { [weak household] in await household?.refresh() }))
    }
    var body: some View {
        Group {
            if household.householdPantryScope == model.scope {
                List {
                    if let page = model.page {
                        Section(household.projection?.household.label ?? householdPantryText("Household pantry")) {
                            HouseholdTonightLink(household: household)
                            if model.pending == nil {
                                Button(ht("Add food to storage")) { sheet = .addition(page) }
                                    .accessibilityIdentifier("householdPantry.add")
                                Button(householdPantryText("Add receipt to household pantry")) { sheet = .receipt(page) }
                                    .accessibilityIdentifier("householdPantry.receipt")
                            }
                            if household.projection?.capabilities.contains("my_feedback_withdrawal") == true, let service = household.service {
                                NavigationLink(cookingText("Review my shared meal feedback")) {
                                    SharedFeedbackWithdrawalView(household: household, scope: model.scope, service: service)
                                }
                            }
                            Button(householdPantryText("Staple reminders")) { sheet = .staples }
                                .accessibilityIdentifier("householdPantry.staples")
                            if model.scope.managesGrants {
                                Button(householdPantryText("Manage pantry access")) { sheet = .grants }
                                    .accessibilityIdentifier("householdPantry.manage")
                            }
                        }
                        if let pending = model.pending {
                            Section(householdPantryText("Saved pantry change")) {
                                switch pending.intent.change {
                                case .receipt(let receipt):
                                    HouseholdReceiptFacts(receipt: receipt)
                                case .addition(let addition): PantryAdditionFacts(addition: addition)
                                case .correction(let correction):
                                    if let lot = model.lots.first(where: { $0.id == correction.lotId }) { Text(lot.foodName) }
                                    LabeledContent(householdPantryText("Corrected count"), value: deliveryQuantityText(correction.quantity))
                                }
                                Text(householdPantryText("Check the stock below. Retrying sends the same change."))
                                if let deadline = serviceDate(pending.intent.expiresAt), deadline > Date() {
                                    Button(householdPantryText("Retry the same change")) { Task { await model.retry() } }
                                        .accessibilityIdentifier("householdPantry.retry")
                                } else { Text(householdPantryText("The retry period has ended.")) }
                                Button(householdPantryText("Clear saved retry"), role: .destructive) { clearingRetry = true }
                                    .confirmationDialog(householdPantryText("Clear the saved retry after checking stock?"), isPresented: $clearingRetry, titleVisibility: .visible) {
                                        Button(householdPantryText("I checked the stock. Clear retry."), role: .destructive) { Task { await model.clearReviewedRetry() } }
                                        Button(ht("Cancel"), role: .cancel) {}
                                    }
                            }
                        }
                        Section(householdPantryText("Stored food")) {
                            if model.lots.isEmpty { Text(ht("No household batches recorded.")) }
                            ForEach(model.lots) { lot in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(lot.foodName).font(.headline)
                                    Text(pantryLocation(lot.location.rawValue) + " · " + deliveryQuantityText(lot.observation?.quantity))
                                    LabeledContent(ht("Food source"), value: lot.origin == .delivery ? sharedRecoveryText("Delivery") : (lot.receiptEvidence == nil ? ht("Food already at home") : pantryText("Purchase receipt")))
                                    if let checked = (lot.observation?.confirmedAt).flatMap(serviceDate) {
                                        LabeledContent(ht("Previously confirmed"), value: checked.formatted())
                                    }
                                    if let evidence = lot.receiptEvidence {
                                        Text(evidence.merchant + " · " + evidence.purchaseDay)
                                        HouseholdReceiptLineFacts(row: evidence.line)
                                    }
                                    PantryStorageFacts(storedAt: lot.storedAt, useFirstAt: lot.useFirstAt, tags: lot.exclusionTags)
                                }.accessibilityElement(children: .combine)
                                if model.pending == nil, lot.origin == .manual, lot.observation != nil {
                                    Button(householdPantryText("Correct count")) { sheet = .correction(page, lot) }
                                        .accessibilityLabel(Text(householdPantryText("Correct count")) + Text(verbatim: " · " + lot.foodName))
                                        .accessibilityIdentifier("householdPantry.correct." + lot.id.uuidString)
                                }
                            }
                            if page.nextCursor != nil {
                                Button(householdPantryText("Load more food")) { Task { await model.loadMore() } }
                                    .accessibilityIdentifier("householdPantry.more")
                            }
                        }
                    }
                    if let notice = model.notice { Text(notice).accessibilityIdentifier("householdPantry.notice") }
                    if model.busy { ProgressView(ht("Checking service…")) }
                    Button(householdPantryText("Reload pantry")) { Task { await model.load() } }
                        .accessibilityIdentifier("householdPantry.refresh")
                }.disabled(model.busy)
            } else { ContentUnavailableView(ht("Household access changed"), systemImage: "lock") }
        }
        .navigationTitle(householdPantryText("Household pantry"))
        .task { await model.load() }
        .onDisappear { model.dismiss() }
        .onChange(of: household.householdPantryScope) { _, updated in
            if updated != model.scope { sheet = nil; model.dismiss() }
        }
        .onChange(of: model.page == nil) { _, empty in if empty { sheet = nil } }
        .sheet(item: $sheet) { item in
            if household.householdPantryScope == model.scope, model.page != nil {
                NavigationStack {
                    switch item {
                    case .receipt(let reviewed): HouseholdReceiptEntry(model: model, page: reviewed,
                        household: household.projection?.household.label ?? householdPantryText("Household pantry"))
                    case .addition(let reviewed): HouseholdPantryEditor(model: model, page: reviewed)
                    case .correction(let page, let lot): HouseholdPantryCountEditor(model: model, page: page, lot: lot)
                    case .staples: HouseholdStaplesView(model: model)
                    case .grants: HouseholdPantryGrantsView(model: model)
                    }
                }.interactiveDismissDisabled(model.busy)
            }
        }
    }
}

struct HouseholdPantryConfirmButton: View {
    @ObservedObject var model: HouseholdPantryModel
    let page: HouseholdPantryPage
    let change: HouseholdPantryChange
    let title: String
    let identifier: String
    @Environment(\.dismiss) private var dismiss
    @State private var retryPreparation = false

    var body: some View {
        Button(title) {
            Task {
                switch await model.confirmChange(change, reviewed: page) {
                case .savedForSubmission: dismiss()
                case .retryPreparation: retryPreparation = true
                case .unavailable: break
                }
            }
        }
        .disabled(!model.permitsReceiptReview(page))
        .accessibilityIdentifier(identifier)
        if retryPreparation {
            Text(householdPantryText("Your change is still open. Try confirming again when the service is available."))
                .accessibilityIdentifier("householdPantry.confirmationNotice")
        }
    }
}

private struct PantryStorageFacts: View {
    let storedAt: String?
    let useFirstAt: String?
    let tags: [String]
    var body: some View {
        if let stored = storedAt.flatMap(serviceDate) { LabeledContent(ht("Stored at"), value: stored.formatted()) }
        if let useFirst = useFirstAt.flatMap(serviceDate) { LabeledContent(ht("Use first by"), value: useFirst.formatted()) }
        if !tags.isEmpty { LabeledContent(householdPantryText("Food exclusions"), value: tags.joined(separator: ", ")) }
    }
}

private struct PantryAdditionFacts: View {
    let addition: HouseholdPantryAddition
    var body: some View {
        LabeledContent(ht("Food name"), value: addition.foodName)
        LabeledContent(ht("Storage location"), value: pantryLocation(addition.location.rawValue))
        LabeledContent(ht("Confirmed usable quantity"), value: deliveryQuantityText(addition.quantity))
        if let checked = serviceDate(addition.confirmedAt) { LabeledContent(ht("Previously confirmed"), value: checked.formatted()) }
        PantryStorageFacts(storedAt: addition.storedAt, useFirstAt: addition.useFirstAt, tags: addition.exclusionTags)
    }
}

struct HouseholdPantryDraft {
    var name = ""
    var location = HouseholdPantryLocation.pantry
    var literal = ""
    var unit = UnitOfMeasure.count
    var exclusions = ""
    var storedAt = Date()
    var useFirstAt = Date()
    var knownStored = false
    var knownUseFirst = false

    func review(at now: Date = Date()) throws -> HouseholdPantryAddition {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let quantity = try pantryEntryQuantity(literal, unit: unit)
        guard !knownStored || storedAt <= now else { throw ClientError.configuration }
        let value = HouseholdPantryAddition(foodName: name.trimmingCharacters(in: .whitespacesAndNewlines), location: location,
            storedAt: knownStored ? formatter.string(from: storedAt) : nil, useFirstAt: knownUseFirst ? formatter.string(from: useFirstAt) : nil,
            exclusionTags: exclusions.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            confirmedAt: formatter.string(from: now), quantity: quantity)
        try value.validate()
        return value
    }
}

private struct HouseholdPantryEditor: View {
    @ObservedObject var model: HouseholdPantryModel
    let page: HouseholdPantryPage
    @Environment(\.dismiss) private var dismiss
    @State private var draft = HouseholdPantryDraft()
    @State private var reviewed: HouseholdPantryAddition?
    @State private var invalid = false

    var body: some View {
        Form {
            if let reviewed {
                Section(householdPantryText("Review pantry addition")) { PantryAdditionFacts(addition: reviewed) }
                Button(householdPantryText("Edit addition")) { self.reviewed = nil }
                HouseholdPantryConfirmButton(model: model, page: page, change: .addition(reviewed),
                    title: householdPantryText("Confirm and add food"), identifier: "householdPantry.confirm")
            } else {
                Section {
                    TextField(ht("Food name"), text: $draft.name).accessibilityIdentifier("householdPantry.name")
                    Picker(ht("Storage location"), selection: $draft.location) {
                        ForEach(HouseholdPantryLocation.allCases, id: \.self) { Text(pantryLocation($0.rawValue)).tag($0) }
                    }
                    TextField(ht("Food exclusions, one per line"), text: $draft.exclusions, axis: .vertical)
                    Toggle(ht("Storage date known"), isOn: $draft.knownStored)
                    if draft.knownStored { DatePicker(ht("Stored at"), selection: $draft.storedAt, in: ...Date.now) }
                    Toggle(ht("Use-first date known"), isOn: $draft.knownUseFirst)
                    if draft.knownUseFirst { DatePicker(ht("Use first by"), selection: $draft.useFirstAt) }
                }
                Section {
                    TextField(ht("Confirmed usable quantity"), text: $draft.literal).accessibilityIdentifier("householdPantry.quantity")
                    Picker(ht("Unit"), selection: $draft.unit) {
                        ForEach(UnitOfMeasure.allCases, id: \.self) { Text(dinnerUnit($0)).tag($0) }
                    }
                } footer: { Text(ht("Leave the quantity blank if it is unknown. Enter 0 for a confirmed zero.")) }
                if invalid { Text(householdPantryText("Check the food name, amount and exclusions.")) }
                Button(householdPantryText("Review pantry addition")) {
                    do { reviewed = try draft.review(); invalid = false } catch { invalid = true }
                }.accessibilityIdentifier("householdPantry.review")
            }
        }.disabled(model.busy)
            .navigationTitle(ht("Add food to storage"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() }.disabled(model.busy) } }
    }
}

private func pantryEntryQuantity(_ literal: String, unit: UnitOfMeasure) throws -> SharedMealQuantity? {
    try DinnerEntry.quantity(literal, unit: unit).map {
        SharedMealQuantity(amount: .init(numerator: Int($0.amount.numerator), denominator: Int($0.amount.denominator)),
                           unit: unit.rawValue, originalLiteral: $0.originalLiteral)
    }
}

private struct HouseholdPantryCountEditor: View {
    @ObservedObject var model: HouseholdPantryModel
    let page: HouseholdPantryPage
    let lot: HouseholdPantryPage.Lot
    @Environment(\.dismiss) private var dismiss
    @State private var literal: String
    @State private var unit: UnitOfMeasure
    @State private var reviewed: HouseholdPantryCountCorrection?
    @State private var invalid = false

    init(model: HouseholdPantryModel, page: HouseholdPantryPage, lot: HouseholdPantryPage.Lot) {
        self.model = model
        self.page = page
        self.lot = lot
        let count = lot.observation?.quantity
        _literal = State(initialValue: count?.originalLiteral ?? "")
        _unit = State(initialValue: count.flatMap { UnitOfMeasure(rawValue: $0.unit) } ?? .count)
    }

    var body: some View {
        Form {
            Section(lot.foodName) {
                LabeledContent(householdPantryText("Previous count"), value: deliveryQuantityText(lot.observation?.quantity))
                if let reviewed {
                    LabeledContent(householdPantryText("Corrected count"), value: deliveryQuantityText(reviewed.quantity))
                }
            }
            if let reviewed {
                Button(householdPantryText("Edit count")) { self.reviewed = nil }
                HouseholdPantryConfirmButton(model: model, page: page, change: .correction(reviewed),
                    title: householdPantryText("Confirm corrected count"), identifier: "householdPantry.confirmCount")
            } else {
                Section {
                    TextField(householdPantryText("Corrected count"), text: $literal).accessibilityIdentifier("householdPantry.correctedQuantity")
                    Picker(ht("Unit"), selection: $unit) {
                        ForEach(UnitOfMeasure.allCases, id: \.self) { Text(dinnerUnit($0)).tag($0) }
                    }
                } footer: { Text(ht("Leave the quantity blank if it is unknown. Enter 0 for a confirmed zero.")) }
                if invalid { Text(householdPantryText("Check the count and unit.")) }
                Button(householdPantryText("Review count")) {
                    do {
                        reviewed = try .init(lot: lot, confirmedAt: Date.now.ISO8601Format(),
                                             quantity: pantryEntryQuantity(literal, unit: unit))
                        invalid = false
                    } catch { invalid = true }
                }.accessibilityIdentifier("householdPantry.reviewCount")
            }
        }.disabled(model.busy)
            .navigationTitle(householdPantryText("Correct count"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() }.disabled(model.busy) } }
    }
}

private struct HouseholdPantryGrantsView: View {
    @ObservedObject var model: HouseholdPantryModel
    @Environment(\.dismiss) private var dismiss
    @State private var target: HouseholdPantryGrants.Adult?
    var body: some View {
        List {
            Section {
                Text(householdPantryText("Adults with pantry access can see stored food, add food and correct counts."))
                if let grants = model.grants {
                    if grants.adults.isEmpty { Text(householdPantryText("There are no other active adults to manage.")) }
                    ForEach(grants.adults) { adult in
                        Button { target = adult } label: {
                            LabeledContent(adult.label, value: adult.enabled ? householdPantryText("Has pantry access") : householdPantryText("No pantry access"))
                        }
                    }
                }
                if model.busy { ProgressView() }
            }
            Button(householdPantryText("Reload pantry access")) { Task { await model.loadGrants() } }
        }.navigationTitle(householdPantryText("Manage pantry access"))
            .disabled(model.busy)
            .task { await model.loadGrants() }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Done")) { dismiss() } } }
            .alert(target?.enabled == true ? householdPantryText("Remove pantry access?") : householdPantryText("Grant pantry access?"),
                   isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), presenting: target) { adult in
                Button(adult.enabled ? householdPantryText("Remove access") : householdPantryText("Grant access"), role: adult.enabled ? .destructive : nil) {
                    Task { await model.changeGrant(adult) }
                }
                Button(ht("Cancel"), role: .cancel) {}
            } message: { adult in Text(verbatim: adult.label) }
    }
}
