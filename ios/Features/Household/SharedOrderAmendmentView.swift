import SwiftUI
import HouseholdClient

struct SharedOrderAmendmentView: View {
    @ObservedObject var model: HouseholdShopModel
    let shopID: String
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var page: SharedConfirmedOrder?
    @State private var editing = false
    @State private var lines: [ShopperBasketLine] = []
    @State private var reference = ""
    @State private var confirmedAt = Date()
    @State private var confirmation: SharedOrderConfirmation?
    @State private var selected: AmendmentLineChoice?
    @State private var message: String?
    @State private var loading = false
    @FocusState private var referenceFocused: Bool
    @AccessibilityFocusState private var retryFocused: Bool
    private var canRead: Bool { model.canReadConfirmedOrder && model.scope.shopId == shopID }
    private var readyRetryID: String? {
        canRead && !loading && !model.busy && model.delivery == .waiting ? model.pending?.id : nil
    }

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            if canRead {
                if model.pending != nil {
                    Section(OrderAmendmentCopy.text("Pending confirmation")) {
                        if model.delivery == .waiting {
                            Button(ht("Retry the same shared shop action")) { Task { await model.retry(); await refresh() } }
                                .id("shared-order-retry").accessibilityFocused($retryFocused)
                                .accessibilityIdentifier("sharedOrder.retry")
                        }
                        Text(OrderAmendmentCopy.text("The result is not confirmed. Retry the saved action without creating another confirmation."))
                    }
                }
                if let message { Text(message) }
                if let notice = model.notice { Text(notice) }
                if let page {
                    if editing { editor(page) } else { history(page) }
                }
                if loading || model.busy { ProgressView() }
                if !editing { Button(OrderAmendmentCopy.text("Refresh confirmed order")) { Task { await refresh() } } }
            } else { Text(ht("Shared shop access has ended. Return to household settings.")) }
        }
        .navigationTitle(OrderAmendmentCopy.text("Confirmed order"))
        .navigationBarTitleDisplayMode(typeSize.isAccessibilitySize ? .inline : .automatic)
        .disabled(model.busy || loading)
        .keyboardDoneAction(visible: referenceFocused, title: ht("Done")) { referenceFocused = false }
        .task { await refresh() }
        .sheet(item: $selected) { choice in
            if canRead {
                SharedAmendmentLineEditor(choice: choice) { line in
                    guard canRead, model.pending == nil else { return }
                    if let index = lines.firstIndex(where: { $0.lineId == choice.id.uuidString.lowercased() }) {
                        if let line { lines[index] = line } else { lines.remove(at: index) }
                    } else if let line { lines.append(line) }
                    selected = nil
                }
            }
        }
        .onChange(of: canRead) { _, allowed in if !allowed { page = nil; clearDraft() } }
        .task(id: readyRetryID) {
            guard let id = readyRetryID else { return }
            await Task.yield()
            guard !Task.isCancelled, readyRetryID == id else { return }
            proxy.scrollTo("shared-order-retry", anchor: .top)
            retryFocused = true
        }
        }
    }
    @ViewBuilder private func history(_ page: SharedConfirmedOrder) -> some View {
        Section(OrderAmendmentCopy.text("Original placed order")) {
            Text(PlacementCopy.date(page.original.snapshotCreatedAt))
            orderLines(page.original.lines, prefix: "sharedOrder.original")
        }
        if !page.amendments.isEmpty {
            Section(OrderAmendmentCopy.text("Current confirmed order")) {
                Text(OrderAmendmentCopy.text("Recheck the amended checkout total with the retailer. The original quote is not a new total."))
                orderLines(page.current.lines, prefix: "sharedOrder.current")
            }
        }
        if model.pending == nil {
            Button(OrderAmendmentCopy.text("Record a retailer-confirmed change")) {
                lines = page.current.lines; confirmedAt = Date(); editing = true; message = nil
            }.accessibilityIdentifier("sharedOrder.amend")
        }
        ForEach(Array(page.amendments.enumerated().reversed()), id: \.element.id) { index, event in
            Section(OrderAmendmentCopy.text("Retailer confirmation")) {
                Text(event.retailerReference).textSelection(.enabled)
                Text(PlacementCopy.date(event.confirmedAt))
                LabeledContent(OrderAmendmentCopy.text("Reported by"), value:
                    event.actorId == UUID(uuidString: model.scope.memberId) ? OrderAmendmentCopy.text("You") : (event.actorLabel ?? OrderAmendmentCopy.text("Another household shopper")))
                changes(from: index == 0 ? page.original.lines : page.amendments[index - 1].lines, to: event.lines)
            }
        }
    }
    @ViewBuilder private func editor(_ page: SharedConfirmedOrder) -> some View {
        if let confirmation {
            Section(OrderAmendmentCopy.text("Review retailer confirmation")) {
                Text(confirmation.reference); Text(confirmation.confirmedAt.formatted())
                changes(from: page.current.lines, to: confirmation.lines)
                Text(OrderAmendmentCopy.text("This changes the confirmed order only. Record arrivals, meal changes and payments separately."))
            }
            if model.pending == nil {
                Button(OrderAmendmentCopy.text("Confirm retailer amendment")) {
                    referenceFocused = false
                    Task {
                        if await model.confirmOrder(confirmation, reviewed: page) { clearDraft(); await refresh() }
                        else if model.pending == nil { message = OrderAmendmentCopy.text("The order or access changed. Refresh and review the retailer confirmation again.") }
                    }
                }.accessibilityIdentifier("sharedOrder.confirm")
                Button(OrderAmendmentCopy.text("Edit this review")) { self.confirmation = nil }
            }
        } else {
            Section {
                Text(OrderAmendmentCopy.text("Enter only changes the retailer independently confirmed."))
                ForEach(lines) { line in
                    Button(String(format: OrderAmendmentCopy.text("Edit %@"), line.originalItem)) { selected = .init(line: line) }
                }
                Button(OrderAmendmentCopy.text("Add a confirmed item")) { selected = .init(line: nil) }
            }
            Section(OrderAmendmentCopy.text("Retailer confirmation")) {
                TextField(OrderAmendmentCopy.text("Retailer reference or confirmation details"), text: $reference)
                    .focused($referenceFocused).accessibilityIdentifier("sharedOrder.reference")
                if typeSize.isAccessibilitySize {
                    Text(OrderAmendmentCopy.text("Retailer confirmed at"))
                    DatePicker(OrderAmendmentCopy.text("Confirmation date"), selection: $confirmedAt, in: ...Date(), displayedComponents: .date)
                        .labelsHidden().accessibilityIdentifier("sharedOrder.date")
                    DatePicker(OrderAmendmentCopy.text("Confirmation time"), selection: $confirmedAt, in: ...Date(), displayedComponents: .hourAndMinute)
                        .labelsHidden().accessibilityIdentifier("sharedOrder.time")
                } else {
                    DatePicker(OrderAmendmentCopy.text("Retailer confirmed at"), selection: $confirmedAt, in: ...Date())
                }
                Button(OrderAmendmentCopy.text("Review confirmed changes")) {
                    referenceFocused = false
                    let value = SharedOrderConfirmation(reference: reference, confirmedAt: confirmedAt, lines: lines)
                    do { _ = try value.body(reviewed: page); confirmation = value; message = nil }
                    catch { message = OrderAmendmentCopy.text("Check the changed lines, confirmation time and retailer reference (up to 240 characters).") }
                }.accessibilityIdentifier("sharedOrder.review")
            }
        }
        if model.pending == nil { Button(ht("Cancel"), role: .cancel) { clearDraft() } }
    }
    @ViewBuilder private func orderLines(_ lines: [ShopperBasketLine], prefix: String = "sharedOrder.history") -> some View {
        if lines.isEmpty { Text(OrderAmendmentCopy.text("All ordered items were cancelled.")) }
        ForEach(lines) { line in
            VStack(alignment: .leading, spacing: 4) {
                Text(line.originalItem)
                Text(String(format: OrderAmendmentCopy.text("Packs: %lld"), Int64(line.packs)))
                Text(String(format: OrderAmendmentCopy.text("Price per pack: %@"), PlacementCopy.money(line.unitPriceMinor))).font(.caption)
            }.accessibilityElement(children: .combine).accessibilityIdentifier(prefix + "." + line.lineId)
        }
    }
    @ViewBuilder private func changes(from before: [ShopperBasketLine], to after: [ShopperBasketLine]) -> some View {
        let ids = before.map(\.lineId) + after.filter { line in !before.contains(where: { $0.lineId == line.lineId }) }.map(\.lineId)
        ForEach(ids, id: \.self) { id in
            let old = before.first { $0.lineId == id }, new = after.first { $0.lineId == id }
            if old != new {
                if let old { Text(OrderAmendmentCopy.text("Previously ordered")); orderLines([old]) }
                if let new { Text(OrderAmendmentCopy.text("Confirmed by the retailer")); orderLines([new]) }
                else { Text(OrderAmendmentCopy.text("Removed from this order")) }
            }
        }
    }
    private func clearDraft() {
        editing = false; confirmation = nil; selected = nil; reference = ""; lines = []; referenceFocused = false
    }
    private func refresh() async {
        guard !loading else { return }
        loading = true; page = nil; defer { loading = false }
        await model.load()
        guard canRead else { clearDraft(); return }
        do { let value = try await model.confirmedOrder(); guard canRead else { return }; page = value; message = nil
            if model.pending == nil { clearDraft() }
        } catch ClientError.service(status: 409, code: "order_evidence_removed", correlationID: _, retryAfter: _) {
            message = OrderAmendmentCopy.text("This order’s confirmation history was removed. Return to the shared shop to review and clear any pending action.")
        } catch { message = OrderAmendmentCopy.text("The confirmed order could not be loaded. Refresh before recording a change.") }
    }
}

private struct AmendmentLineChoice: Identifiable {
    let id: UUID
    let line: ShopperBasketLine?
    init(line: ShopperBasketLine?) { self.line = line; id = line.flatMap { UUID(uuidString: $0.lineId) } ?? UUID() }
}
private struct SharedAmendmentLineEditor: View {
    let choice: AmendmentLineChoice
    let save: (ShopperBasketLine?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var packs: String
    @State private var price = ""
    @State private var invalid = false
    @FocusState private var focus: Field?
    private enum Field { case name, packs, price }
    init(choice: AmendmentLineChoice, save: @escaping (ShopperBasketLine?) -> Void) {
        self.choice = choice; self.save = save
        _name = State(initialValue: choice.line?.originalItem ?? "")
        _packs = State(initialValue: choice.line.map { String($0.packs) } ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                if choice.line == nil { TextField(OrderAmendmentCopy.text("Item name"), text: $name).focused($focus, equals: .name) }
                else { Text(name) }
                TextField(OrderAmendmentCopy.text("Confirmed packs"), text: $packs).keyboardType(.numberPad)
                    .focused($focus, equals: .packs).accessibilityIdentifier("sharedOrder.packs")
                TextField(OrderAmendmentCopy.text("Confirmed price per pack (USD), if provided"), text: $price)
                    .keyboardType(.decimalPad).focused($focus, equals: .price)
                Button(OrderAmendmentCopy.text("Keep line for review")) {
                    do {
                        guard let count = Int(packs), (1...10_000).contains(count), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              name.utf16.count <= 240 else { invalid = true; return }
                        let entered = try HouseholdInboxModel.priceMinor(price)
                        let unchanged = choice.line?.packs == count
                        let cost = entered ?? (unchanged ? choice.line?.unitPriceMinor : nil)
                        save(.init(lineId: choice.id, originalItem: name, packs: count, unitPriceMinor: cost, feeEligible: choice.line?.feeEligible ?? false))
                    } catch { invalid = true }
                }.accessibilityIdentifier("sharedOrder.keepLine")
                if choice.line != nil { Button(OrderAmendmentCopy.text("Remove from the amended order"), role: .destructive) { save(nil) } }
                if invalid { Text(OrderAmendmentCopy.text("Enter an item, positive whole packs and a valid price if provided.")) }
            }
            .navigationTitle(OrderAmendmentCopy.text("Confirmed order line"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() } } }
            .keyboardDoneAction(visible: focus != nil, title: ht("Done"), identifier: "sharedOrder.lineKeyboardDone") { focus = nil }
        }
    }
}
enum OrderAmendmentCopy {
    static func text(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "OrderAmendment") }
}
