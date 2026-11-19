import SwiftUI
import UIKit
import CoreDomain

struct LedgerDepartmentOrderDraft {
    enum Store: Hashable { case current, saved(UUID), new }
    enum Scope { case storeDefault, thisShop, followStore }

    private(set) var store = Store.current
    private(set) var scope: Scope
    var name: String
    var aisles: [String]

    init(layout: LedgerListLayout, shop: ShoppingLedger) {
        let branch = shop.basis.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        name = branch
        let saved = layout.layout(for: shop)
        scope = branch.isEmpty || (saved.aisleOverride != nil && saved.branch == branch) ? .thisShop : .followStore
        aisles = layout.aisleNames(in: shop)
    }

    func isNameValid(in layout: LedgerListLayout) -> Bool {
        guard store == .new else { return true }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !label.isEmpty && label.utf8.count <= 512 &&
            layout.departmentDirectory?.stores.values.contains(where: { $0.name == label }) != true
    }

    func matchChosenStore(in layout: inout LedgerListLayout, shop: ShoppingLedger) throws {
        switch store {
        case .current: break
        case .saved(let id): try layout.matchStore(in: shop, to: id)
        case .new: try layout.matchStore(in: shop, to: nil, name: name)
        }
    }

    mutating func select(_ store: Store, scope: Scope, in saved: LedgerListLayout, shop: ShoppingLedger) {
        guard self.store != store || self.scope != scope else { return }
        self.store = store
        self.scope = scope
        var preview = saved
        let shopKey = shop.id.uuidString.lowercased()
        if store == .new {
            // A new store inherits the legacy branch order and has no remembered
            // products. Its display name is independent of this preview.
            if preview.shopLayouts[shopKey]?.departmentStore != nil {
                preview.shopLayouts[shopKey]?.departmentStore = nil
                preview.shopLayouts[shopKey]?.aisleOverride = nil
            }
        } else { try? matchChosenStore(in: &preview, shop: shop) }
        if scope != .thisShop { preview.shopLayouts[shopKey]?.aisleOverride = nil }
        aisles = preview.aisleNames(in: shop)
    }
}

struct LedgerLayoutEditor: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    @Environment(\.dismiss) private var dismiss
    @State private var mode: LedgerListOrder
    @State private var lineIDs: [UUID]
    @State private var draft: LedgerDepartmentOrderDraft
    @State private var baseRevision: Int64
    @State private var reviewedShopID: UUID
    private var current: Bool {
        model.revision == baseRevision && model.workspace.selectedShopID == reviewedShopID && shop.id == reviewedShopID
    }
    private var isStoreNameValid: Bool {
        mode != .aisle || draft.isNameValid(in: model.workspace.listLayout)
    }
    private let branch: String
    private let lineNames: [UUID:String]

    init(model: LedgerModel, shop: ShoppingLedger) {
        self.model = model; self.shop = shop
        _baseRevision = State(initialValue: model.revision)
        _reviewedShopID = State(initialValue: shop.id)
        branch = shop.basis.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        _draft = State(initialValue: LedgerDepartmentOrderDraft(layout: model.workspace.listLayout, shop: shop))
        let layout = model.workspace.listLayout.layout(for: shop)
        _mode = State(initialValue: layout.mode)
        let active = shop.search("").filter { !$0.isTrashed && !$0.isChecked && !$0.isHandled }
        lineNames = Dictionary(uniqueKeysWithValues: active.map { ($0.id,$0.name) })
        let previous = Set(layout.lineOrder)
        let activeIDs = Set(active.map(\.id))
        _lineIDs = State(initialValue: layout.lineOrder.filter(activeIDs.contains) + active.map(\.id).filter { !previous.contains($0) })
    }

    var body: some View {
        WorkingForm {
            Picker(ledgerText("List order"), selection: $mode) {
                Text(ledgerText("Original entry order")).tag(LedgerListOrder.entered)
                Text(ledgerText("Manual item order")).tag(LedgerListOrder.manual)
                Text(ledgerText("Group by aisle")).tag(LedgerListOrder.aisle)
            }
            if mode == .aisle {
                if !branch.isEmpty {
                    Section(branch) {
                        Picker(ledgerText("Match store name"), selection: Binding(get: { draft.store }, set: { store in
                            draft.select(store, scope: draft.scope, in: model.workspace.listLayout, shop: shop)
                        })) {
                            let matched = model.workspace.listLayout.layout(for: shop).departmentStore.flatMap { $0.branch == branch ? $0.storeID : nil }
                            let currentStore = matched.flatMap { model.workspace.listLayout.departmentDirectory?.stores[$0.uuidString.lowercased()] }
                            if let currentStore { Text(verbatim: currentStore.name).tag(LedgerDepartmentOrderDraft.Store.current) }
                            else { Text(ledgerText("No store matched")).tag(LedgerDepartmentOrderDraft.Store.current) }
                            ForEach((model.workspace.listLayout.departmentDirectory?.stores.values.map { $0 } ?? [])
                                .filter { $0.id != matched }.sorted { $0.name < $1.name }) { store in
                                Text(verbatim: store.name).tag(LedgerDepartmentOrderDraft.Store.saved(store.id))
                            }
                            Text(ledgerText("Create separate store")).tag(LedgerDepartmentOrderDraft.Store.new)
                        }
                        if draft.store == .new {
                            TextField(ledgerText("Name for this store"), text: $draft.name)
                            if !isStoreNameValid { Text(ledgerText("Give this store its own short name.")) }
                        }
                        if draft.store != .current {
                            Text(ledgerText("Saving matches this pickup’s store name for future lists."))
                                .font(.footnote)
                        }
                        Picker(ledgerText("Aisle order"), selection: Binding(get: { draft.scope }, set: { scope in
                            draft.select(draft.store, scope: scope, in: model.workspace.listLayout, shop: shop)
                        })) {
                            Text(ledgerText("Use store order")).tag(LedgerDepartmentOrderDraft.Scope.followStore)
                            Text(ledgerText("Set order for this store")).tag(LedgerDepartmentOrderDraft.Scope.storeDefault)
                            Text(ledgerText("Override for this pickup")).tag(LedgerDepartmentOrderDraft.Scope.thisShop)
                        }
                    }
                }
                Section(ledgerText("Aisles")) {
                    if draft.aisles.isEmpty { Text(ledgerText("Set an aisle in item details to group items here.")) }
                    ForEach(draft.aisles, id: \.self) { aisle in
                        if draft.scope == .followStore { Text(aisle) }
                        else { moveRow(aisle, id: aisle, values: $draft.aisles) }
                    }
                }
            }
            if mode == .manual {
                Section(ledgerText("Active items")) {
                    ForEach(lineIDs, id: \.self) { id in moveRow(lineNames[id] ?? "", id: id, values: $lineIDs) }
                }
            }
            if !current { Text(ledgerText("The list changed. Reopen list options to review its current order.")) }
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
            Button(ledgerText("Save list order")) { Task { await save() } }
                .disabled(!current || !isStoreNameValid || model.saving || model.hasPendingSave).accessibilityIdentifier("saveListOrder")
        }.navigationTitle(ledgerText("List order and aisles"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() } } }
    }

    private func moveRow<ID: Hashable>(_ title: String, id: ID, values: Binding<[ID]>) -> some View {
        VStack(alignment: .leading) {
            Text(title)
            HStack {
                ForEach([-1,1], id: \.self) { offset in
                    Button {
                        var items = values.wrappedValue
                        guard let current = items.firstIndex(of: id), items.indices.contains(current+offset) else { return }
                        items.swapAt(current,current+offset); values.wrappedValue = items
                    } label: {
                        Image(systemName: offset < 0 ? "arrow.up" : "arrow.down").frame(minWidth: 44,minHeight: 44)
                    }.accessibilityLabel(ledgerFormat(offset < 0 ? "Move %@ up" : "Move %@ down",title))
                        .disabled(offset < 0 ? values.wrappedValue.first == id : values.wrappedValue.last == id)
                }
            }.buttonStyle(.borderless)
        }
    }

    @MainActor private func save() async {
        let ok = await model.change(key: "list-layout-\(shop.id)") { workspace in
            guard current, workspace.selectedShopID == reviewedShopID else { throw LedgerError.stalePreview }
            let id = shop.id.uuidString.lowercased()
            if mode == .aisle {
                try draft.matchChosenStore(in: &workspace.listLayout, shop: shop)
                if draft.scope == .storeDefault && !branch.isEmpty { try workspace.listLayout.setStoreOrder(draft.aisles, in: shop) }
            }
            var layout = workspace.listLayout.layout(for: shop)
            layout.mode = mode
            if mode == .manual {
                try layout.setActiveOrder(lineIDs, in: shop)
            }
            if mode == .aisle {
                layout.branch = branch
                layout.aisleOverride = draft.scope == .thisShop ? draft.aisles : nil
            }
            workspace.listLayout.shopLayouts[id] = layout
        }
        if ok { dismiss() }
    }
}

struct LargePrintList: View {
    @Environment(\.dismiss) private var dismiss
    let shop: ShoppingLedger
    let layout: LedgerListLayout
    private let itemDetails: [UUID: [String]]
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var printSession = GroceryPrintSession()

    init(shop: ShoppingLedger, layout: LedgerListLayout) {
        self.shop = shop
        self.layout = layout
        var details: [UUID: [String]] = [:]
        var seen: [UUID: Set<String>] = [:]
        for source in shop.contributions where source.removedAt == nil {
            if let label = Self.packageLabel(for: source), seen[source.lineID, default: []].insert(label).inserted {
                details[source.lineID, default: []].append(label)
            }
        }
        for (lineID, exclusions) in shop.listExclusions {
            details[lineID, default: []].append(exclusions)
        }
        itemDetails = details
    }

    private static func packageLabel(for source: LedgerContribution) -> String? {
        if let pack = source.originalPack {
            let size = ledgerQuantity(pack.amountPerPack)
            if let count = pack.count {
                return ledgerFormat("Original package label (%lld × %@)", Int64(count), size)
            }
            return ledgerFormat("Amount per pack on the original label: %@", size)
        }
        guard let capture = source.capture else { return nil }
        var facts: [String] = []
        if let count = capture.packCount, !capture.unresolvedFields.contains(.packCount) {
            facts.append(captureText("Packs") + ": " + String(count))
        }
        if let size = capture.amountPerPack, !capture.unresolvedFields.contains(.amountPerPack) {
            facts.append(captureText("Usable amount per pack") + ": " + ledgerQuantity(size))
        }
        return facts.isEmpty ? nil : facts.joined(separator: " · ")
    }

    var body: some View {
        let groups = layout.groups(shop: shop)
        List {
            Section {
                Text(shop.title).font(.largeTitle.bold())
                if !shop.basis.branch.isEmpty { Text(shop.basis.branch).font(.title2) }
                Text(ledgerText("Print active items and quantities in the current list order."))
                Button(ledgerText("Print shopping list")) { printList(groups) }
                    .disabled(printSession.active || groups.allSatisfy { $0.lines.isEmpty })
                    .accessibilityIdentifier("printShoppingList")
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.lines) { line in
                        VStack(alignment: .leading) {
                            Text(line.name).font(.title2.bold())
                            Text(ledgerQuantity(try? shop.quantity(forLineID: line.id))).font(.title3)
                            ForEach(itemDetails[line.id] ?? [], id: \.self) { label in
                                Text(verbatim: label).font(.title3)
                            }
                        }
                    }
                } header: { if let heading = heading(group) { Text(heading) } }
            }
        }.navigationTitle(ledgerText("Large-print list"))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ledgerText("Done")) { dismiss() } } }
        .workingSurface()
        .alert(ledgerText("Printing is unavailable"), isPresented: $printSession.showError) { Button(ledgerText("Done")) {} }
        .onChange(of: shop) { _, _ in printSession.dismiss() }
        .onChange(of: layout) { _, _ in printSession.dismiss() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { printSession.dismiss() } }
        .onDisappear { printSession.dismiss() }
    }
    private func heading(_ group: LedgerListLayout.Group) -> String? {
        if !group.aisle.isEmpty { return group.aisle }
        return layout.layout(for: shop).mode == .aisle ? ledgerText("No aisle assigned") : nil
    }
    func printFormatter() -> UIPrintFormatter {
        // All shopper-entered text is literal, including product names that look like markup.
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var html = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body { font: 20pt -apple-system; color: black; margin: 0 }
        h1 { font-size: 28pt; margin: 0 }
        h2 { font-size: 24pt; margin: 16pt 0 0; page-break-after: avoid }
        header p { font-size: 22pt; margin: 0 }
        .item { position: relative; padding: 12pt 0 0 26pt; page-break-inside: avoid; overflow-wrap: anywhere }
        .item::before { content: ""; position: absolute; left: 0; top: 16pt;
                        width: 14pt; height: 14pt; border: 1.5pt solid black; border-radius: 2pt }
        strong { font-size: 22pt }
        h1, h2, p, strong { white-space: pre-wrap; overflow-wrap: anywhere }
        </style></head><body><header><h1>\(escaped(shop.title))</h1>
        """
        if !shop.basis.branch.isEmpty { html += "<p>\(escaped(shop.basis.branch))</p>" }
        html += "</header>"
        for group in layout.groups(shop: shop) {
            if let heading = heading(group) { html += "<h2>\(escaped(heading))</h2>" }
            for line in group.lines {
                let amount = ledgerQuantity(try? shop.quantity(forLineID: line.id))
                html += "<div class='item'><strong>\(escaped(line.name))</strong><br>\(escaped(amount))"
                for label in itemDetails[line.id] ?? [] { html += "<br>" + escaped(label) }
                html += "</div>"
            }
        }
        return UIMarkupTextPrintFormatter(markupText: html + "</body></html>")
    }
    private func printList(_ groups: [LedgerListLayout.Group]) {
        guard scenePhase == .active, groups.contains(where: { !$0.lines.isEmpty }) else { return }
        printSession.present(PickupPrintPageRenderer(formatter: printFormatter()))
    }
}

/// A print sheet is shared by UIKit, but each private view owns its renderer.
@MainActor final class GroceryPrintSession: ObservableObject {
    @Published private(set) var renderer: UIPrintPageRenderer?
    @Published var showError = false
    var active: Bool { renderer != nil }

    func present(_ document: UIPrintPageRenderer) {
        guard !active else { return }
        guard UIPrintInteractionController.isPrintingAvailable else { showError = true; return }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = "Room in the Cart"
        info.outputType = .grayscale
        controller.printInfo = info
        controller.printPageRenderer = document
        renderer = document
        let presented = controller.present(animated: true) { [weak self] controller, _, error in
            if controller.printPageRenderer === document { controller.printPageRenderer = nil }
            guard let self, self.renderer === document else { return }
            self.renderer = nil
            self.showError = error != nil
        }
        if !presented, renderer === document {
            if controller.printPageRenderer === document { controller.printPageRenderer = nil }
            renderer = nil
            showError = true
        }
    }

    func dismiss() {
        guard let document = renderer else { return }
        renderer = nil
        let controller = UIPrintInteractionController.shared
        if controller.printPageRenderer === document {
            controller.dismiss(animated: false)
            controller.printPageRenderer = nil
        }
    }
}

class PickupPrintPageRenderer: UIPrintPageRenderer {
    convenience init(text: NSAttributedString) {
        self.init(formatter: UISimpleTextPrintFormatter(attributedText: text))
    }

    init(formatter: UIPrintFormatter) {
        super.init()
        footerHeight = 30
        formatter.perPageContentInsets = UIEdgeInsets(top: 32, left: 32, bottom: 32, right: 32)
        addPrintFormatter(formatter, startingAtPageAt: 0)
    }

    override func drawFooterForPage(at pageIndex: Int, in footerRect: CGRect) {
        let name = NSAttributedString(string: "Room in the Cart", attributes: [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor.black
        ])
        let page = NSAttributedString(
            string: ledgerFormat("Page %lld of %lld", Int64(pageIndex + 1), Int64(numberOfPages)),
            attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
                         .foregroundColor: UIColor.black]
        )
        let nameSize = name.size(), pageSize = page.size()
        if footerRect.width >= nameSize.width + pageSize.width + 16 {
            name.draw(at: CGPoint(x: footerRect.minX, y: footerRect.midY - nameSize.height / 2))
            page.draw(at: CGPoint(x: footerRect.maxX - pageSize.width, y: footerRect.midY - pageSize.height / 2))
        } else {
            page.draw(at: CGPoint(x: footerRect.midX - pageSize.width / 2, y: footerRect.midY - pageSize.height / 2))
        }
    }
}
