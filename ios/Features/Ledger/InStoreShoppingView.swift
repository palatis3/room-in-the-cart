import SwiftUI
import CoreDomain

func shoppingText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "ShoppingLists")
}

func shoppingFormat(_ key: String, _ values: CVarArg...) -> String {
    String(format: shoppingText(key), locale: Locale.current, arguments: values)
}

private struct ShoppingListAuthorizationKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Bool = { false }
}

extension EnvironmentValues {
    var shoppingListAuthorization: @MainActor () -> Bool {
        get { self[ShoppingListAuthorizationKey.self] }
        set { self[ShoppingListAuthorizationKey.self] = newValue }
    }
}

struct PrivateShoppingSheet<Content: View>: View {
    @ObservedObject var model: LedgerModel
    @ViewBuilder let content: () -> Content
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.guardianChildCoordinator) private var child
    @State private var identity: CapturePrivateIdentity?
    @State private var workspaceID: UUID?

    var body: some View {
        Group {
            if authorized() {
                NavigationStack { content() }
                    .environment(\.shoppingListAuthorization, authorized)
            } else { Text(captureText("Unlock your private workspace to review this source.")) }
        }.onAppear {
            if workspaceID == nil {
                workspaceID = model.sourceWorkspaceID
                identity = CapturePrivateIdentity.current(access: access, household: household)
            }
        }
    }

    private func authorized() -> Bool {
        scenePhase == .active && UIApplication.shared.isProtectedDataAvailable && UIApplication.shared.applicationState == .active &&
            model.ready && !model.hasPendingLedgerDeletion && workspaceID != nil && workspaceID == model.sourceWorkspaceID &&
            identity != nil && identity == CapturePrivateIdentity.current(access: access, household: household) &&
            household.projection?.grantId == nil && child?.presented != true
    }
}

/// Feedback belongs to the confirmed item. Its dated schedule ends after 120 ms
/// and cannot replay when the row is reused or the app returns to the foreground.
struct GroceryCheckCue {
    let lineID: UUID
    let began = Date()
}

struct GroceryCheckInset: View {
    let cue: GroceryCheckCue?
    let lineID: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scene
    var body: some View {
        if let cue, cue.lineID == lineID, !reduceMotion, scene == .active, Date().timeIntervalSince(cue.began) < 0.12 {
            let frames = (0...8).map { cue.began.addingTimeInterval(Double($0) * 0.015) }
            TimelineView(.explicit(frames)) { frame in
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.action, lineWidth: 2)
                    .opacity(max(0, min(1, 1 - frame.date.timeIntervalSince(cue.began) / 0.12)))
            }
            .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

struct InStoreShoppingView: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    @Environment(\.shoppingListAuthorization) private var authorize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var cue: GroceryCheckCue?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scene
    @State private var editingPrice: ShoppingLine?
    private enum Focus: Hashable { case line(UUID), subtotal }
    @AccessibilityFocusState private var focus: Focus?
    @State private var pendingFocus: Focus?

    var body: some View {
        Group {
            if let shop = model.shop, shop.id == shopID {
                let groups = model.workspace.listLayout.groups(shop: shop)
                let visible = groups.flatMap(\.lines)
                let exclusionsByLine = shop.listExclusions
                let picked = shop.recentlyChecked.filter { !$0.isHandled }
                ScrollViewReader { reader in
                    List {
                        if model.error != nil || model.hasPendingSave { LedgerSaveStatus(model: model) }
                        ForEach(groups) { group in
                            if !group.lines.isEmpty {
                                Section(group.aisle.isEmpty ? shoppingText("To pick") : group.aisle) {
                                    ForEach(group.lines) { line in
                                        let quantity = shop.shoppingRowQuantity(for: line)
                                        Button {
                                            let index = visible.firstIndex(where: { $0.id == line.id }) ?? 0
                                            let others = visible.filter { $0.id != line.id }
                                            let next = others.isEmpty ? nil : others[min(index, others.count - 1)].id
                                            changePick(line, in: shop, checked: true, next: next)
                                        } label: {
                                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                Image(systemName: "square").font(.title3).foregroundStyle(Theme.controlEdge)
                                                    .frame(width: 44)
                                                VStack(alignment: .leading) {
                                                    Text(line.name).font(.headline)
                                                    if let quantity { Text(quantity).font(.subheadline) }
                                                    if !line.notes.isEmpty { Text(line.notes) }
                                                    if let exclusions = exclusionsByLine[line.id] { Text(exclusions) }
                                                }
                                            }.frame(minHeight: 48)
                                        }.accessibilityLabel(ledgerFormat("Check %@", line.name))
                                        .accessibilityValue(Text([quantity ?? "",
                                            line.notes, exclusionsByLine[line.id] ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")))
                                        .accessibilityFocused($focus, equals: .line(line.id))
                                        .accessibilityIdentifier("inStoreCheck-\(line.id)")
                                        .id(line.id)
                                    }
                                }
                            }
                        }
                        if visible.isEmpty { Text(shoppingText("No items left to pick.")) }
                        if !picked.isEmpty {
                            Section(shoppingText("Picked items")) {
                                ForEach(picked) { line in
                                    pickedRow(line, in: shop)
                                }
                            }
                        }
                        if typeSize.isAccessibilitySize {
                            Section { subtotalSummary(shop, last: picked.first).id(Focus.subtotal) }
                        }
                    }
                    .workingSurface()
                    .disabled(model.saving)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if !typeSize.isAccessibilitySize {
                            subtotalSummary(shop, last: picked.first)
                                .padding(.horizontal).padding(.vertical, 6).background(Theme.surface)
                                .overlay(alignment: .top) { Divider() }
                        }
                    }
                    .onChange(of: pendingFocus) { _, target in
                        guard let target else { return }
                        if UIAccessibility.isVoiceOverRunning {
                            switch target {
                            case .line(let id): reader.scrollTo(id, anchor: .center)
                            case .subtotal:
                                if typeSize.isAccessibilitySize { reader.scrollTo(Focus.subtotal, anchor: .top) }
                            }
                        }
                        Task { @MainActor in
                            await Task.yield()
                            focus = target
                            pendingFocus = nil
                        }
                    }
                }
                .sheet(item: $editingPrice) { line in
                    NavigationStack { PickedPriceEditor(model: model, shop: shop, line: line) }
                }
            }
        }.navigationTitle(shoppingText("Shop in store"))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ledgerText("Done")) { dismiss() } } }
    }

    private func pickedRow(_ line: ShoppingLine, in shop: ShoppingLedger) -> some View {
        let undo = shoppingFormat("Undo pick of %@", line.name)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                changePick(line, in: shop, checked: false, next: line.id)
            } label: {
                Image(systemName: "checkmark.square.fill").font(.title3)
                    .foregroundStyle(Theme.action)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(shoppingFormat("Uncheck %@", line.name))
            .accessibilityIdentifier("inStoreUncheck-\(line.id)")
            .disabled(model.hasPendingSave)

            Button { editingPrice = line } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.name).font(.headline).foregroundStyle(Theme.ink)
                        Text(priceLabel(shop.priceForCurrentPick(lineID: line.id)))
                            .foregroundStyle(Theme.secondary).monospacedDigit()
                    }
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: "pencil").font(.footnote).foregroundStyle(Theme.action)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityHint(shoppingText("Edit the price for the entire picked amount."))
            .accessibilityIdentifier("inStorePrice-\(line.id)")
            .accessibilityAction(named: Text(undo)) {
                changePick(line, in: shop, checked: false, next: line.id)
            }
        }
        .buttonStyle(.borderless)
        .overlay { GroceryCheckInset(cue: cue, lineID: line.id).allowsHitTesting(false) }
    }

    private func subtotalSummary(_ shop: ShoppingLedger, last: ShoppingLine?) -> some View {
        let subtotal = shop.pickedCartSubtotal
        return VStack(alignment: .leading, spacing: 5) {
            Text(shoppingFormat("%@ for %lld of %lld picked items", moneyText(subtotal.total),
                Int64(subtotal.priced), Int64(subtotal.picked))).font(.headline).monospacedDigit()
                .accessibilityFocused($focus, equals: .subtotal)
                .accessibilityIdentifier("inStoreSubtotal")
            Text(shoppingText("Entered item totals before checkout charges.")).font(.footnote)
            if let last {
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 12))
                layout { lastPickActions(last, shop: shop) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .disabled(model.saving || model.hasPendingSave)
    }

    @ViewBuilder private func lastPickActions(_ last: ShoppingLine, shop: ShoppingLedger) -> some View {
        Button(shoppingText("Enter price")) { editingPrice = last }
            .frame(minHeight: 44)
            .accessibilityLabel(shoppingFormat("Enter price for %@", last.name))
            .accessibilityIdentifier("inStoreLastPrice")
        Button(shoppingFormat("Undo pick of %@", last.name)) {
            changePick(last, in: shop, checked: false, next: last.id)
        }.frame(minHeight: 44).accessibilityIdentifier("inStoreUndo")
    }

    private func priceLabel(_ price: PickedLinePrice?) -> String {
        guard let price else { return shoppingText("Price unknown · enter total") }
        var parts = [price.total.map { shoppingFormat("Saved price · %@", moneyText($0)) } ?? shoppingText("Price unknown")]
        if price.membership { parts.append(shoppingText("Member price")) }
        if price.weighted { parts.append(shoppingText("Sold by weight")) }
        if price.includedTotal == nil { parts.append(shoppingText("Excluded from subtotal")) }
        return parts.joined(separator: " · ")
    }

    private func changePick(_ line: ShoppingLine, in shop: ShoppingLedger, checked: Bool, next: UUID?) {
        Task {
            guard !model.hasPendingSave, await model.editShop(key: "pick-\(line.id)", shopID: shop.id, authorize: authorize, { current in
                guard model.workspace.selectedShopID == shopID, current.revisionID == shop.revisionID,
                      current.lines.contains(where: { $0.id == line.id && !$0.isHandled && !$0.isTrashed }) else { throw LedgerError.stalePreview }
                try current.setChecked(lineID: line.id, checked: checked)
            }) else { return }
            cue = checked && !reduceMotion && scene == .active ? GroceryCheckCue(lineID: line.id) : nil
            pendingFocus = next.map(Focus.line) ?? .subtotal
        }
    }
}

private struct PickedPriceEditor: View {
    @ObservedObject var model: LedgerModel
    let shopID: UUID
    @Environment(\.shoppingListAuthorization) private var authorize
    let line: ShoppingLine
    @State private var revision: UUID
    @State private var amount: String
    @State private var membership: Bool
    @State private var weighted: Bool
    @State private var confirmed: Bool
    @FocusState private var editingAmount: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: LedgerModel, shop: ShoppingLedger, line: ShoppingLine) {
        self.model = model
        self.shopID = shop.id
        self.line = line
        _revision = State(initialValue: shop.revisionID)
        let price = shop.priceForCurrentPick(lineID: line.id)
        _amount = State(initialValue: price?.total.map { (Decimal($0.minorUnits) / 100).description } ?? "")
        _membership = State(initialValue: price?.membership ?? false)
        _weighted = State(initialValue: price?.weighted ?? false)
        _confirmed = State(initialValue: price?.conditionsConfirmed ?? false)
    }

    var body: some View {
        WorkingForm {
            Section {
                workingTextField(shoppingText("Total for this picked amount ($)"), text: $amount).keyboardType(.decimalPad)
                    .focused($editingAmount).accessibilityIdentifier("inStoreAmount")
                Text(shoppingText("Enter the total for all packs or the weighed amount. Leave blank for unknown.")).font(.footnote)
                Toggle(shoppingText("Member price"), isOn: $membership)
                Toggle(shoppingText("Sold by weight"), isOn: $weighted)
                if membership || weighted {
                    Toggle(shoppingText("I confirmed the applicable total"), isOn: $confirmed)
                    Text(shoppingText("The subtotal includes this price once you confirm the membership conditions and actual weight that apply.")).font(.footnote)
                }
            } header: {
                Text(verbatim: line.name).font(.headline).foregroundStyle(Theme.ink).textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !validAmount { Text(shoppingText("Enter a nonnegative dollar amount with up to two decimal places.")) }
            if model.hasPendingSave || model.error != nil {
                LedgerSaveStatus(model: model, showsLastSave: false, onRetried: { dismiss() })
            } else if model.saving {
                ProgressView(shoppingText("Saving price…"))
            }
            Button(shoppingText("Save price")) {
                Task {
                    if await model.editShop(key: "picked-price-\(line.id)", shopID: shopID, authorize: authorize, { current in
                        guard model.workspace.selectedShopID == shopID else { throw LedgerError.stalePreview }
                        try current.recordPickedPrice(lineID: line.id, expectedRevision: revision,
                            total: try ComparisonModel.money(amount), membership: membership, weighted: weighted,
                            conditionsConfirmed: confirmed)
                    }) { dismiss() }
                }
            }.disabled(!validAmount || model.hasPendingSave || model.saving)
        }.navigationTitle(shoppingText("Picked item price")).navigationBarTitleDisplayMode(.inline)
        .keyboardDoneAction(visible: editingAmount, title: ledgerText("Done"), identifier: "inStoreAmountDone") { editingAmount = false }
        .onChange(of: amount) { _, _ in confirmed = false }
        .onChange(of: membership) { _, _ in confirmed = false }
        .onChange(of: weighted) { _, _ in confirmed = false }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() } } }
    }

    private var validAmount: Bool {
        if amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard let value = try? ComparisonModel.money(amount) else { return false }
        return (0...1_000_000_000).contains(value.minorUnits)
    }
}
