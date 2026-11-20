import CoreDomain
import LocalStore
import SwiftUI
import UniformTypeIdentifiers

struct PrivateDeliveryReceiptsView: View {
    @ObservedObject var model: PantryModel
    let target: CaptureTarget
    let onPutaway: (SourceMediaRecord, PrivateDeliveryRevision, Set<Int>) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var picking = false
    @State private var draft: DeliveryPDFReview?
    @State private var confirmed = false
    @State private var purchases: [PrivateDeliveryPurchase] = []
    @State private var history: [PrivateDeliveryPurchase] = []
    @State private var selected = Set<Int>()
    @State private var status: String?
    @State private var busy = false
    @State private var deleting = false
    @State private var generation = UUID()

    private var authorized: Bool {
        model.canEdit && model.supportsReceiptAliases && model.permitsReceiptSource && model.snapshot?.state.workspaceID == target.workspaceID
    }
    var body: some View {
        WorkingForm {
            if let status { Text(status).accessibilityIdentifier("deliveryReceipt.status") }
            if authorized {
                if busy { ProgressView() }
                if let current = draft {
                    let binding = Binding(get: { draft ?? current }, set: { draft = $0; confirmed = false })
                    edit(binding)
                } else if let head = history.first {
                    detail(head)
                } else {
                    Section {
                        Button(pantryText("Choose a final Uber Eats PDF")) { picking = true }
                            .accessibilityIdentifier("deliveryReceipt.pick")
                        Text(pantryText("Choose one PDF from Files. Reviewed purchase details stay private to your profile on this device."))
                    }
                    Section(pantryText("My delivery receipts")) {
                        ForEach(purchases) { purchase in
                            Button {
                                Task { await open(purchase) }
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(purchase.latest.merchant + " · " + purchase.latest.order)
                                    Text(amount(purchase.latest)).font(.subheadline)
                                }
                            }
                        }
                        if purchases.isEmpty { Text(pantryText("No saved delivery purchases.")) }
                    }
                }
            }
        }
        .disabled(busy)
        .privacySensitive()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(pantryText("My delivery receipts"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(pantryText("Close")) { dismiss() }
            }
        }
        .task { await load() }
        .onChange(of: model.snapshot?.state.workspaceID) { _, origin in if origin != target.workspaceID { clear(); dismiss() } }
        .onChange(of: phase) { _, phase in if phase == .background { clear(); dismiss() } }
        .onDisappear { clear() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { Task { await read(url) } }
        }
        .alert(pantryText("Delete this private purchase?"), isPresented: $deleting) {
            Button(pantryText("Delete"), role: .destructive) { Task { await erase() } }
            Button(pantryText("Cancel"), role: .cancel) {}
        } message: {
            Text(pantryText("This removes the purchase and its receipt revisions from this profile. Pantry entries have their own history."))
        }
    }

    @ViewBuilder private func edit(_ value: Binding<DeliveryPDFReview>) -> some View {
        let record = value.wrappedValue.record(at: .now)
        let previous = purchases.first { $0.id == record.orderKey }
        Section(pantryText("Purchase details")) {
            TextField(pantryText("Merchant on receipt"), text: value.merchant)
            Picker(pantryText("Type of merchant"), selection: Binding(get: { value.wrappedValue.merchantType }, set: { type in
                var next = value.wrappedValue
                next.changeMerchantType(type)
                value.wrappedValue = next
            })) {
                ForEach(DeliveryPDFReview.MerchantType.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField(pantryText("Uber Eats order reference"), text: value.order).textInputAutocapitalization(.never).autocorrectionDisabled()
            Picker(pantryText("Document type"), selection: value.kind) {
                ForEach(PrivateDeliveryRevision.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            TextField(pantryText("Final charge in USD"), text: value.total).keyboardType(.decimalPad)
            optionalDate(pantryText("Purchase date on receipt"), value.purchaseDate)
            optionalDate(pantryText("Delivery date on receipt"), value.deliveryDate)
            if let previous {
                Text(pantryText("This order already has a private purchase.") + " " + previous.latest.merchant + " · " + amount(previous.latest))
            }
            if value.wrappedValue.possibleConfirmation {
                Text(pantryText("This PDF mentions an estimate or order confirmation. Check for a final charge before saving."))
            }
            if value.wrappedValue.incomplete {
                Text(pantryText("Some PDF lines could not be read. Review the charge and save only the evidence you can confirm."))
            }
        }
        Section(pantryText("Included receipt lines")) {
            ForEach(value.rows) { row in
                if row.wrappedValue.included {
                    VStack(alignment: .leading) {
                        Text(row.wrappedValue.evidence.wording)
                        Picker(pantryText("Line treatment"), selection: row.evidence.disposition) {
                            ForEach(PrivateDeliveryRevision.Disposition.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        if row.wrappedValue.evidence.disposition.financial {
                            TextField(pantryText("Printed adjustment in USD"), text: row.amount)
                                .keyboardType(.numbersAndPunctuation)
                        } else {
                            quantity(row.wrappedValue.evidence)
                        }
                        Button(pantryText("Exclude line")) { row.included.wrappedValue = false }.buttonStyle(.borderless)
                    }
                }
            }
            DisclosureGroup(pantryText("Other PDF lines")) {
                ForEach(value.rows) { row in
                    if !row.wrappedValue.included {
                        Button {
                            row.included.wrappedValue = true
                        } label: {
                            Label(row.wrappedValue.evidence.wording, systemImage: "plus")
                        }.buttonStyle(.borderless)
                    }
                }
            }
            if record.lines.isEmpty { Text(pantryText("Total only")) }
        }
        Section {
            Toggle(pantryText("I checked the order, final charge or adjustment, and included lines against this PDF."), isOn: $confirmed)
            Button(pantryText(previous == nil ? "Save private purchase" : "Update this private purchase")) {
                Task { await save(record, expected: previous?.revision ?? 0) }
            }.disabled(!confirmed || record.order.isEmpty || record.merchant.isEmpty ||
                       (record.kind != .finalReceipt && previous == nil) ||
                       (!value.wrappedValue.total.isEmpty && record.finalCents == nil) ||
                       (record.kind == .finalReceipt && record.finalCents == nil) ||
                       value.wrappedValue.rows.contains { $0.included && !$0.amount.isEmpty && DeliveryPDFReview.cents($0.amount) == nil })
            .accessibilityIdentifier("deliveryReceipt.save")
            Button(pantryText("Discard draft"), role: .cancel) { draft = nil; confirmed = false; status = nil }
        }
    }

    private func optionalDate(_ title: String, _ value: Binding<Date?>) -> some View {
        VStack {
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? Date() : nil }))
            if value.wrappedValue != nil {
                DatePicker(title, selection: Binding(get: { value.wrappedValue ?? Date() }, set: { value.wrappedValue = $0 }),
                           in: ...Date(), displayedComponents: .date).labelsHidden()
            }
        }
    }

    @ViewBuilder private func detail(_ head: PrivateDeliveryPurchase) -> some View {
        let original = history.last { $0.latest.kind == .finalReceipt && $0.latest.lines.contains { !$0.disposition.financial } }
        Section {
            Text(head.latest.merchant + " · " + head.latest.order)
            LabeledContent(pantryText("Final charge in USD"), value: amount(head.latest))
        }
        ForEach(history, id: \.revision) { entry in
            Section(entry.latest.kind.title) {
                Text(entry.latest.importedAt, format: .dateTime.year().month().day().hour().minute())
                    .accessibilityLabel(Text(pantryText("Imported on")) + Text(" ") + Text(entry.latest.importedAt, style: .date))
                if let date = entry.latest.purchaseDate { LabeledContent(pantryText("Purchase date on receipt")) { Text(date, style: .date) } }
                if let date = entry.latest.deliveryDate { LabeledContent(pantryText("Delivery date on receipt")) { Text(date, style: .date) } }
                Text(amount(entry.latest))
                if entry.latest.lines.isEmpty { Text(pantryText("Total only")) }
                ForEach(entry.latest.lines) { line in
                    VStack(alignment: .leading) {
                        Text(line.wording)
                        if line.disposition.financial {
                            Text(line.disposition.title).font(.subheadline)
                        } else {
                            Menu {
                                ForEach(PrivateDeliveryRevision.Disposition.allCases.filter { !$0.financial }, id: \.self) { choice in
                                    Button(choice.title) { Task { await update(line, in: entry, to: choice) } }
                                }
                            } label: {
                                Label(line.disposition.title, systemImage: "pencil")
                            }.accessibilityHint(pantryText("Line treatment"))
                            quantity(line)
                        }
                        if let cents = line.cents { Text(usd(cents)).font(.caption) }
                        if entry.revision == original?.revision, !line.disposition.financial, line.disposition != .unresolved {
                            Toggle(pantryText(line.disposition.storage == nil ? "Save leftovers" : "Select for putaway"),
                                   isOn: Binding(get: { selected.contains(line.id) }, set: { include in
                                if include { selected.insert(line.id) } else { selected.remove(line.id) }
                            }))
                        }
                    }
                }
            }
        }
        Section {
            if let original, !selected.isEmpty {
                Button(pantryText("Review selected food")) {
                    do {
                        guard authorized else { return }
                        let source = try original.latest.putaway(target: target, selected: selected)
                        onPutaway(source, original.latest, selected)
                        dismiss()
                    } catch { status = pantryText("Check the selected receipt lines and try again.") }
                }
            }
            Button(pantryText("All delivery receipts")) { history = []; selected = []; status = nil }
            Button(pantryText("Delete private purchase"), role: .destructive) { deleting = true }
        }
    }

    private func quantity(_ line: PrivateDeliveryRevision.Line) -> some View {
        var source = ScanReceiptLine(originalText: line.wording)
        source.uncertainOCR = line.uncertain
        let printed = ReceiptPrintedEvidence(source, knownStorage: [:])
        if let qty = printed.quantity, let unit = printed.unit {
            return Text(qty + " " + pantryUnit(unit)).font(.caption)
        }
        return Text(pantryText("Quantity unknown")).font(.caption)
    }
    private func usd(_ cents: Int) -> String { (Decimal(cents) / 100).formatted(.currency(code: "USD")) }
    private func amount(_ row: PrivateDeliveryRevision) -> String { row.finalCents.map(usd) ?? pantryText("Updated total unknown") }

    private func read(_ url: URL) async {
        guard authorized, !busy else { return }
        let token = generation
        busy = true
        defer { busy = false }
        do {
            let input = try await ReceiptDocumentBytes.picked(url)
            guard authorized, token == generation, input.kind == .pdf else { throw ReceiptDocumentFailure.unsupported }
            let file = try await ReceiptDocumentReader().extract(input)
            guard authorized, token == generation else { return }
            if let existing = try await model.withPrivateDeliveryScope({ try await $0.privateDeliveryWithFile(persona: $1, digest: file.digest) }) {
                guard authorized, token == generation else { return }
                await open(existing)
                status = pantryText("This PDF is already in your purchase history.")
                return
            }
            guard authorized, token == generation else { return }
            draft = DeliveryPDFReview(document: file, origin: target.workspaceID)
            confirmed = false; status = nil
        } catch { if authorized && token == generation { status = pantryText("This PDF could not be read. Choose an unlocked receipt under 10 MB.") } }
    }

    private func load() async {
        let token = generation
        do {
            let results = try await model.withPrivateDeliveryScope { try await $0.privateDeliveryPurchases(persona: $1) }
            if authorized && generation == token { purchases = results }
        } catch { if authorized { status = pantryText("Could not open private purchases.") } }
    }

    private func open(_ row: PrivateDeliveryPurchase) async {
        let token = generation
        do {
            let revisions = try await model.withPrivateDeliveryScope { try await $0.privateDeliveryHistory(persona: $1, orderKey: row.id) }
            guard authorized, generation == token else { return }
            history = revisions; selected = []
        } catch { if authorized { status = pantryText("Could not open private purchases.") } }
    }

    private func save(_ row: PrivateDeliveryRevision, expected: Int) async {
        guard authorized, confirmed, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let saved = try await model.withPrivateDeliveryScope { try await $0.savePrivateDelivery(row, persona: $1, expectedRevision: expected) }
            guard authorized else { return }
            draft = nil; confirmed = false
            await load()
            await open(saved)
            status = pantryText("Private purchase saved. Confirm putaway separately.")
        } catch {
            await load()
            confirmed = false
            status = pantryText("Check the order reference, merchant and charge. Adjustments need a matching saved order.")
        }
    }

    private func update(_ line: PrivateDeliveryRevision.Line, in entry: PrivateDeliveryPurchase, to choice: PrivateDeliveryRevision.Disposition) async {
        guard authorized, !busy, choice != line.disposition else { return }
        busy = true
        defer { busy = false }
        do {
            try await model.withPrivateDeliveryScope { store, persona in
                try await store.reviewPrivateDeliveryLine(persona: persona, orderKey: entry.id, digest: entry.latest.digest,
                    ordinal: line.id, from: line.disposition, to: choice)
            }
            await open(entry)
            status = nil
        } catch { if authorized { status = pantryText("Check the selected receipt lines and try again.") } }
    }

    private func erase() async {
        guard let row = history.first, authorized, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await model.withPrivateDeliveryScope { try await $0.deletePrivateDelivery(persona: $1, orderKey: row.id, expectedRevision: row.revision) }
            history = []; selected = []; status = nil
            await load()
        } catch { if authorized { status = pantryText("Could not open private purchases.") } }
    }

    private func clear() {
        generation = UUID(); draft = nil; history = []; purchases = []; selected = []; confirmed = false; status = nil
    }
}
