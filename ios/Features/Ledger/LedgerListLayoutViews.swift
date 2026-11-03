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
    private let baseRevision: Int64
    private let branch: String
    private let lineNames: [UUID:String]

    init(model: LedgerModel, shop: ShoppingLedger) {
        self.model = model; self.shop = shop; baseRevision = model.revision
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
            LedgerSaveStatus(model: model, onRetried: { dismiss() })
            Button(ledgerText("Save list order")) { Task { await save() } }
                .disabled(model.saving || model.hasPendingSave).accessibilityIdentifier("saveListOrder")
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
            guard model.revision == baseRevision, workspace.selectedShopID == shop.id else { throw LedgerError.stalePreview }
            let id = shop.id.uuidString.lowercased()
            var layout = workspace.listLayout.layout(for: shop)
            layout.mode = mode
            if mode == .manual {
                let active = Set(lineIDs)
                layout.lineOrder = lineIDs + layout.lineOrder.filter { !active.contains($0) }
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
    @State private var printError = false
    init(shop: ShoppingLedger, layout: LedgerListLayout) { self.shop = shop; self.layout = layout }
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
    func printText() -> NSAttributedString {
        let text = NSMutableAttributedString(string: "")
        func append(_ string: String, size: CGFloat, bold: Bool = false) {
            let font = bold ? UIFont.boldSystemFont(ofSize:size) : UIFont.systemFont(ofSize:size)
            text.append(NSAttributedString(string:string+"\n",attributes:[.font:font,.foregroundColor:UIColor.black]))
        }
        append(shop.title,size:28,bold:true)
        if !shop.basis.branch.isEmpty { append(shop.basis.branch,size:22) }
        for group in layout.groups(shop: shop) {
            if let heading = heading(group) { append("\n"+heading,size:24,bold:true) }
            for line in group.lines {
                append("\n"+line.name,size:22,bold:true)
                append(ledgerQuantity(try? shop.quantity(forLineID:line.id)),size:20)
            }
        }
        return text
    }
    private func printList(_ groups: [LedgerListLayout.Group]) {
        guard groups.contains(where: { !$0.lines.isEmpty }),UIPrintInteractionController.isPrintingAvailable,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let view = scene.keyWindow?.rootViewController?.view else { printError = true; return }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary:nil); info.jobName = shop.title; info.outputType = .grayscale
        controller.printInfo = info
        let formatter = UISimpleTextPrintFormatter(attributedText: printText())
        formatter.perPageContentInsets = UIEdgeInsets(top:32,left:32,bottom:32,right:32)
        controller.printFormatter = formatter
        if !controller.present(from: CGRect(x:view.bounds.midX,y:view.bounds.midY,width:1,height:1), in:view, animated:true,
            completionHandler:{ _,_,error in if error != nil { printError = true } }) { printError = true }
    }
}
