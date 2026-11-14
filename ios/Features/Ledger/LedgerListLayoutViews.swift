import SwiftUI
import UIKit
import CoreDomain

private enum AisleScope { case storeDefault, thisShop, followStore }

struct LedgerLayoutEditor: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    @Environment(\.dismiss) private var dismiss
    @State private var mode: LedgerListOrder
    @State private var lineIDs: [UUID]
    @State private var aisles: [String]
    @State private var scope: AisleScope
    @State private var baseRevision: Int64
    @State private var reviewedShopID: UUID
    private var current: Bool {
        model.revision == baseRevision && model.workspace.selectedShopID == reviewedShopID && shop.id == reviewedShopID
    }
    private let branch: String
    private let lineNames: [UUID:String]

    init(model: LedgerModel, shop: ShoppingLedger) {
        self.model = model; self.shop = shop
        _baseRevision = State(initialValue: model.revision)
        _reviewedShopID = State(initialValue: shop.id)
        branch = shop.basis.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let layout = model.workspace.listLayout.layout(for: shop)
        _mode = State(initialValue: layout.mode)
        _scope = State(initialValue: branch.isEmpty || (layout.aisleOverride != nil && layout.branch == branch) ? .thisShop : .followStore)
        _aisles = State(initialValue: model.workspace.listLayout.aisleNames(in: shop))
        let active = shop.search("").filter { !$0.isTrashed && !$0.isChecked && !$0.isHandled }
        lineNames = Dictionary(uniqueKeysWithValues: active.map { ($0.id,$0.name) })
        let previous = Set(layout.lineOrder)
        let activeIDs = Set(active.map(\.id))
        _lineIDs = State(initialValue: layout.lineOrder.filter(activeIDs.contains) + active.map(\.id).filter { !previous.contains($0) })
    }

    var body: some View {
        Form {
            Picker(ledgerText("List order"), selection: $mode) {
                Text(ledgerText("Original entry order")).tag(LedgerListOrder.entered)
                Text(ledgerText("Manual item order")).tag(LedgerListOrder.manual)
                Text(ledgerText("Group by aisle")).tag(LedgerListOrder.aisle)
            }
            if mode == .aisle {
                if !branch.isEmpty {
                    Section(branch) {
                        Picker(ledgerText("Aisle order"), selection: $scope) {
                            Text(ledgerText("Use store order")).tag(AisleScope.followStore)
                            Text(ledgerText("Set order for this store")).tag(AisleScope.storeDefault)
                            Text(ledgerText("Override for this pickup")).tag(AisleScope.thisShop)
                        }
                    }
                }
                Section(ledgerText("Aisles")) {
                    if aisles.isEmpty { Text(ledgerText("Set an aisle in item details to group items here.")) }
                    ForEach(aisles, id: \.self) { aisle in
                        if scope == .followStore { Text(aisle) }
                        else { moveRow(aisle, id: aisle, values: $aisles) }
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
                .disabled(!current || model.saving || model.hasPendingSave).accessibilityIdentifier("saveListOrder")
        }.navigationTitle(ledgerText("List order and aisles"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ledgerText("Cancel")) { dismiss() } } }
        .onChange(of: scope) { _, next in
            var projected = model.workspace.listLayout
            if next != .thisShop {
                projected.shopLayouts.removeValue(forKey: shop.id.uuidString.lowercased())
            }
            aisles = projected.aisleNames(in: shop)
        }
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
            var layout = workspace.listLayout.layout(for: shop)
            layout.mode = mode
            if mode == .manual {
                try layout.setActiveOrder(lineIDs, in: shop)
            }
            if mode == .aisle {
                layout.branch = branch
                layout.aisleOverride = scope == .thisShop ? aisles : nil
                if scope == .storeDefault && !branch.isEmpty { workspace.listLayout.storeAisles[branch] = aisles }
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
    @State private var printError = false

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
                    .disabled(groups.allSatisfy { $0.lines.isEmpty }).accessibilityIdentifier("printShoppingList")
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
        .alert(ledgerText("Printing is unavailable"),isPresented:$printError) { Button(ledgerText("Done")) {} }
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
        .item { page-break-inside: avoid; padding-top: 14pt }
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
        guard groups.contains(where: { !$0.lines.isEmpty }), UIPrintInteractionController.isPrintingAvailable else {
            printError = true
            return
        }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary:nil); info.jobName = shop.title; info.outputType = .grayscale
        controller.printInfo = info
        controller.printPageRenderer = PickupPrintPageRenderer(formatter: printFormatter())
        let presented = controller.present(animated: true) { _, _, error in
            if error != nil { printError = true }
        }
        if !presented { printError = true }
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
        let size = name.size()
        name.draw(at: CGPoint(x: footerRect.midX - size.width / 2, y: footerRect.midY - size.height / 2))
    }
}
