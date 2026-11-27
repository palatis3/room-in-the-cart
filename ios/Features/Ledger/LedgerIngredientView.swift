import SwiftUI
import CoreDomain

private extension ContributionSource {
    var journalMark: JournalSourceKind? {
        switch self {
        case .manual, .imported: .shoppingList
        case .meal, .protectedNeed: nil
        }
    }
}

private enum IngredientSheet: Identifiable {
    case line, contribution(UUID), link(UUID), protectedNeed, handle, trash, packs
    var id: String {
        switch self {
        case .line: return "line"
        case .contribution(let id): return "contribution-\(id)"
        case .link(let id): return "link-\(id)"
        case .protectedNeed: return "protected"
        case .handle: return "handle"
        case .trash: return "trash"
        case .packs: return "packs"
        }
    }
}

struct LedgerIngredientView: View {
    @ObservedObject var model: LedgerModel
    @EnvironmentObject private var pickup: PickupModel
    let shopID: UUID
    let lineID: UUID
    @State private var sheet: IngredientSheet?
    // Presentation only: quantities and pack reviews always use the complete ledger.
    @State private var showProtectedNeeds = true
    private var shop: ShoppingLedger? { model.workspace.shops.first { $0.id == shopID } }
    private var line: ShoppingLine? { shop?.lines.first { $0.id == lineID } }
    private var detailTitle: String {
        shop?.contributions(forLineID: lineID).contains(where: { $0.source.isMeal }) == true
            ? ledgerText("Inspect ingredient") : tripText("Item details")
    }
    private enum Focus: Hashable { case status }
    @AccessibilityFocusState private var focus: Focus?
    var body: some View {
        JournalList {
            if let shop, let line {
                let contributions = shop.contributions(forLineID: lineID)
                let typedItemBatches = shop.typedItemBatchIDs
                let primaryQuantitySource = shop.ordinaryQuantitySource(for: line, contributions: contributions,
                                                                   typedItemBatches: typedItemBatches)
                Section {
                    Text(line.name).font(.title2.bold())
                    if let amount = shop.shoppingRowQuantity(for: line) {
                        Text(amount).font(.headline).accessibilityIdentifier("ledgerIngredientTotal")
                    }
                    if let primaryQuantitySource {
                        Button { sheet = .contribution(primaryQuantitySource.id) } label: { editQuantityLabel }
                            .accessibilityIdentifier("ledgerEditQuantityAndNotes")
                            .disabled(model.saving || model.hasPendingSave)
                    }
                    if !line.notes.isEmpty { Text(line.notes) }
                    if let barcode = shop.importBatches.lazy.filter({ $0.undoneAt == nil })
                        .compactMap({ $0.preview.lines.first(where: { $0.proposedLineID == lineID })?.csvRecord?.barcode })
                        .first(where: { !$0.isEmpty }) {
                        LabeledContent(ledgerText("Barcode"), value: barcode)
                    }
                    let department = model.workspace.listLayout.department(for: line, in: shop)
                    if !department.isEmpty { Text(department) }
                    NavigationLink(ledgerText("Staple for future pickups")) { StapleApprovalView(ledger: model, shop: shop, line: line) }
                    if pickup.journeys.contains(where: { $0.id == shopID && ($0.basket?.current.lines.contains(where: { $0.id == lineID }) == true || $0.plannedNeeds.contains(where: { $0.orderLineID == lineID })) }) {
                        NavigationLink(pTr("Confirm pantry or freezer food")) {
                            PickupStockEntryView(model: pickup, title: line.name, shopID: shopID, ingredientID: lineID)
                        }
                    }
                    Button(quickGroceryText("Edit name, notes and department")) { sheet = .line }
                        .accessibilityIdentifier("ledgerEditItemDetails")
                        .disabled(model.saving || model.hasPendingSave)
                    if !line.isTrashed && !line.isHandled {
                        if let workspaceID = model.sourceWorkspaceID,
                           let selection = currentSelection(shop: shop, workspaceID: workspaceID) {
                            if selection.isNoPurchase { Text(ledgerText("Use confirmed food at home · no purchase needed")) }
                            else {
                                let offer = selection.selectedOfferID == selection.request.offerA.id ? selection.request.offerA : selection.request.offerB
                                Text(ledgerFormat("Reviewed pack choice: %@", offer.label))
                                if let basis = offer.confirmedConversion {
                                    Text(ComparisonConversion.readableText(for: basis))
                                }
                            }
                            if let stock = selection.request.confirmedAtHome { Text(ledgerFormat("Confirmed at home for this need: %@", ledgerQuantity(stock))) }
                            if !selection.isNoPurchase, let cost = selection.selectedResult.totalCost { Text(ledgerFormat("Item cost: %@", moneyText(cost))) }
                        } else if model.workspace.packSelections.contains(where: { $0.shopID == shopID && $0.lineID == lineID }) {
                            Text(ledgerText("Review the earlier pack choice again before changing this checkout."))
                        }
                        Button(ledgerText("Choose whole packs for this item")) { sheet = .packs }
                            .disabled(model.saving || model.hasPendingSave).accessibilityIdentifier("ledgerPackChoice")
                    }
                }
                PrivatePackagePhotoLink(model: model, shop: shop, line: line)
                TripItemSettingsLink(model: model, shop: shop, line: line)
                Section(ledgerText("Where this need came from")) {
                    if contributions.contains(where: { $0.source.isProtected }) {
                        Toggle(ledgerText("Show protected needs"), isOn: $showProtectedNeeds)
                            .accessibilityIdentifier("ledgerShowProtectedNeeds")
                        if !showProtectedNeeds {
                            Text(ledgerText("Hidden protected needs still count toward the total and whole packs."))
                                .font(.footnote).foregroundStyle(Theme.secondary)
                        }
                    }
                    ForEach(contributions.filter { showProtectedNeeds || !$0.source.isProtected }, id: \.id) { contribution in
                        let source = ledgerSourceLabel(contribution, shop: shop, typedItemBatches: typedItemBatches)
                        VStack(alignment: .leading, spacing: 8) {
                            JournalSourceLabel(kind: contribution.source.journalMark, title: source).font(.headline)
                            Text(contribution.sourceQuantityLabel)
                            Text(contribution.originalText).font(.footnote).foregroundStyle(Theme.secondary)
                            if let pack = contribution.originalPack { LedgerPackLabelFacts(pack: pack) }
                            let displayedNote = ledgerEditableNote(contribution)
                            if !displayedNote.isEmpty { Text(displayedNote) }
                            if !contribution.exclusions.isEmpty {
                                Text(ledgerFormat("Exclusions: %@", ledgerExclusionsText(contribution.exclusions)))
                            }
                            ForEach(shop.allocations.filter { $0.demandContributionID == contribution.id }, id: \.id) { link in
                                Text(ledgerFormat("Linked within existing quantity: %@", ledgerQuantity(link.quantity)))
                                    .font(.footnote)
                            }
                            if primaryQuantitySource?.id != contribution.id {
                                Button { sheet = .contribution(contribution.id) } label: { editQuantityLabel }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(quickGroceryFormat("Edit quantity and notes for %@", source))
                            }
                            if contribution.source.isMeal || contribution.source.isProtected {
                                Button { sheet = .link(contribution.id) } label: {
                                    Text(ledgerText("Link within an existing amount"))
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                            }
                        }.padding(.vertical, 6).disabled(model.saving || model.hasPendingSave)
                    }
                }
                Section {
                    Button(ledgerText("Protect an amount for lunch or another need")) { sheet = .protectedNeed }
                    Button(ledgerText("Mark handled by someone")) { sheet = .handle }
                    if line.trashedAt == nil {
                        Button(ledgerText("Review removing this item"), role: .destructive) { sheet = .trash }
                    }
                }.disabled(model.saving || model.hasPendingSave)
                Section {
                    Text(ledgerText("Linking uses the amount already listed. Adding demand increases the list. A whole-pack choice keeps these ingredient needs and supplies the purchased amount at checkout review."))
                        .font(.footnote).foregroundStyle(Theme.secondary)
                }
            }
            LedgerSaveStatus(model: model).accessibilityFocused($focus, equals: .status)
        }.scrollDismissesKeyboard(.interactively).navigationTitle(detailTitle)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $sheet) { destination in
                NavigationStack {
                    if let shop, let line {
                        switch destination {
                        case .line: LedgerLineEditor(model: model, shop: shop, line: line)
                        case .contribution(let id):
                            if let value = shop.contributions.first(where: { $0.id == id }) {
                                LedgerContributionEditor(model: model, shopID: shopID, contribution: value)
                            }
                        case .link(let id): LedgerLinkView(model: model, shop: shop, contributionID: id)
                        case .protectedNeed: LedgerProtectedNeedView(model: model, shop: shop, line: line)
                        case .handle: LedgerHandleView(model: model, shopID: shopID, lineID: lineID)
                        case .trash: LedgerTrashView(model: model, shop: shop, line: line)
                        case .packs: LedgerPackChoiceView(model: model, shopID: shopID, lineID: lineID)
                        }
                    }
                }
            }
            .onChange(of: model.error) { _, value in if value != nil { focus = .status } }
            .onChange(of: shopID) { _, _ in showProtectedNeeds = true }
            .onChange(of: lineID) { _, _ in showProtectedNeeds = true }
            .task {
                await pickup.load()
                if pickup.pantryIsActive { _ = await pickup.refreshPantryStock() }
            }
    }

    private var editQuantityLabel: some View {
        Text(quickGroceryText("Edit quantity and notes"))
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }

    private func currentSelection(shop: ShoppingLedger, workspaceID: UUID) -> LedgerPackSelection? {
        model.workspace.packSelections.reversed().first { selection in
            selection.shopID == shopID && selection.lineID == lineID &&
            pickup.isPackSelectionCurrent(selection, shop: shop, workspaceID: workspaceID,
                bindings: model.workspace.dinnerPlanning.portionBindings)
        }
    }

}

extension ShoppingLedger {
    func ordinaryQuantitySource(for line: ShoppingLine,
                                contributions: [LedgerContribution], typedItemBatches: Set<UUID>) -> LedgerContribution? {
        guard !line.isTrashed, !line.isHandled, !line.isChecked, contributions.count == 1,
              let source = contributions.first,
              !allocations.contains(where: { $0.supplyContributionID == source.id || $0.demandContributionID == source.id })
        else { return nil }
        switch source.source {
        case .manual: return source
        case .imported(let batchID) where typedItemBatches.contains(batchID): return source
        default: return nil
        }
    }
}

struct LedgerLineEditor: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let line: ShoppingLine
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var notes: String
    @State private var aisle: String
    @State private var remember = false
    @State private var baseRevision: Int64
    @State private var workspaceID: UUID?
    @State private var originalDepartment: String
    @FocusState private var nameFocused: Bool
    private var hasEdits: Bool { name != line.name || notes != line.notes || aisle != originalDepartment || remember }
    init(model: LedgerModel, shop: ShoppingLedger, line: ShoppingLine) {
        self.model = model; self.shop = shop; self.line = line
        let department = model.workspace.listLayout.department(for: line, in: shop)
        _name = State(initialValue: line.name); _notes = State(initialValue: line.notes)
        _aisle = State(initialValue: department); _originalDepartment = State(initialValue: department)
        _baseRevision = State(initialValue: model.revision)
        _workspaceID = State(initialValue: model.sourceWorkspaceID)
    }
    var body: some View {
        WorkingForm {
            Section {
                WorkingField(ledgerText("Item name")) {
                    TextField(ledgerText("Item name"), text: $name, prompt: Text(verbatim: ""))
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .submitLabel(.done).onSubmit { nameFocused = false }
                        .accessibilityIdentifier("ledgerEditItemName")
                }
                WorkingField(ledgerText("Visible notes")) {
                    TextField(ledgerText("Visible notes"), text: $notes, prompt: Text(verbatim: ""), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                }
                WorkingField(quickGroceryText("Department")) {
                    TextField(quickGroceryText("Department"), text: $aisle, prompt: Text(verbatim: ""), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                }
                if !shop.currentStop.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Picker(ledgerText("Department assignment"), selection: $remember) {
                        Text(ledgerText("This row")).tag(false)
                        Text(ledgerText("Remember at this store")).tag(true)
                    }
                    if remember {
                        Text(verbatim: shop.currentStop.name).font(.footnote)
                    }
                }
            }.disabled(model.saving || model.hasPendingSave)
            Button(ledgerText("Save item")) {
                Task {
                    let saved = await model.change(key: "line-\(line.id)", reviewedPantryBasis: nil, authorize: {
                        workspaceID != nil && model.sourceWorkspaceID == workspaceID &&
                            model.revision == baseRevision && model.shop?.id == shop.id
                    }) { workspace in
                        guard model.revision == baseRevision, workspace.selectedShopID == shop.id,
                              let index = workspace.shops.firstIndex(where: { $0.id == shop.id }),
                              let source = workspace.shops[index].lines.first(where: { $0.id == line.id }) else { throw LedgerError.stalePreview }
                        if name != source.name || notes != source.notes {
                            try workspace.shops[index].updateLine(lineID: line.id, name: name, notes: notes, aisle: source.aisle)
                        }
                        if remember || aisle != originalDepartment {
                            let current = workspace.shops[index]
                            guard let edited = current.lines.first(where: { $0.id == line.id }) else { throw LedgerError.stalePreview }
                            try workspace.listLayout.setDepartment(aisle, for: edited, in: current, remember: remember)
                        }
                    }
                    if saved { dismiss() }
                }
            }.buttonStyle(PrimaryAction()).disabled(!hasEdits || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.saving || model.hasPendingSave)
            GroceryEditStatus(model: model, hasEdits: hasEdits, onRetried: { dismiss() })
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Edit item"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
    }
}

private struct GroceryEditStatus: View {
    @ObservedObject var model: LedgerModel
    let hasEdits: Bool
    let onRetried: () -> Void

    var body: some View {
        if model.saving || model.hasPendingSave || model.error != nil {
            LedgerSaveStatus(model: model, showsLastSave: false, onRetried: onRetried)
        } else if hasEdits {
            Text(quickGroceryText("Unsaved edits")).foregroundStyle(Theme.secondary)
                .accessibilityIdentifier("ledgerUnsavedItem")
        }
    }
}

enum GroceryEntryUnit: Hashable {
    case measure(UnitOfMeasure)
    case package(GroceryPackageCount.Kind)

    init(_ contribution: LedgerContribution) {
        if let packages = contribution.reviewedPackages { self = .package(packages.kind) }
        else { self = .measure(contribution.quantity?.unit ?? .count) }
    }

    var displayName: String {
        switch self {
        case .measure(let measure): measure.displayName
        case .package(let kind): kind.label()
        }
    }

    var invalidAmountMessage: String {
        switch self {
        case .package: quickGroceryText("Enter a positive whole number of packages, or leave the quantity blank.")
        case .measure: ledgerText("Enter a nonnegative amount with up to six decimal places, or leave it unknown.")
        }
    }

    @MainActor func parse(_ text: String) throws -> (quantity: Quantity?, packages: GroceryPackageCount?) {
        switch self {
        case .package(let kind):
            guard let count = try LedgerEntry.rational(text) else { return (nil, nil) }
            guard count.denominator == 1, count > .zero else { throw EntryError.invalidNumber }
            return (nil, GroceryPackageCount(count: count.numerator, kind: kind))
        case .measure(let measure):
            return (try LedgerEntry.quantity(text, measure), nil)
        }
    }
}

struct GroceryUnitPicker: View {
    @Binding var unit: GroceryEntryUnit
    let allowsPackages: Bool

    var body: some View {
        Picker(ledgerText("Unit"), selection: $unit) {
            Text(UnitOfMeasure.count.displayName).tag(GroceryEntryUnit.measure(.count))
            if allowsPackages {
                ForEach(GroceryPackageCount.Kind.allCases, id: \.self) { kind in
                    Text(kind.label()).tag(GroceryEntryUnit.package(kind))
                }
            }
            ForEach(UnitOfMeasure.allCases.filter { $0 != .count }, id: \.self) { unit in
                Text(unit.displayName).tag(GroceryEntryUnit.measure(unit))
            }
        }
        .accessibilityValue(Text(verbatim: unit.displayName))
    }
}

private extension LedgerContribution {
    var editableAmount: String {
        if let packages = reviewedPackages { return String(packages.count) }
        return quantity.map { ledgerAmountInput($0.amount) } ?? ""
    }
}

struct LedgerContributionEditor: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    let contribution: LedgerContribution
    let authorize: (@MainActor () -> Bool)?
    private let onFinish: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var amount: String
    @State private var unit: GroceryEntryUnit
    @State private var notes: String
    @State private var validation: String?
    @State private var confirmingRemoval = false
    @FocusState private var focusedField: String?
    private var hasEdits: Bool {
        amount != contribution.editableAmount || unit != GroceryEntryUnit(contribution) || notes != ledgerEditableNote(contribution)
    }

    init(model: LedgerModel, shopID: UUID, contribution: LedgerContribution,
         authorize: (@MainActor () -> Bool)? = nil, onFinish: (() -> Void)? = nil) {
        self.onFinish = onFinish
        self.authorize = authorize
        self.model = model; self.shopID = shopID; self.contribution = contribution
        _amount = State(initialValue: contribution.editableAmount)
        _unit = State(initialValue: GroceryEntryUnit(contribution))
        _notes = State(initialValue: ledgerEditableNote(contribution))
    }
    var body: some View {
        WorkingForm {
            Section {
                Text(verbatim: contribution.productName)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("ledgerContributionName")
                if contribution.originalText != contribution.productName {
                    Text(verbatim: ledgerFormat("Original wording: %@", contribution.originalText))
                        .font(.subheadline).foregroundStyle(Theme.secondary)
                }
            }
            Section {
                LedgerAmountField(amount: $amount, amountFocus: ($focusedField, "amount"), amountLabel: shoppingText("Quantity (optional)"))
                GroceryUnitPicker(unit: $unit, allowsPackages: contribution.canEditPackageCount)
                    .accessibilityIdentifier("ledgerContributionUnit")
                WorkingField(ledgerText("Contribution notes")) {
                    TextField(ledgerText("Contribution notes"), text: $notes, prompt: Text(verbatim: ""), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: "notes")
                        .accessibilityIdentifier("ledgerContributionNotes")
                }
            }.disabled(model.saving || model.hasPendingSave)
            Button(ledgerText("Remove only this contribution"), role: .destructive) { confirmingRemoval = true }
                .foregroundStyle(Theme.error)
                .disabled(model.saving || model.hasPendingSave)
            if let validation { Text(validation).foregroundStyle(Theme.warning) }
            GroceryEditStatus(model: model, hasEdits: hasEdits, onRetried: { finish() })
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(quickGroceryText("Quantity and notes"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { finish() }.disabled(model.saving) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 12) {
                    if focusedField != nil {
                        Button { focusedField = nil } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(quickGroceryText("Dismiss keyboard"))
                        .accessibilityIdentifier("ledgerContributionDone")
                    }
                    Button(ledgerText("Save changes"), action: save)
                        .buttonStyle(PrimaryAction())
                        .disabled(!hasEdits || model.saving || model.hasPendingSave)
                        .accessibilityIdentifier("ledgerSaveContributionChanges")
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
                .background(.bar)
            }
            .interactiveDismissDisabled(model.saving)
            .confirmationDialog(ledgerText("Remove only this contribution?"), isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button(ledgerText("Remove contribution"), role: .destructive) {
                    Task { if await model.editShop(key: "remove-source-\(contribution.id)", shopID: shopID, authorize: authorize, { try $0.removeContribution(contributionID: contribution.id) }) { finish() } }
                }
            } message: { Text(ledgerText("Other sources remain saved. Needs linked to this quantity may require another source.")) }
    }

    private func finish() {
        if let onFinish { onFinish() } else { dismiss() }
    }

    private func save() {
        let quantity: Quantity?
        let packages: GroceryPackageCount?
        if amount == contribution.editableAmount && unit == GroceryEntryUnit(contribution) {
            (quantity, packages) = (contribution.quantity, contribution.reviewedPackages)
        } else {
            do { (quantity, packages) = try unit.parse(amount) }
            catch { validation = unit.invalidAmountMessage; return }
        }
        let savedNotes = notes == ledgerEditableNote(contribution) ? contribution.notes : notes
        focusedField = nil
        Task {
            let saved = await model.editShop(key: "contribution-\(contribution.id)", shopID: shopID, authorize: authorize) { current in
                try current.updateContribution(contributionID: contribution.id, quantity: quantity, notes: savedNotes, reviewedPackages: packages)
            }
            if saved { finish() }
        }
    }
}

struct LedgerQuantityFields: View {
    @Binding var amount: String
    @Binding var unit: UnitOfMeasure
    var amountFocus: (binding: FocusState<String?>.Binding, id: String)? = nil
    var amountLabel: String? = nil

    var body: some View {
        LedgerAmountField(amount: $amount, amountFocus: amountFocus, amountLabel: amountLabel)
        Picker(ledgerText("Unit"), selection: $unit) {
            ForEach(UnitOfMeasure.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
    }
}

private struct LedgerAmountField: View {
    @Binding var amount: String
    let amountFocus: (binding: FocusState<String?>.Binding, id: String)?
    let amountLabel: String?

    @ViewBuilder private var amountField: some View {
        let title = amountLabel ?? ledgerText("Amount, unknown if blank")
        let field = TextField(title, text: $amount, prompt: amountLabel == nil ? nil : Text(verbatim: "—"))
            .keyboardType(.numbersAndPunctuation)
        if let amountFocus { field.focused(amountFocus.binding, equals: amountFocus.id) }
        else { field }
    }

    var body: some View {
        if let amountLabel {
            let row = WorkingField(amountLabel) { amountField }
            if let amountFocus {
                row.dinnerInputRow(amountFocus.binding, field: amountFocus.id)
                    .id(amountFocus.id)
            } else {
                row
            }
        } else { amountField }
    }
}

private struct LedgerLinkView: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let contributionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var supplyID: UUID?
    @State private var amount = ""
    @State private var unit: UnitOfMeasure = .count
    @State private var validation: String?
    var body: some View {
        WorkingForm {
            Section {
                Text(ledgerText("Use part of an amount already listed. For example, linking six taco wraps within twelve listed wraps keeps twelve on the list."))
                Picker(ledgerText("Existing contribution"), selection: $supplyID) {
                    Text(ledgerText("Choose an existing amount")).tag(Optional<UUID>.none)
                    ForEach(shop.contributions.filter { $0.id != contributionID && $0.removedAt == nil && $0.source.canSupplyExistingQuantity }, id: \.id) { supply in
                        Text("\(supply.productName) · \(ledgerQuantity(supply.quantity))").tag(Optional(supply.id))
                    }
                }
                LedgerQuantityFields(amount: $amount, unit: $unit)
            }.disabled(model.saving || model.hasPendingSave)
            Button(ledgerText("Link within existing quantity")) {
                do {
                    guard let supplyID, let quantity = try LedgerEntry.quantity(amount, unit) else {
                        validation = ledgerText("Choose an existing amount and enter the quantity to link."); return
                    }
                    Task { if await model.editShop(key: "link-\(contributionID)", shopID: shop.id, { try $0.linkContribution(contributionID: contributionID, within: supplyID, quantity: quantity) }) { dismiss() } }
                } catch { validation = ledgerText("Enter a nonnegative amount with up to six decimal places, or leave it unknown.") }
            }.buttonStyle(PrimaryAction()).disabled(model.saving || model.hasPendingSave)
            if let validation { Text(validation).foregroundStyle(Theme.warning) }
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Link existing quantity"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
    }
}

private struct LedgerProtectedNeedView: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let line: ShoppingLine
    @Environment(\.dismiss) private var dismiss
    @State private var purpose = ""
    @State private var amount = ""
    @State private var unit: UnitOfMeasure = .count
    @State private var supplyID: UUID?
    @State private var validation: String?
    var body: some View {
        WorkingForm {
            Section {
                TextField(ledgerText("Who or what this is for"), text: $purpose, axis: .vertical)
                LedgerQuantityFields(amount: $amount, unit: $unit)
                Picker(ledgerText("How to reserve it"), selection: $supplyID) {
                    Text(ledgerText("Add a new amount")).tag(Optional<UUID>.none)
                    ForEach(shop.contributions(forLineID: line.id).filter { $0.source.canSupplyExistingQuantity }, id: \.id) { contribution in
                        Text(ledgerFormat("Within %@", ledgerQuantity(contribution.quantity))).tag(Optional(contribution.id))
                    }
                }.accessibilityIdentifier("ledgerProtectedReservation")
            }.disabled(model.saving || model.hasPendingSave)
            Button(ledgerText("Save protected need")) {
                do {
                    guard let quantity = try LedgerEntry.quantity(amount, unit), !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        validation = ledgerText("Enter the protected quantity and who or what it is for."); return
                    }
                    Task { if await model.editShop(key: "protected-\(line.id)", shopID: shop.id, { _ = try $0.addProtectedNeed(name: line.name, quantity: quantity, purpose: purpose, within: supplyID) }) { dismiss() } }
                } catch { validation = ledgerText("Enter a nonnegative amount with up to six decimal places, or leave it unknown.") }
            }.buttonStyle(PrimaryAction()).disabled(model.saving || model.hasPendingSave)
            if let validation { Text(validation).foregroundStyle(Theme.warning) }
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Protect a need"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
    }
}

private struct LedgerHandleView: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    let lineID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var who = ""
    var body: some View {
        WorkingForm {
            Text(ledgerText("Handling records who took care of this need. Checking only records list progress."))
            TextField(ledgerText("Handled by"), text: $who).disabled(model.saving || model.hasPendingSave)
                .accessibilityIdentifier("ledgerHandledBy")
            Button(ledgerText("Mark handled")) {
                Task { if await model.editShop(key: "handle-\(lineID)", shopID: shopID, { try $0.handle(lineID: lineID, by: who) }) { dismiss() } }
            }.buttonStyle(PrimaryAction()).disabled(who.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.saving)
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Handle this need"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
    }
}

private struct LedgerTrashView: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let line: ShoppingLine
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                Text(line.name).font(.headline)
                Text(ledgerText("This item will leave the active list. Its sources remain saved, and you can restore it from Trash in its original position."))
            }
            Section(ledgerText("Active needs affected")) {
                let affected = (try? shop.trashImpact(lineID: line.id)) ?? []
                if affected.isEmpty { Text(ledgerText("No active meal or protected need is linked to this item.")) }
                ForEach(affected, id: \.id) { need in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(need.productName)
                        Text(ledgerQuantity(need.quantity))
                        Text(ledgerText("This need will remain unresolved until you restore or replace the item."))
                    }
                }
            }
            Section {
                Button(ledgerText("Move item to Trash"), role: .destructive) {
                    Task { if await model.editShop(key: "trash-\(line.id)", shopID: shop.id, { try $0.trash(lineID: line.id) }) { dismiss() } }
                }.disabled(model.saving).frame(minHeight: 44)
                LedgerSaveStatus(model: model, onRetried: { dismiss() })
            }
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Review item removal"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
    }
}
