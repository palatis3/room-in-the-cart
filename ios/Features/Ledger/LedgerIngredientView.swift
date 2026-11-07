import SwiftUI
import CoreDomain

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
    private enum Focus: Hashable { case status }
    @AccessibilityFocusState private var focus: Focus?
    var body: some View {
        List {
            if let shop, let line {
                Section {
                    Text(line.name).font(.title2.bold())
                    Text(ledgerQuantity(try? shop.quantity(forLineID: lineID))).font(.headline)
                        .accessibilityIdentifier("ledgerIngredientTotal")
                    if !line.notes.isEmpty { Text(line.notes) }
                    if !line.aisle.isEmpty { Text(line.aisle) }
                    NavigationLink(ledgerText("Staple for future pickups")) { StapleApprovalView(ledger: model, shop: shop, line: line) }
                    if pickup.journeys.contains(where: { $0.id == shopID && ($0.basket?.current.lines.contains(where: { $0.id == lineID }) == true || $0.plannedNeeds.contains(where: { $0.orderLineID == lineID })) }) {
                        NavigationLink(pTr("Confirm pantry or freezer food")) {
                            PickupStockEntryView(model: pickup, title: line.name, shopID: shopID, ingredientID: lineID)
                        }
                    }
                    Button(ledgerText("Edit item and visible notes")) { sheet = .line }
                        .disabled(model.saving || model.hasPendingSave)
                    if !line.isTrashed && !line.isHandled {
                        if let workspaceID = model.sourceWorkspaceID,
                           let selection = currentSelection(shop: shop, workspaceID: workspaceID) {
                            if selection.isNoPurchase { Text(ledgerText("Use confirmed food at home · no purchase needed")) }
                            else { Text(ledgerFormat("Reviewed pack choice: %@", selection.selectedOfferID == selection.request.offerA.id ? selection.request.offerA.label : selection.request.offerB.label)) }
                            if let stock = selection.request.confirmedAtHome { Text(ledgerFormat("Confirmed at home for this need: %@", ledgerQuantity(stock))) }
                            if !selection.isNoPurchase, let cost = selection.selectedResult.totalCost { Text(ledgerFormat("Item cost: %@", moneyText(cost))) }
                        } else if model.workspace.packSelections.contains(where: { $0.shopID == shopID && $0.lineID == lineID }) {
                            Text(ledgerText("Review the earlier pack choice again before changing this checkout."))
                        }
                        Button(ledgerText("Choose whole packs for this item")) { sheet = .packs }
                            .disabled(model.saving || model.hasPendingSave).accessibilityIdentifier("ledgerPackChoice")
                    }
                }
                if let workspaceID = model.sourceWorkspaceID, !line.isTrashed {
                    NavigationLink(captureText("Package photos and barcode references")) {
                        PrivateSourceReferenceEntry(target: CaptureTarget(workspaceID: workspaceID,
                            containerID: shopID, objectID: lineID, revision: Int64(shop.revision), kind: .packageReference),
                            initialLabel: line.name, sourceCurrent: {
                                model.ready && !model.saving && !model.hasPendingSave && !model.hasPendingLedgerDeletion &&
                                model.sourceWorkspaceID == workspaceID && model.workspace.selectedShopID == shopID &&
                                model.workspace.shops.first(where: { $0.id == shopID })?.revision == shop.revision &&
                                model.workspace.shops.first(where: { $0.id == shopID })?.lines.contains(where: { $0.id == lineID && !$0.isTrashed }) == true
                            })
                    }.accessibilityIdentifier("ledger.scanReferences")
                }
                Section(ledgerText("Where this need came from")) {
                    let contributions = shop.contributions(forLineID: lineID)
                    if contributions.contains(where: { $0.source.isProtected }) {
                        Toggle(ledgerText("Show protected needs"), isOn: $showProtectedNeeds)
                            .accessibilityIdentifier("ledgerShowProtectedNeeds")
                        if !showProtectedNeeds {
                            Text(ledgerText("Hidden protected needs still count toward the total and whole packs."))
                                .font(.footnote).foregroundStyle(Theme.secondary)
                        }
                    }
                    ForEach(contributions.filter { showProtectedNeeds || !$0.source.isProtected }, id: \.id) { contribution in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(ledgerSourceLabel(contribution, shop: shop)).font(.headline)
                            Text(ledgerQuantity(contribution.quantity))
                            Text(contribution.originalText).font(.footnote).foregroundStyle(Theme.secondary)
                            if !contribution.notes.isEmpty { Text(ledgerContributionNote(contribution.notes)) }
                            if !contribution.exclusions.isEmpty {
                                Text(ledgerFormat("Exclusions: %@", contribution.exclusions.joined(separator: ", ")))
                            }
                            ForEach(shop.allocations.filter { $0.demandContributionID == contribution.id }, id: \.id) { link in
                                Text(ledgerFormat("Linked within existing quantity: %@", ledgerQuantity(link.quantity)))
                                    .font(.footnote)
                            }
                            Button(ledgerText("Edit this contribution")) { sheet = .contribution(contribution.id) }
                                .accessibilityLabel(ledgerFormat("Edit contribution: %@", ledgerSourceLabel(contribution, shop: shop)))
                            if contribution.source.isMeal || contribution.source.isProtected {
                                Button(ledgerText("Link within an existing amount")) { sheet = .link(contribution.id) }
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
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Inspect ingredient"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $sheet) { destination in
                NavigationStack {
                    if let shop, let line {
                        switch destination {
                        case .line: LedgerLineEditor(model: model, shopID: shopID, line: line)
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
    }
    private func currentSelection(shop: ShoppingLedger, workspaceID: UUID) -> LedgerPackSelection? {
        model.workspace.packSelections.reversed().first { selection in
            selection.shopID == shopID && selection.lineID == lineID &&
            (try? LedgerPackStockReview.isCurrent(selection, shop: shop, workspaceID: workspaceID,
                journey: pickup.journeys.first { $0.id == shopID }, pickupWorkspaceID: pickup.sourceWorkspaceID,
                bindings: model.workspace.dinnerPlanning.portionBindings)) == true
        }
    }

}

private struct LedgerLineEditor: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    let line: ShoppingLine
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var notes: String
    @State private var aisle: String
    init(model: LedgerModel, shopID: UUID, line: ShoppingLine) {
        self.model = model; self.shopID = shopID; self.line = line
        _name = State(initialValue: line.name); _notes = State(initialValue: line.notes); _aisle = State(initialValue: line.aisle)
    }
    var body: some View {
        Form {
            Section {
                TextField(ledgerText("Item name"), text: $name, axis: .vertical)
                TextField(ledgerText("Visible notes"), text: $notes, axis: .vertical)
                TextField(ledgerText("Aisle or group"), text: $aisle, axis: .vertical)
            }.disabled(model.saving || model.hasPendingSave)
            Button(ledgerText("Save item")) {
                Task { if await model.editShop(key: "line-\(line.id)", shopID: shopID, { try $0.updateLine(lineID: line.id, name: name, notes: notes, aisle: aisle) }) { dismiss() } }
            }.buttonStyle(PrimaryAction()).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.saving)
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Edit item"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
    }
}

private struct LedgerContributionEditor: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    let contribution: LedgerContribution
    @Environment(\.dismiss) private var dismiss
    @State private var amount: String
    @State private var unit: UnitOfMeasure
    @State private var notes: String
    @State private var validation: String?
    @State private var confirmingRemoval = false
    init(model: LedgerModel, shopID: UUID, contribution: LedgerContribution) {
        self.model = model; self.shopID = shopID; self.contribution = contribution
        _amount = State(initialValue: contribution.quantity.map { ledgerAmountInput($0.amount) } ?? "")
        _unit = State(initialValue: contribution.quantity?.unit ?? .count)
        _notes = State(initialValue: contribution.notes)
    }
    var body: some View {
        Form {
            Section(ledgerText("Original wording")) { Text(contribution.originalText) }
            Section {
                LedgerQuantityFields(amount: $amount, unit: $unit)
                TextField(ledgerText("Contribution notes"), text: $notes, axis: .vertical)
            }.disabled(model.saving || model.hasPendingSave)
            Button(ledgerText("Save contribution")) {
                do {
                    let quantity = try LedgerEntry.quantity(amount, unit)
                    Task { if await model.editShop(key: "contribution-\(contribution.id)", shopID: shopID, { try $0.updateContribution(contributionID: contribution.id, quantity: quantity, notes: notes) }) { dismiss() } }
                } catch { validation = ledgerText("Enter a nonnegative amount with up to six decimal places, or leave it unknown.") }
            }.buttonStyle(PrimaryAction()).disabled(model.saving || model.hasPendingSave)
            Button(ledgerText("Remove only this contribution"), role: .destructive) { confirmingRemoval = true }
                .disabled(model.saving || model.hasPendingSave)
            if let validation { Text(validation).foregroundStyle(Theme.warning) }
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
        }.scrollDismissesKeyboard(.interactively).workingSurface().navigationTitle(ledgerText("Edit contribution"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
            .confirmationDialog(ledgerText("Remove only this contribution?"), isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button(ledgerText("Remove contribution"), role: .destructive) {
                    Task { if await model.editShop(key: "remove-source-\(contribution.id)", shopID: shopID, { try $0.removeContribution(contributionID: contribution.id) }) { dismiss() } }
                }
            } message: { Text(ledgerText("Other sources remain saved. Needs linked to this quantity may require another source.")) }
    }
}

struct LedgerQuantityFields: View {
    @Binding var amount: String
    @Binding var unit: UnitOfMeasure
    var amountFocus: (binding: FocusState<String?>.Binding, id: String)? = nil
    var body: some View {
        let field = TextField(ledgerText("Amount, unknown if blank"), text: $amount).keyboardType(.decimalPad)
        if let amountFocus { field.focused(amountFocus.binding, equals: amountFocus.id) }
        else { field }
        Picker(ledgerText("Unit"), selection: $unit) {
            ForEach(UnitOfMeasure.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
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
        Form {
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
        Form {
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
        Form {
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
