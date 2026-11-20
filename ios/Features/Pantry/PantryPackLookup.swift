import CoreDomain
import SwiftUI

/// Read-only scan and name lookup. The caller owns the action on the selected pack or batch.
private struct PackLookupInput: View {
    let workspaceID: UUID?
    let access: PantryDigestAccess?
    let authorized: () -> Bool
    @Binding var query: String
    @Binding var selected: ConfirmedPantryPack?
    @ObservedObject private var memory = PantryDigestStore.shared.packMemory
    @State private var code = ""
    @State private var kind = "manual"
    @State private var retailer = ""
    @State private var consent = false
    @State private var status: String?
    @State private var lastScan: CapturedBarcode?

    var body: some View {
        Section(pantryText("Find a pack")) {
            TextField(pantryText("Product name"), text: $query).onChange(of: query) { _, _ in selected = nil; status = nil }
            TextField(pantryText("Barcode"), text: $code)
                .accessibilityIdentifier("pack.find.code").autocorrectionDisabled().textInputAutocapitalization(.never)
                .onChange(of: code) { _, _ in selected = nil; lastScan = nil; status = nil }
            if code.count == 8 && code.allSatisfy(\.isNumber) {
                Picker(pantryText("Barcode format"), selection: $kind) {
                    Text(pantryText("Unknown")).tag("manual")
                    Text(verbatim: "UPC-E").tag("UPC-E")
                    Text(verbatim: "EAN-8").tag("EAN-8")
                }
            }
            if let candidate = lastScan ?? typed, candidate.catalogGTIN == nil {
                TextField(pantryText("Retailer for this code"), text: $retailer)
                    .onChange(of: retailer) { _, _ in selected = nil }
            }
            if let candidate = lastScan ?? typed {
                Button(pantryText("Find barcode")) { resolve(candidate) }.accessibilityIdentifier("pack.find.resolve")
            }
            LivePackageButton(workspaceID: workspaceID, authorized: authorized) { code in lastScan = code; resolve(code) }
            PantryProductPhotoInput(workspaceID: workspaceID, consent: $consent, authorized: authorized, add: { source in
                guard source.barcodes.count == 1, let code = source.barcodes.first else {
                    status = pantryText("Choose a photo of one barcode or type the code."); return
                }
                lastScan = code; resolve(code)
            }, revoke: { lastScan = nil; selected = nil; status = nil })
            if let status { Text(status) }
        }
        if let access, authorized(), access.authorized(), let recent = try? memory.recent(access.scope) {
            let matches = recent.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            if !matches.isEmpty {
                Section(pantryText("Recent confirmed packs")) {
                    ForEach(matches.prefix(30), id: \.key) { pack in
                        Button(pack.label) { if authorized() && access.authorized() { selected = pack; status = nil } }
                    }
                }
            }
        }
    }
    private var typed: CapturedBarcode? {
        let raw = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : .init(symbology: raw.count == 8 ? kind : "manual", value: raw)
    }
    private func resolve(_ code: CapturedBarcode) {
        guard authorized() else { return }
        if let access, access.authorized() { selected = try? memory.match(code, retailer: retailer, scope: access.scope) }
        else { selected = nil }
        status = selected == nil ? pantryText("No confirmed match. Search by product name or check the retailer.") : nil
    }
}

struct PantryPackFind: View {
    @ObservedObject var model: PantryModel
    let origin: UUID
    @Environment(\.pantryDigestAccess) private var access
    @Environment(\.scenePhase) private var scene
    @State private var query = ""
    @State private var selected: ConfirmedPantryPack?
    private var authorized: Bool { model.phase == .ready && model.snapshot?.state.workspaceID == origin }
    private var scoped: PantryDigestAccess? { access?.scope.origin == origin && access?.authorized() == true ? access : nil }
    private var presentationScope: PantryDigestScope? {
        guard let access, access.scope.origin == origin, access.canPresent() else { return nil }
        return access.scope
    }
    var body: some View {
        WorkingForm {
            if authorized {
                PackLookupInput(workspaceID: origin, access: scoped, authorized: { authorized && scene == .active },
                    query: $query, selected: $selected)
                let confirmed = selected.flatMap { item -> ConfirmedPantryPack? in
                    guard let scoped,
                          (try? PantryDigestStore.shared.packMemory.match(item.barcode, retailer: item.retailer, scope: scoped.scope)) == item else { return nil }
                    return item
                }
                let lots = (model.snapshot?.lots ?? []).filter { lot in
                    if let confirmed { return lot.foodID == confirmed.id }
                    return !query.isEmpty && lot.name.localizedCaseInsensitiveContains(query)
                }
                if confirmed != nil || !query.isEmpty {
                    Section(confirmed?.label ?? query) {
                        if lots.isEmpty { Text(pantryText("No recorded batches.")) }
                        ForEach(lots) { lot in
                            NavigationLink {
                                PantryLotEntryView(model: model, lotID: lot.id, accessAllowed: authorized)
                            } label: { PackLotLabel(lot: lot, access: scoped) }.accessibilityIdentifier("pack.find.lot." + lot.id.uuidString)
                        }
                    }
                }
            }
        }.privacySensitive().navigationTitle(pantryText("Find a package in Pantry"))
        .onChange(of: presentationScope) { _, _ in selected = nil; query = "" }
    }
}

extension InventoryLot {
    var packageBatchLabel: String {
        var pieces: [String] = []
        if let manufacturer = packageCode?.gs1?.lot { pieces.append(pantryFormat("Lot %@", manufacturer)) }
        if let ordinal = intakeOrdinal {
            pieces.append(pantryFormat("Batch %@ in this intake", (ordinal + 1).formatted()))
            pieces.append(pantryCount(count, estimate: countWording))
        }
        if pieces.isEmpty { pieces.append(pantryFormat("Batch %@", String(id.uuidString.suffix(8)))) }
        return pieces.joined(separator: " · ")
    }
}

struct PackLotLabel: View {
    let lot: InventoryLot
    let access: PantryDigestAccess?
    @Environment(\.locale) private var locale
    private func day(_ value: MealDay) -> String { PantryVoiceDateEvidence.formatted(value, locale: locale) }
    @ObservedObject private var store = PantryDigestStore.shared
    @ObservedObject private var printed = PantryDigestStore.shared.packageDates
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(lot.name).font(.headline)
            Text(pantryLocationName(lot.location) + " · " + pantryCount(lot.count, estimate: lot.countWording))
            Text(lot.packageBatchLabel).font(.caption)
            if let access, access.authorized(), access.scope.origin == lot.source.originID {
                if let label = try? printed.load(access.scope, lot: lot.id) {
                    if let chosen = label.verifiedDay {
                        Text(label.sourceLabel + " · " + label.meaning.label + " · " + day(chosen))
                    }
                    if let original = label.originalPrintedWording {
                        LabeledContent(pantryText("Original printed wording"), value: original)
                    }
                }
                if let doc = try? store.document(access.scope) {
                    if let range = doc.currentGuideRange(for: lot) {
                        Text("USDA FoodKeeper · " + range.qualityWindowTitle + " · " + range.qualityWindowDays(day))
                    }
                    if let rule = doc.rules.first(where: { $0.lotID == lot.id && $0.revision == lot.revision && $0.source == nil }) {
                        Text(pantryText("Personal check day") + " · " + day(rule.day))
                    }
                }
            }
        }.accessibilityElement(children: .combine)
    }
}

enum PackRebuyDraft {
    enum LineMatch { case exact, unconfirmed, different }
    static func match(_ line: ShoppingLine, pack: ConfirmedPantryPack?, shop: ShoppingLedger) -> LineMatch {
        guard let pack else { return .unconfirmed }
        let sources = shop.contributions(forLineID: line.id)
        var confirmed = false
        var unconfirmed = false
        for source in sources {
            if let size = source.originalPack?.amountPerPack ?? source.capture?.amountPerPack,
               (try? size.converted(to: pack.size.unit)) != pack.size.amount { return .different }
            if case .imported(let batchID) = source.source,
               let batch = shop.importBatches.first(where: { $0.id == batchID && $0.undoneAt == nil }),
               let prior = batch.preview.lines.first(where: { $0.id == source.id })?.pantryProductLink {
                guard prior == pack.id else { return .different }
                confirmed = true
            } else { unconfirmed = true }
        }
        return confirmed && !unconfirmed ? .exact : .unconfirmed
    }

    static func canIncrease(_ line: ShoppingLine, pack: ConfirmedPantryPack?, shop: ShoppingLedger, confirmedUnlinked: Bool) -> Bool {
        switch match(line, pack: pack, shop: shop) {
        case .different: false
        case .exact: true
        case .unconfirmed: pack == nil || confirmedUnlinked
        }
    }

    static func stage(name: String, count: Int64, pack: ConfirmedPantryPack?, shop: ShoppingLedger, id: UUID) throws -> StagedListImport {
        guard (1...10_000).contains(count) else { throw ProductBatchError.invalid }
        let literal = String(count) + " × " + (pack?.label ?? name)
        let amount: Quantity
        if let pack {
            amount = Quantity(amount: try pack.size.amount.multiplied(by: Rational(count)), unit: pack.size.unit, originalLiteral: literal)
        } else { amount = Quantity(amount: try Rational(count), unit: .count, originalLiteral: literal) }
        let row = StagedImportLine(id: UUID(), proposedLineID: UUID(), originalText: literal, name: name, quantity: amount,
            unresolvedReason: nil, duplicateLineIDs: [], originalPack: pack.map { .init(count: Int(count), amountPerPack: $0.size) },
            pantryProductLink: pack?.id)
        var draft = try shop.stageImport(text: literal, source: .typed, importID: id)
        draft.lines = [row]
        return try shop.refreshImportMatches(draft)
    }
}

struct ShopPackLookupEntry: View {
    @ObservedObject var ledger: LedgerModel
    let shopID: UUID
    @EnvironmentObject private var pickup: PickupModel
    @Environment(\.shoppingListAuthorization) private var authorize
    @Environment(\.pantryDigestAccess) private var access
    @State private var query = ""
    @State private var selected: ConfirmedPantryPack?
    @State private var count = ""
    @State private var preview: StagedListImport?
    @State private var confirmedUnlinked = false
    @State private var target: UUID?
    @State private var status: String?
    @State private var operationID = UUID()
    private var scoped: PantryDigestAccess? {
        guard let access, access.authorized(), pickup.pantryReadIsCurrent, access.scope.origin == pickup.pantrySnapshot?.state.workspaceID else { return nil }
        return access
    }
    private var presentationScope: PantryDigestScope? {
        guard let access, access.canPresent(), pickup.pantryReadIsCurrent,
              access.scope.origin == pickup.pantrySnapshot?.state.workspaceID else { return nil }
        return access.scope
    }
    private var name: String { selected?.name ?? query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func current() -> Bool {
        guard authorize(), ledger.shop?.id == shopID else { return false }
        guard let selected else { return true }
        guard let scoped else { return false }
        return (try? PantryDigestStore.shared.packMemory.match(selected.barcode, retailer: selected.retailer, scope: scoped.scope)) == selected
    }
    var body: some View {
        WorkingForm {
            if authorize(), let shop = ledger.shop, shop.id == shopID {
                if let preview, let line = preview.lines.first, current() {
                    Section(pantryText("Review shopping change")) {
                        Text(selected?.label ?? name).font(.headline)
                        if let selected { Text(count + " × " + pantryQuantity(selected.size)) }
                        if let amount = line.quantity { Text(pantryFormat("Add %@", pantryQuantity(amount))) }
                        Picker(pantryText("Shopping line"), selection: $target) {
                            Text(pantryText("Add a new line")).tag(nil as UUID?)
                            ForEach(shop.importMatchOptions(for: preview, decisions: [:])[line.id] ?? [], id: \.lineID) { option in
                                if option.canAdd, let row = shop.lines.first(where: { $0.id == option.lineID }),
                                   PackRebuyDraft.match(row, pack: selected, shop: shop) != .different {
                                    Text(pantryFormat("Increase %@ · %@", row.name, shop.shoppingRowQuantity(for: row) ?? "—")).tag(Optional(row.id))
                                }
                            }
                        }
                        let targetLine = target.flatMap { id in shop.lines.first(where: { $0.id == id }) }
                        if let targetLine, selected != nil, PackRebuyDraft.match(targetLine, pack: selected, shop: shop) == .unconfirmed {
                            Toggle(pantryText("I checked that this list line means this exact pack."), isOn: $confirmedUnlinked)
                        }
                        Button(pantryText("Add to my list")) {
                            Task {
                                guard current(), self.preview == preview else { return }
                                let choice = target.map(ImportResolution.addToLine) ?? .addNew
                                let didSave = await ledger.editShop(key: "buyConfirmedPack", shopID: shopID, authorize: current) { shop in
                                    if let target {
                                        guard let row = shop.lines.first(where: { $0.id == target }),
                                              PackRebuyDraft.canIncrease(row, pack: selected, shop: shop, confirmedUnlinked: confirmedUnlinked) else { throw LedgerError.incompatibleMatch }
                                    }
                                    _ = try shop.commitImport(preview, decisions: [line.id: choice])
                                }
                                if didSave { self.preview = nil; count = ""; operationID = UUID(); status = pantryText("Shopping list updated.") }
                                else { status = pantryText("Review the current list before trying again.") }
                                UIAccessibility.post(notification: .announcement, argument: status)
                            }
                        }.buttonStyle(PrimaryAction()).disabled(ledger.saving || ledger.hasPendingSave ||
                            targetLine.map { !PackRebuyDraft.canIncrease($0, pack: selected, shop: shop, confirmedUnlinked: confirmedUnlinked) } == true)
                        Button(pantryText("Edit")) { self.preview = nil }
                    }
                } else {
                    PackLookupInput(workspaceID: presentationScope?.origin, access: scoped, authorized: { authorize() },
                        query: $query, selected: $selected)
                    if !name.isEmpty, current() {
                        Section(selected?.label ?? name) {
                            let lines = shop.lines.filter { !$0.isTrashed && !$0.isHandled && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame && PackRebuyDraft.match($0, pack: selected, shop: shop) != .different }
                            if lines.isEmpty { Text(pantryText("No matching lines on this list.")) }
                            ForEach(lines) { line in
                                let quantity = try? shop.outstandingQuantity(forLineID: line.id)
                                VStack(alignment: .leading) {
                                    LabeledContent(line.name, value: pantryQuantity(quantity))
                                    if selected != nil, PackRebuyDraft.match(line, pack: selected, shop: shop) == .unconfirmed {
                                        Text(pantryText("Same name · pack not confirmed")).font(.caption)
                                    }
                                }
                            }
                            if let selected, let scoped {
                                let lots = pickup.pantrySnapshot?.lots.filter { $0.foodID == selected.id } ?? []
                                if lots.isEmpty { Text(pantryText("No recorded batches.")) }
                                ForEach(lots) { lot in PackLotLabel(lot: lot, access: scoped) }
                            }
                            TextField(pantryText("Packages to add"), text: $count).keyboardType(.numberPad)
                            Button(pantryText("Buy this pack again")) { prepare(shop) }
                                .disabled(Int(count).map { !(1...10_000).contains($0) } ?? true)
                        }
                    }
                }
                if let status { Text(status) }
            }
        }.privacySensitive().navigationTitle(pantryText("Buy this pack again"))
        .onChange(of: target) { _, _ in confirmedUnlinked = false }
        .onChange(of: presentationScope) { _, _ in selected = nil; query = ""; preview = nil; target = nil; status = nil }
    }
    private func prepare(_ shop: ShoppingLedger) {
        guard current(), let number = Int64(count), (1...10_000).contains(number) else { return }
        do {
            preview = try PackRebuyDraft.stage(name: name, count: number, pack: selected, shop: shop, id: operationID)
            target = nil; confirmedUnlinked = false; status = nil
        } catch { status = pantryText("Review the current list before trying again.") }
    }
}
