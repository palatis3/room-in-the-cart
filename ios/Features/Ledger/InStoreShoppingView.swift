import SwiftUI
import CoreDomain

func shoppingText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "ShoppingLists")
}

func shoppingFormat(_ key: String, _ values: CVarArg...) -> String {
    String(format: shoppingText(key), locale: Locale.current, arguments: values)
}

func pickedSubtotalText(_ subtotal: PickedCartSubtotal) -> String {
    if subtotal.picked == 0 { return shoppingFormat("%@ · No items picked", moneyText(subtotal.total)) }
    if subtotal.priced == 0 { return shelfText("Picked subtotal unknown") }
    if subtotal.picked == 1 { return shoppingFormat("%@ for 1 picked item", moneyText(subtotal.total)) }
    return shoppingFormat("%@ for %lld of %lld picked items", moneyText(subtotal.total),
                          Int64(subtotal.priced), Int64(subtotal.picked))
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
    @Environment(\.pantryVoicePrompt) private var pantryPrompt
    @State private var identity: CapturePrivateIdentity?
    @State private var workspaceID: UUID?

    var body: some View {
        let active = authorized()
        let retained = scenePhase != .background && pantryPrompt?.holdsPresentation() == true && currentOwner()
        Group {
            if active || retained {
                NavigationStack { content() }
                    .opacity(active ? 1 : 0).allowsHitTesting(active).accessibilityHidden(!active)
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
        scenePhase == .active && UIApplication.shared.applicationState == .active && currentOwner()
    }

    private func currentOwner() -> Bool {
        UIApplication.shared.isProtectedDataAvailable && model.ready && !model.hasPendingLedgerDeletion && workspaceID != nil && workspaceID == model.sourceWorkspaceID &&
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
    @State private var displayOwner = UUID()
    @State private var editingPrice: ShoppingLine?
    private enum Focus: Hashable { case line(UUID), picked(UUID), subtotal }
    private enum Destination: Hashable, Identifiable {
        case details(UUID), options, find, nextStore
        var id: Self { self }
    }
    @State private var destination: Destination?
    @SceneStorage("inStoreScrollRow") private var savedRow = ""
    @State private var trackingAisle = false
    @State private var completedDetailRow: UUID?
    @State private var scrollToReturn = false
    @AccessibilityFocusState private var focus: Focus?
    @State private var pendingFocus: Focus?

    var body: some View {
        Group {
            if let shop = model.shop, shop.id == shopID {
                let groups = model.workspace.listLayout.groups(shop: shop)
                let visible = groups.flatMap(\.lines).filter { available($0, shop: shop) }
                let outstanding = groups.flatMap(\.lines).filter { shop.outcomeAtCurrentStop($0) != nil }
                let picked = shop.inStorePickedLines
                let exclusions = shop.listExclusions
                let packages = shop.itemPackages
                ScrollViewReader { reader in
                    List {
                        if model.error != nil || model.hasPendingSave { LedgerSaveStatus(model: model) }
                        if !shop.currentStop.name.isEmpty {
                            Section { Label(shop.currentStop.name, systemImage: "storefront").font(.headline) }
                        }
                        ForEach(groups) { group in
                            let rows = group.lines.filter { available($0, shop: shop) }
                            if !rows.isEmpty {
                                Section(group.aisle.isEmpty ? shoppingText("To pick") : group.aisle) {
                                    ForEach(rows) { line in
                                        outstandingRow(line, shop: shop, visible: visible, exclusions: exclusions[line.id],
                                                       packages: packages[line.id] ?? [])
                                    }
                                }
                            }
                        }
                        if visible.isEmpty {
                            Text(groups.allSatisfy { $0.lines.isEmpty } ? shoppingText("No items left to pick.") : tripText("Nothing else to pick at this stop."))
                        }
                        if !outstanding.isEmpty {
                            Section(tripText("Still needed")) {
                                ForEach(outstanding) { line in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Button { destination = .details(line.id) } label: {
                                            VStack(alignment: .leading) {
                                                Text(line.name).font(.headline)
                                                let measure = TripMeasure(shop, line: line, packages: packages[line.id] ?? [])
                                                if let quantity = shop.tripAmountLabel(line, measure: measure) { Text(quantity) }
                                                Text(tripText(shop.isLeftForNextTrip(line) ? "Left for next time" : "Couldn’t find it at this stop"))
                                                    .foregroundStyle(Theme.secondary)
                                            }.frame(minHeight: 44)
                                        }.accessibilityFocused($focus, equals: .line(line.id))
                                        if line.tripUndo != nil {
                                            Button(tripFormat("Undo for %@", line.name)) { undo(line, in: shop) }.frame(minHeight: 44)
                                        }
                                    }.buttonStyle(.borderless).id(Focus.line(line.id))
                                        .background(TripRowPosition(row: line.id))
                                }
                            }
                        }
                        if !picked.isEmpty {
                            Section(shoppingText("Picked items")) {
                                ForEach(picked) { line in
                                    pickedRow(line, in: shop, packages: packages[line.id] ?? [])
                                }
                            }
                        }
                        Section {
                            Button { destination = .nextStore } label: { Label(tripText("Next store"), systemImage: "storefront") }
                                .accessibilityIdentifier("tripNextStore")
                        }.frame(minHeight: 44)
                        if typeSize.isAccessibilitySize {
                            Section { subtotalSummary(shop, last: picked.first).id(Focus.subtotal) }
                        }
                    }
                    .workingSurface()
                    .coordinateSpace(name: "shoppingAisles")
                    .onAppear {
                        if let id = restoredRow(), visible.contains(where: { $0.id == id }) || outstanding.contains(where: { $0.id == id }) {
                            reader.scrollTo(Focus.line(id), anchor: .top)
                        }
                        Task { @MainActor in await Task.yield(); trackingAisle = true }
                    }
                    .onPreferenceChange(TripVisibleRows.self) { rows in
                        guard trackingAisle, scene == .active, authorize(),
                              let top = rows.filter({ $0.value.maxY > 0 }).min(by: { $0.value.minY < $1.value.minY })
                        else { return }
                        remember(top.key)
                    }
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
                        if UIAccessibility.isVoiceOverRunning || scrollToReturn {
                            switch target {
                            case .line, .picked: reader.scrollTo(target, anchor: .center)
                            case .subtotal:
                                if typeSize.isAccessibilitySize { reader.scrollTo(Focus.subtotal, anchor: .top) }
                            }
                        }
                        Task { @MainActor in
                            await Task.yield()
                            focus = target
                            scrollToReturn = false
                            pendingFocus = nil
                        }
                    }
                }
                .sheet(item: $editingPrice) { line in
                    NavigationStack { InStorePriceEditor(model: model, shop: shop, line: line) }
                }
                .sheet(item: $destination, onDismiss: {
                    if let completedDetailRow {
                        returnToRow(completedDetailRow)
                        self.completedDetailRow = nil
                    }
                }) { value in
                    NavigationStack {
                        switch value {
                        case let .details(id):
                            TripItemDetail(model: model, shopID: shopID, lineID: id, onSaved: { completedDetailRow = $0 })
                                .toolbar { closeSheet }
                        case .find:
                            TripFindEntry(model: model, shop: shop, onSaved: { completedDetailRow = $0 }).toolbar { closeSheet }
                        case .nextStore:
                            TripNextStoreEntry(model: model, shopID: shopID).toolbar { closeSheet }
                        case .options:
                            List {
                                NavigationLink(tripText("Preview list copy")) { TripHandoffEntry(model: model, shopID: shopID) }
                                    .accessibilityIdentifier("tripShare.previewCopy")
                                NavigationLink(pantryText("Buy this pack again")) { ShopPackLookupEntry(ledger: model, shopID: shopID) }
                                PantryShelfPhotoLink()
                                InStoreDisplayToggle(owner: displayOwner)
                            }.workingSurface().navigationTitle(ledgerText("List options")).toolbar { closeSheet }
                        }
                    }
                }
            }
        }.navigationTitle(typeSize.isAccessibilitySize ? shoppingText("In store") : shoppingText("Shop in store"))
        .navigationBarTitleDisplayMode(typeSize.isAccessibilitySize ? .inline : .automatic)
        .toolbar {
            if model.shop?.id == shopID && authorize() {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { destination = .options } label: {
                        Label(ledgerText("List options"), systemImage: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("inStoreTripOptions")
                    Button { destination = .find } label: {
                        Label(tripText("Add a find"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("tripAddFind")
                }
            }
            ToolbarItem(placement: .confirmationAction) { Button(ledgerText("Done")) { dismiss() } }
        }
        .modifier(InStoreDisplayPreference(trip: shopID, owner: displayOwner, available: model.shop?.id == shopID && authorize()))
    }

    private var closeSheet: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(ledgerText("Done")) { destination = nil }
        }
    }

    private func available(_ line: ShoppingLine, shop: ShoppingLedger) -> Bool {
        shop.outcomeAtCurrentStop(line) == nil && line.eligibleForStop(named: shop.currentStop.name)
    }

    private func outstandingRow(_ line: ShoppingLine, shop: ShoppingLedger, visible: [ShoppingLine], exclusions: String?,
                                packages: [BasketPackage]) -> some View {
        let measure = TripMeasure(shop, line: line, packages: packages)
        let amount = shop.tripAmountLabel(line, measure: measure)
        let department = model.workspace.listLayout.department(for: line, in: shop)
        let showDepartment = !department.isEmpty && model.workspace.listLayout.layout(for: shop).mode != .aisle
        return HStack(alignment: .top, spacing: 8) {
            Button {
                let index = visible.firstIndex(where: { $0.id == line.id }) ?? 0
                let others = visible.filter { $0.id != line.id }
                let next = others.isEmpty ? nil : others[min(index, others.count - 1)].id
                changePick(line, in: shop, checked: true, next: next)
            } label: {
                Image(systemName: "square").font(.title3).foregroundStyle(Theme.controlEdge)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(ledgerFormat("Check %@", line.name))
            .accessibilityValue([amount ?? "", showDepartment ? department : "", line.notes, exclusions ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityFocused($focus, equals: .line(line.id))
            .accessibilityIdentifier("inStoreCheck-\(line.id)")
            Button { destination = .details(line.id) } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: line.name).font(.headline)
                        if showDepartment { Text(verbatim: department).font(.subheadline).foregroundStyle(Theme.secondary) }
                        if let coupon = line.pinnedCoupon { InStoreCouponPickLabel(coupon: coupon, line: line) }
                        if let amount { Text(amount) }
                        if !line.notes.isEmpty { Text(verbatim: line.notes) }
                        if let exclusions { Text(exclusions) }
                    }.foregroundStyle(Theme.ink)
                    Spacer(minLength: 4)
                    Image(systemName: "info.circle").accessibilityHidden(true)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.accessibilityHint(tripText("Shows dinner, pick part and store options."))
                .accessibilityIdentifier("tripDetails-\(line.id)")
        }.buttonStyle(.borderless).disabled(model.hasPendingSave)
        .background(TripRowPosition(row: line.id))
        .id(Focus.line(line.id))
    }

    private func remember(_ id: UUID) {
        guard let workspace = model.sourceWorkspaceID else { return }
        let scoped = [workspace, shopID, id].map(\.uuidString).joined(separator: "/")
        if savedRow != scoped { savedRow = scoped }
    }

    private func restoredRow() -> UUID? {
        let parts = savedRow.split(separator: "/").map(String.init)
        guard authorize(), parts.count == 3, parts[0] == model.sourceWorkspaceID?.uuidString,
              parts[1] == shopID.uuidString else { return nil }
        return UUID(uuidString: parts[2])
    }

    private func returnToRow(_ id: UUID) {
        guard let shop = model.shop else { return }
        scrollToReturn = true
        guard let line = shop.lines.first(where: { $0.id == id && !$0.isTrashed && !$0.isHandled }),
              line.isChecked || shop.outcomeAtCurrentStop(line) != nil || available(line, shop: shop) else {
            let next = model.workspace.listLayout.groups(shop: shop).flatMap(\.lines).first { available($0, shop: shop) }
            pendingFocus = next.map { .line($0.id) } ?? .subtotal
            return
        }
        remember(id)
        pendingFocus = line.isChecked ? .picked(id) : .line(id)
    }

    private func pickedRow(_ line: ShoppingLine, in shop: ShoppingLedger, packages: [BasketPackage]) -> some View {
        let undoLabel = shoppingFormat("Undo pick of %@", line.name)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                if line.tripUndo?.action == .pick { undo(line, in: shop) }
                else { changePick(line, in: shop, checked: false, next: line.id) }
            } label: {
                Image(systemName: "checkmark.square.fill").font(.title3)
                    .foregroundStyle(Theme.action)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(shoppingFormat("Uncheck %@", line.name))
            .accessibilityIdentifier("inStoreUncheck-\(line.id)")
            .accessibilityFocused($focus, equals: .picked(line.id))
            .disabled(model.hasPendingSave)

            Button { editingPrice = line } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.name).font(.headline).foregroundStyle(Theme.ink)
                        if let picked = try? shop.pickedQuantity(forLineID: line.id) {
                            let measure = TripMeasure(shop, line: line, packages: packages)
                            let label = measure.flatMap { measure in
                                (try? picked.converted(to: measure.need.unit)).map { measure.display($0) }
                            }
                            Text(label ?? ledgerQuantity(picked)).foregroundStyle(Theme.secondary)
                        }
                        if let coupon = line.pinnedCoupon { InStoreCouponPickLabel(coupon: coupon, line: line) }
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
            .accessibilityActions {
                if line.canUndoInStore { Button(undoLabel) { undo(line, in: shop) } }
            }
            Button { destination = .details(line.id) } label: {
                Image(systemName: "info.circle").frame(width: 44, height: 44)
            }.accessibilityLabel(ledgerFormat("Inspect %@", line.name))
        }
        .id(Focus.picked(line.id))
        .buttonStyle(.borderless)
        .overlay { GroceryCheckInset(cue: cue, lineID: line.id).allowsHitTesting(false) }
    }

    private func subtotalSummary(_ shop: ShoppingLedger, last: ShoppingLine?) -> some View {
        let subtotal = shop.pickedCartSubtotal
        return VStack(alignment: .leading, spacing: 5) {
            Text(pickedSubtotalText(subtotal)).font(.headline).monospacedDigit()
                .accessibilityFocused($focus, equals: .subtotal)
                .accessibilityIdentifier("inStoreSubtotal")
            InStoreBudgetSummary(shop: shop)
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
        if last.canUndoInStore {
            Button(last.tripUndo?.action == .pick || last.tripUndo == nil ? shoppingFormat("Undo pick of %@", last.name) : tripFormat("Undo for %@", last.name)) {
                undo(last, in: shop)
            }.frame(minHeight: 44).accessibilityIdentifier("inStoreUndo")
        }
    }

    private func priceLabel(_ price: PickedLinePrice?) -> String {
        guard let price else { return shoppingText("Price unknown · enter total") }
        var parts = [price.total.map { shoppingFormat("Saved price · %@", moneyText($0)) } ?? shoppingText("Price unknown")]
        if price.membership { parts.append(shoppingText("Member price")) }
        if price.weighted { parts.append(shoppingText("Sold by weight")) }
        if price.includedTotal == nil { parts.append(shoppingText("Excluded from subtotal")) }
        return parts.joined(separator: " · ")
    }

    private func undo(_ line: ShoppingLine, in shop: ShoppingLedger) {
        Task {
            guard !model.hasPendingSave,
                  await model.editShop(key: "undo-trip-\(line.id)", shopID: shop.id, authorize: authorize, { current in
                    guard model.workspace.selectedShopID == shopID, current.revisionID == shop.revisionID else { throw LedgerError.stalePreview }
                    try current.undoInStore(lineID: line.id, expectedRevision: shop.revisionID)
                  }) else { return }
            cue = nil
            returnToRow(line.id)
        }
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


private struct TripVisibleRows: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, next in next }
    }
}

private struct TripRowPosition: View {
    let row: UUID
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: TripVisibleRows.self, value: [row: geometry.frame(in: .named("shoppingAisles"))])
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}
